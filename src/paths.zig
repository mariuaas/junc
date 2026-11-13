//! Host path policy: canonical buffer identities and a private, cwd-independent runtime directory.
const std = @import("std");
const c = @import("host_c");
const wire = @import("wire.zig");

pub fn valid(path: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(path)) return false;
    for (path) |byte| if (byte < 32 or byte == 127) return false;
    return true;
}

/// Returns an owning absolute path. Existing symlinks resolve; missing files require a real parent.
/// Dangling symlinks are rejected rather than creating two identities for their absent target.
pub fn canonical(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(path) or !valid(path)) return error.InvalidPath;
    const terminated = try allocator.dupeZ(u8, path);
    defer allocator.free(terminated);
    const resolved = c.realpath(terminated, null);
    if (resolved != null) {
        defer c.free(resolved);
        return allocator.dupe(u8, std.mem.span(resolved));
    }
    if (wire.errno() != c.ENOENT) return error.CanonicalPathFailed;
    var stat: c.struct_stat = undefined;
    if (c.lstat(terminated, &stat) == 0 and stat.st_mode & c.S_IFMT == c.S_IFLNK) {
        return error.DanglingSymlink;
    }
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const parent_z = try allocator.dupeZ(u8, parent);
    defer allocator.free(parent_z);
    const real_parent = c.realpath(parent_z, null);
    if (real_parent == null) return error.ParentNotFound;
    defer c.free(real_parent);
    return std.fs.path.join(allocator, &.{ std.mem.span(real_parent), std.fs.path.basename(path) });
}

/// Prevents ordinary open/save from blocking the single host on a FIFO or device.
pub fn ordinaryFile(allocator: std.mem.Allocator, path: []const u8) !void {
    const terminated = try allocator.dupeZ(u8, path);
    defer allocator.free(terminated);
    var stat: c.struct_stat = undefined;
    if (c.stat(terminated, &stat) != 0) {
        if (wire.errno() == c.ENOENT) return;
        return error.FileStatFailed;
    }
    const kind = stat.st_mode & c.S_IFMT;
    if (kind != c.S_IFREG and kind != c.S_IFDIR) return error.NotRegularFile;
}

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    directory: [:0]u8,
    socket: [:0]u8,
    lock: [:0]u8,

    /// Owns path strings only. The directory and lock file intentionally survive a server exit.
    pub fn init(
        allocator: std.mem.Allocator,
        options: struct {
            directory: ?[]const u8 = null,
        },
    ) !Runtime {
        const directory = if (options.directory) |path|
            try allocator.dupeZ(u8, path)
        else
            try std.fmt.allocPrintSentinel(allocator, "/tmp/junc-{d}", .{c.getuid()}, 0);
        errdefer allocator.free(directory);
        if (!std.fs.path.isAbsolute(directory) or !valid(directory)) return error.InvalidRuntimeDirectory;
        if (c.mkdir(directory, 0o700) != 0 and wire.errno() != c.EEXIST) return error.RuntimeDirectoryFailed;
        var stat: c.struct_stat = undefined;
        if (c.lstat(directory, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFDIR or
            stat.st_uid != c.getuid() or stat.st_mode & 0o777 != 0o700)
        {
            return error.UnsafeRuntimeDirectory;
        }
        const socket = try std.fmt.allocPrintSentinel(allocator, "{s}/session.sock", .{
            directory,
        }, 0);
        errdefer allocator.free(socket);
        const lock = try std.fmt.allocPrintSentinel(allocator, "{s}/server.lock", .{directory}, 0);
        errdefer allocator.free(lock);
        if (socket.len >= @sizeOf(@FieldType(c.struct_sockaddr_un, "sun_path"))) {
            return error.SocketPathTooLong;
        }
        return .{ .allocator = allocator, .directory = directory, .socket = socket, .lock = lock };
    }

    pub fn deinit(self: *Runtime) void {
        self.allocator.free(self.directory);
        self.allocator.free(self.socket);
        self.allocator.free(self.lock);
        self.* = undefined;
    }

    /// Returns an owned, unlocked descriptor. The caller acquires flock and closes it after use.
    pub fn openLock(self: *const Runtime) !c_int {
        var fd = c.open(self.lock, c.O_CREAT | c.O_RDWR | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (fd < 0) return error.LockOpenFailed;
        if (fd < 3) {
            const copy = c.fcntl(fd, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
            _ = c.close(fd);
            if (copy < 0) return error.LockOpenFailed;
            fd = copy;
        }
        errdefer _ = c.close(fd);
        var stat: c.struct_stat = undefined;
        if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG or
            stat.st_uid != c.getuid() or stat.st_mode & 0o777 != 0o600 or stat.st_nlink != 1)
        {
            return error.UnsafeLockFile;
        }
        return fd;
    }

    /// Opens private append-only daemon diagnostics without following links or truncating data.
    /// Returns an owned descriptor above stderr; the caller closes it after spawn.
    pub fn openLog(self: *const Runtime) !c_int {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&buffer, "{s}/server.log", .{self.directory});
        var fd = c.open(path, c.O_CREAT | c.O_WRONLY | c.O_APPEND | c.O_NOFOLLOW |
            c.O_CLOEXEC | c.O_NONBLOCK, @as(c_uint, 0o600));
        if (fd < 0) return error.ServerLogOpenFailed;
        if (fd < 3) {
            const copy = c.fcntl(fd, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
            _ = c.close(fd);
            if (copy < 0) return error.ServerLogOpenFailed;
            fd = copy;
        }
        errdefer _ = c.close(fd);
        var stat: c.struct_stat = undefined;
        if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG or
            stat.st_uid != c.getuid() or stat.st_mode & 0o777 != 0o600 or stat.st_nlink != 1)
        {
            return error.UnsafeServerLog;
        }
        return fd;
    }

    /// No caller may remove an existing endpoint until it holds the lifetime startup lock.
    pub fn checkSocket(self: *const Runtime) !bool {
        var stat: c.struct_stat = undefined;
        if (c.lstat(self.socket, &stat) != 0) {
            if (wire.errno() == c.ENOENT) return false;
            return error.SocketStatFailed;
        }
        if (stat.st_uid != c.getuid() or stat.st_mode & c.S_IFMT != c.S_IFSOCK or
            stat.st_mode & 0o777 != 0o600)
        {
            return error.UnsafeSocket;
        }
        return true;
    }

    pub fn address(self: *const Runtime) c.struct_sockaddr_un {
        var result: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        result.sun_family = c.AF_UNIX;
        if (@hasField(c.struct_sockaddr_un, "sun_len")) result.sun_len = @sizeOf(c.struct_sockaddr_un);
        @memcpy(result.sun_path[0..self.socket.len], self.socket);
        return result;
    }
};
