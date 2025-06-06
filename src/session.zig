const std = @import("std");

pub const SessionData = struct {
    user_id: ?u64 = null,
    username: ?[]u8 = null, // Note: Slices parsed from ZON may need careful lifetime management or copying
    csrf_token: ?[32]u8 = null, // Fixed-size array is often easier

    // IMPORTANT: If you parse data containing slices (`[]u8`), and you need to
    // modify or keep that data after the original parsed buffer is freed,
    // you MUST allocate and copy it. For simplicity here, we'll assume
    // slices are either short-lived or point to comptime strings if set manually.
    // For runtime strings loaded from ZON, manage lifetimes carefully or copy.

    // We need a way to free potentially allocated data within SessionData
    // if we copy strings during parsing/modification. For this example,
    // we'll keep it simple and assume no deep allocations within SessionData itself
    // are managed *after* std.zon.parse.free is called on the main result.
    // If `username` were allocated, you'd add a `deinit` here.
};

pub const SessionError = error{
    SessionIdGenerationFailed,
    SessionFileOpenFailed,
    SessionFileReadFailed,
    SessionFileWriteFailed,
    SessionPathAllocationFailed,
    SessionDirectoryCreationFailed,
    SessionDataAllocationFailed,
    SessionParseFailed,
    SessionSerializationFailed,
    SessionIdEncodingFailed,
    CookieParsingFailed, // Added for clarity
};

const SESSION_ID_BYTES = 32; // Length of raw random bytes for session ID
pub const SESSION_DIR = "./sessions"; // IMPORTANT: Make this configurable!
pub const SESSION_COOKIE_NAME = "session_id";

