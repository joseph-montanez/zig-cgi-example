const std = @import("std");

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
    CookieParsingFailed,
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
        is_deleted: bool,

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
            defer allocator.free(file_contents_terminated);

            var status: std.zon.parse.Status = .{};
            defer status.deinit(allocator);

            const parsed_data_value = std.zon.parse.fromSlice(T, allocator, file_contents_terminated[0..], &status, .{}) catch |err| {
                std.debug.print("Failed to parse session file '{s}': {any} {s}\n", .{ session_file_path, err, file_contents_terminated });
                // Decide if parse failure means "no session" or an error
                return SessionError.SessionParseFailed; // Treat parse failure as an error for now
            };

            const data_ptr = try allocator.create(T);
            errdefer {
                data_ptr.deinit(allocator);
                allocator.destroy(data_ptr);
            }
            data_ptr.* = parsed_data_value;

            const session_ptr = try allocator.create(Self);

            const id_copy = try allocator.dupe(u8, id);
            errdefer allocator.free(id_copy);

            // Initialize the session
            session_ptr.* = Self{
                .allocator = allocator,
                .id = id_copy, // Store the allocated copy of the ID
                .data = data_ptr, // Assign the pointer to the heap-allocated data
                .is_new = false,
                .modified = false,
                .is_deleted = false,
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
                .is_deleted = false,
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

        pub fn markModified(self: *Self) void {
            self.modified = true;
        }

        pub fn markDeleted(self: *Self) void {
            self.is_deleted = true;
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
                .errors = [_][2]?[]const u8{.{ null, null }} ** 30,
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
                data.deinit(self.allocator);

                self.allocator.destroy(data);

                self.data = null;
            }

            std.debug.print("Session deinited: {s}\n", .{self.id});

            // Free the allocated session ID
            self.allocator.free(self.id);

            self.id = "";
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
