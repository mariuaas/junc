//! Bounded local framing: blocking client requests and incremental, nonblocking server I/O.
const std = @import("std");
const c = @import("host_c");
const protocol = @import("protocol.zig");
const io_bytes_per_turn = 64 * 1024;

pub fn errno() c_int {
    return if (@import("builtin").os.tag == .macos) c.__error().* else c.__errno_location().*;
}

pub fn configure(fd: c_int, seconds: c_long) !void {
    const timeout: c.struct_timeval = .{ .tv_sec = seconds, .tv_usec = 0 };
    if (c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &timeout, @sizeOf(@TypeOf(timeout))) != 0 or
        c.setsockopt(fd, c.SOL_SOCKET, c.SO_SNDTIMEO, &timeout, @sizeOf(@TypeOf(timeout))) != 0)
    {
        return error.SocketOptionFailed;
    }
    if (@hasDecl(c, "SO_NOSIGPIPE")) {
        const one: c_int = 1;
        if (c.setsockopt(fd, c.SOL_SOCKET, c.SO_NOSIGPIPE, &one, @sizeOf(c_int)) != 0) {
            return error.SocketOptionFailed;
        }
    }
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const flags = if (@hasDecl(c, "MSG_NOSIGNAL")) c.MSG_NOSIGNAL else 0;
        const count = c.send(fd, bytes.ptr + offset, bytes.len - offset, flags);
        if (count <= 0) {
            if (count < 0 and errno() == c.EINTR) continue;
            return error.SocketWriteFailed;
        }
        offset += @intCast(count);
    }
}

/// Writes one request after serialization succeeds. A write failure can leave a partial frame;
/// the caller must close the connection rather than retry. Allocates temporary encoded bytes.
pub fn sendRequest(allocator: std.mem.Allocator, fd: c_int, request: protocol.Request) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, request, .{});
    defer allocator.free(bytes);
    if (bytes.len == 0 or bytes.len > protocol.frame_bytes_max) return error.FrameTooLarge;
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(bytes.len), .little);
    try writeAll(fd, &header);
    try writeAll(fd, bytes);
}

/// Incremental receive state. Owns its partial frame; a completed frame transfers to the caller.
/// Each turn consumes at most 64 KiB, so a partial or large sender cannot monopolize the server.
pub const Reader = struct {
    header: [4]u8 = @splat(0),
    header_used: usize = 0,
    payload: []u8 = &.{},
    payload_used: usize = 0,

    pub fn deinit(self: *Reader, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }

    pub fn partial(self: *const Reader) bool {
        return self.header_used != 0;
    }

    /// Allocates with allocator and transfers a complete frame; use the same allocator for deinit.
    /// Null means incomplete input; after an error, close the connection and discard the reader.
    pub fn next(self: *Reader, allocator: std.mem.Allocator, fd: c_int) !?[]u8 {
        var budget: usize = io_bytes_per_turn;
        while (budget > 0) {
            const header = self.header_used < self.header.len;
            const destination = if (header)
                self.header[self.header_used..]
            else
                self.payload[self.payload_used..];
            const length = @min(destination.len, budget);
            const count = c.recv(fd, destination.ptr, length, c.MSG_DONTWAIT);
            if (count == 0) return error.EndOfStream;
            if (count < 0) {
                const code = errno();
                if (code == c.EINTR) continue;
                if (code == c.EAGAIN or code == c.EWOULDBLOCK) return null;
                return error.SocketReadFailed;
            }
            const received: usize = @intCast(count);
            budget -= received;
            if (header) {
                self.header_used += received;
                if (self.header_used == self.header.len) {
                    const size = std.mem.readInt(u32, &self.header, .little);
                    if (size == 0 or size > protocol.frame_bytes_max) return error.InvalidFrameLength;
                    self.payload = try allocator.alloc(u8, size);
                }
            } else {
                self.payload_used += received;
                if (self.payload_used == self.payload.len) {
                    const result = self.payload;
                    self.* = .{};
                    return result;
                }
            }
        }
        return null;
    }
};

/// Owns one encoded response/hint until its nonblocking write completes.
pub const Outgoing = struct {
    bytes: []u8,
    offset: usize = 0,

    /// Allocates an immutable frame; release through deinit with this same allocator.
    pub fn init(allocator: std.mem.Allocator, response: protocol.Response) !Outgoing {
        const json = try std.json.Stringify.valueAlloc(allocator, response, .{});
        defer allocator.free(json);
        if (json.len == 0 or json.len > protocol.frame_bytes_max) return error.FrameTooLarge;
        const bytes = try allocator.alloc(u8, 4 + json.len);
        std.mem.writeInt(u32, bytes[0..4], @intCast(json.len), .little);
        @memcpy(bytes[4..], json);
        return .{ .bytes = bytes };
    }

    pub fn deinit(self: *Outgoing, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }

    /// Writes at most one turn of bytes; false retains an unsent suffix. Failure requires
    /// disconnect.
    pub fn flush(self: *Outgoing, fd: c_int) !bool {
        const end = @min(self.bytes.len, self.offset + io_bytes_per_turn);
        while (self.offset < end) {
            const flags = c.MSG_DONTWAIT | if (@hasDecl(c, "MSG_NOSIGNAL")) c.MSG_NOSIGNAL else 0;
            const count = c.send(fd, self.bytes.ptr + self.offset, end - self.offset, flags);
            if (count <= 0) {
                const code = errno();
                if (count < 0 and code == c.EINTR) continue;
                if (count < 0 and (code == c.EAGAIN or code == c.EWOULDBLOCK)) return false;
                return error.SocketWriteFailed;
            }
            self.offset += @intCast(count);
        }
        return self.offset == self.bytes.len;
    }
};