pub fn Session(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        id: []u8,
        data: ?*T,
        is_new: bool,
        modified: bool,

        const Self = @This();

        pub fn getSessionFilePath(ally: std.mem.Allocator, id: []const u8) ![]u8 {
            const filename_part = try std.fmt.allocPrint(ally, "{s}.zon", .{id});
            defer ally.free(filename_part);

            const full_path = try std.fs.path.join(ally, &.{ SESSION_DIR, filename_part });

            return full_path;
        }

        pub fn load(allocator: std.mem.Allocator, id: []const u8) !?*Self {
            const session_file_path = getSessionFilePath(allocator, id) catch |err| {
                std.debug.print("Failed to allocate session file path: {any}\n", .{err});
                return SessionError.SessionPathAllocationFailed;
            };
            defer allocator.free(session_file_path);

            const cwd = std.fs.cwd();
            var open_result: anyerror!std.fs.File = undefined;

            if (std.fs.path.isAbsolute(session_file_path)) {
                std.debug.print("Session.load: Path is absolute: {s}\n", .{session_file_path});
                // Use explicit read flag for clarity
                open_result = std.fs.openFileAbsolute(session_file_path, .{});
            } else {
                std.debug.print("Session.load: Path is relative: {s} (relative to cwd)\n", .{session_file_path});
                open_result = cwd.openFile(session_file_path, .{});
            }

            const file = open_result catch |err| switch (err) {
                error.FileNotFound => {
                    std.debug.print("Session file not found: {s}\n", .{session_file_path});
                    return null; // No session found
                },
                else => {
                    std.debug.print("Failed to open session file '{s}': {any}\n", .{ session_file_path, err });
                    return SessionError.SessionFileOpenFailed;
                },
            };
            defer file.close();

            // Read file content
            const file_contents_terminated = file.readToEndAllocOptions(
                allocator,
                1 * 1024 * 1024, // max_bytes = 1MB
                null, // size_hint
                @alignOf(u8),
                0, // sentinel for null termination
            ) catch |err| {
                std.debug.print("Failed to read session file '{s}': {any}\n", .{ session_file_path, err });
                return SessionError.SessionFileReadFailed;
            };
            // This defer is crucial for the buffer read from the file
            defer allocator.free(file_contents_terminated);

            // --- CORRECTED ZON PARSING ---
            var status: std.zon.parse.Status = .{};
            // 1. Use fromSlice to parse into a *value* of type T
            const parsed_data_value = std.zon.parse.fromSlice(T, allocator, file_contents_terminated[0..], &status, .{}) catch |err| {
                std.debug.print("Failed to parse session file '{s}': {any} {s}\n", .{ session_file_path, err, file_contents_terminated });
                // Decide if parse failure means "no session" or an error
                return SessionError.SessionParseFailed; // Treat parse failure as an error for now
            };
            // Note: parsed_data_value is of type T, NOT *T.
            // If fromSlice failed, the catch block already returned.

            // 2. Allocate memory on the heap for the data struct T
            const data_ptr = try allocator.create(T);
            // If allocator.create fails, no new resources need cleanup yet.
            // If allocations *after* this fail, we need to destroy data_ptr:
            errdefer allocator.destroy(data_ptr);

            // 3. Copy the parsed data *value* into the allocated heap memory
            data_ptr.* = parsed_data_value;
            // --- END OF CORRECTED ZON PARSING ---

            // Allocate the Session struct itself
            const session_ptr = try allocator.create(Self);
            // If create fails, errdefer above cleans up data_ptr.

            // Allocate and copy the session ID
            const id_copy = try allocator.dupe(u8, id);
            // If dupe fails, destroy session_ptr AND trigger errdefer for data_ptr.
            errdefer allocator.destroy(session_ptr);

            // Initialize the session
            session_ptr.* = Self{
                .allocator = allocator,
                .id = id_copy, // Store the allocated copy of the ID
                .data = data_ptr, // Assign the pointer to the heap-allocated data
                .is_new = false,
                .modified = false,
            };

            std.debug.print("Session loaded successfully: {s}\n", .{session_file_path});
            return session_ptr; // Success
        }

        // Creates a new session instance
        pub fn createNew(allocator: std.mem.Allocator) !*Self {
            // Generate random bytes for ID
            var id_bytes: [SESSION_ID_BYTES]u8 = undefined;
            std.crypto.random.bytes(&id_bytes);

            const id_hex_array = std.fmt.bytesToHex(id_bytes, .lower);

            const id_hex_slice: []u8 = allocator.dupe(u8, &id_hex_array) catch |err| {
                std.debug.print("Failed to allocate memory for session ID hex slice: {any}\n", .{err});
                return SessionError.SessionIdEncodingFailed; // Or SessionDataAllocationFailed?
            };
            errdefer allocator.free(id_hex_slice);

            // Allocate the Session struct
            const session_ptr = try allocator.create(Self);
            errdefer allocator.destroy(session_ptr);

            // Initialize the new session
            session_ptr.* = Self{
                .allocator = allocator,
                .id = id_hex_slice, // Ownership transferred
                .data = null, // Default/empty session data
                .is_new = true,
                .modified = true, // Mark as modified so it gets saved
            };

            return session_ptr;
        }

        // Saves the session data to its ZON file
        pub fn save(self: *Self) !void {
            if (!self.modified and !self.is_new) {
                return; // No changes to save
            }

            const session_file_path = getSessionFilePath(self.allocator, self.id) catch |err| {
                std.debug.print("Failed to allocate session file path for saving: {any}\n", .{err});
                return SessionError.SessionPathAllocationFailed;
            };
            defer self.allocator.free(session_file_path);

            // Ensure session directory exists
            const dir_path = std.fs.path.dirname(session_file_path).?;
            const cwd = std.fs.cwd();

            if (std.fs.path.isAbsolute(dir_path)) {
                // Path IS absolute (e.g., starts with '/' on Unix)
                std.debug.print("Path is absolute. Using std.fs.makeDirAbsolute\n", .{});
                try std.fs.makeDirAbsolute(dir_path);
                std.debug.print("Ensured absolute directory exists: {s}\n", .{dir_path});
            } else {
                // Path IS relative (e.g., "./sessions", "sessions", ".")
                std.debug.print("Path is relative. Using std.fs.cwd().makePath\n", .{});
                try cwd.makePath(dir_path); // Creates recursively relative to cwd
                std.debug.print("Ensured relative directory exists: {s} (relative to cwd)\n", .{dir_path});
            }

            // Serialize session data to a buffer
            var buffer = std.ArrayList(u8).init(self.allocator);
            defer buffer.deinit();

            const data_to_serialize: T = if (self.data) |data_ptr| data_ptr.* else T{}; // Use default struct T{} if null

            // Use serializeArbitraryDepth for potentially complex/nested data
            // Adjust depth_limit as needed, 0 means default. Use options for pretty printing if desired.
            try std.zon.stringify.serializeArbitraryDepth(
                data_to_serialize,
                .{}, // Pretty print for readability
                buffer.writer(),
            );

            // Write buffer to file

            if (std.fs.path.isAbsolute(dir_path)) {
                const file = try std.fs.createFileAbsolute(session_file_path, .{});
                defer file.close();

                try file.writeAll(buffer.items);
            } else {
                const file = try cwd.createFile(session_file_path, .{});
                defer file.close(); // Ensure file is closed when function exits

                try file.writeAll(buffer.items);
            }

            // Reset flags after successful save
            self.modified = false;
            self.is_new = false; // It's no longer conceptually new after the first save
            std.debug.print("Session saved: {s}\n", .{session_file_path});
        }

        // Marks the session as modified (so it will be saved)
        pub fn markModified(self: *Self) void {
            self.modified = true;
        }

        pub fn getData(self: *Self) !*T {
            if (self.data) |data_ptr| {
                return data_ptr; // Return existing data pointer
            }

            // Data is null, create, initialize, and assign it
            std.debug.print("Session.getData(): Initializing null data for session {s}\n", .{self.id});
            const new_data = try self.allocator.create(T);
            errdefer self.allocator.destroy(new_data); // Ensure cleanup on error *before* assignment

            new_data.* = T{
                .user_id = null,
                .errors_length = null,
                .errors = [_][2][]const u8{.{ "", "" }} ** 30,
            }; // Or initialize with specific defaults if needed

            self.data = new_data; // Assign to the session
            // self.modified = true; // Mark as modified
            self.is_new = true;

            return new_data; // Return the newly created data pointer
        }

        // Cleans up resources owned by the Session struct
        pub fn deinit(self: *Self) void {
            // Free the parsed result if it exists
            if (self.data) |data| {
                // std.zon.parse.free(self.allocator, data);
                self.allocator.destroy(data);
            }

            // Free the allocated session ID
            self.allocator.free(self.id);

            std.debug.print("Session deinited: {s}\n", .{self.id});
        }
    };
}

pub fn parseSessionCookie(allocator: std.mem.Allocator, cookie_header: []const u8, session_cookie_name: []const u8) !?[]const u8 {
    var cookie_iter = std.mem.tokenize(cookie_header, "; ");

    while (cookie_iter.next()) |cookie| {
        // Trim leading spaces from the cookie string.
        const trimmed_cookie = std.mem.trim(u8, cookie, " ");

        // Find the '=' separator.
        const equals_index = std.mem.indexOf(u8, trimmed_cookie, "=");
        if (equals_index) |index| {
            // Extract the cookie name and value.
            const cookie_name = trimmed_cookie[0..index];
            const cookie_value = trimmed_cookie[index + 1 ..];

            // Compare the cookie name (case-sensitive).
            if (std.mem.eql(u8, cookie_name, session_cookie_name)) {
                // Return a copy of the value.
                return try allocator.dupe(u8, cookie_value);
            }
        }
    }

    return null;
}
