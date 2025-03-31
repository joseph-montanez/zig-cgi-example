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

        fn getSessionFilePath(ally: std.mem.Allocator, id: []const u8) ![]u8 {
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

            // Try to open the session file
            const file = std.fs.openFileAbsolute(session_file_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return null, // Not an error, just no session found
                else => {
                    std.debug.print("Failed to open session file '{s}': {any}\n", .{ session_file_path, err });
                    return SessionError.SessionFileOpenFailed;
                },
            };
            defer file.close();

            // Read the entire file content, ensuring null termination
            const file_contents_terminated = try file.readToEndAllocOptions(allocator, 1 * 1024 * 1024, // max_bytes
                null, // size_hint (optional)
                @alignOf(u8), // alignment
                0 // THE IMPORTANT PART: sentinel value 0
            );
            // file_contents_terminated now has type [:0]u8
            defer allocator.free(file_contents_terminated); // Free the buffer later

            // Parse the ZON data
            var status: std.zon.parse.Status = .{};
            const parse_result = std.zon.parse.fromSlice(T, allocator, file_contents_terminated, &status, .{}) catch |err| {
                std.debug.print("Failed to parse session file '{s}': {any}\n", .{ session_file_path, err });
                return null;
            };
            defer std.zon.parse.free(allocator, parse_result);

            //
            const data_ptr = try allocator.create(T);
            errdefer allocator.destroy(data_ptr);

            data_ptr.* = parse_result;

            // Allocate the Session struct itself
            const session_ptr = try allocator.create(Self);
            errdefer allocator.destroy(session_ptr);

            // Allocate and copy the session ID
            const id_copy = try allocator.dupe(u8, id);
            errdefer allocator.free(id_copy);

            // Initialize the session
            session_ptr.* = Self{
                .allocator = allocator,
                .id = id_copy, // Store the allocated copy
                .data = data_ptr, // Assign the parsed data
                .is_new = false,
                .modified = false,
            };

            return session_ptr;
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

            // Use serializeArbitraryDepth for potentially complex/nested data
            // Adjust depth_limit as needed, 0 means default. Use options for pretty printing if desired.
            try std.zon.stringify.serializeArbitraryDepth(
                self.data,
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
