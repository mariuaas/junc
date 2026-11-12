//! Authoritative host without a daemon: one registry and one attachment answering requests through
//! the same server handlers. Tests and other embedders attach a Connection to it.
const std = @import("std");
const protocol = @import("protocol.zig");
const server = @import("server.zig");
const Registry = @import("Registry.zig");
const InProcessHost = @This();

allocator: std.mem.Allocator,
registry: Registry,
attachment: Registry.Attachment,
/// Buffer created by init and selected before the first request.
initial_buffer: u32,

/// Creates a registry holding one clean buffer with text. A relative path resolves against the
/// working directory, like a terminal argument, and is used for identity and syntax detection; it
/// is not read. Do not copy a live host; connections borrow its address.
pub fn init(
    allocator: std.mem.Allocator,
    options: struct { text: []const u8 = "", path: ?[]const u8 = null },
) !InProcessHost {
    var registry = Registry.init(allocator);
    errdefer registry.deinit();
    const absolute = if (options.path) |path| try absolutePath(allocator, path) else null;
    defer if (absolute) |path| allocator.free(path);
    const buffer = try registry.create(.{ .path = absolute, .text = options.text });
    return .{
        .allocator = allocator,
        .registry = registry,
        .attachment = .{ .allocator = allocator },
        .initial_buffer = buffer.id,
    };
}

pub fn deinit(self: *InProcessHost) void {
    self.attachment.deinit(&self.registry);
    self.registry.deinit();
    self.* = undefined;
}

fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

/// Answers one request with an owning decoded response, as if it had crossed the wire. The reply is
/// serialized and parsed so its slices borrow only the returned arena, never engine memory. Hosting
/// failures are encoded in the response; only allocation and encoding errors return.
pub fn call(
    self: *InProcessHost,
    allocator: std.mem.Allocator,
    request: protocol.Request,
) !std.json.Parsed(protocol.Response) {
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    var response = server.respond(&self.registry, &self.attachment, arena.allocator(), request);
    response.server_pid = 0;
    const bytes = try std.json.Stringify.valueAlloc(allocator, response, .{});
    defer allocator.free(bytes);
    if (bytes.len > protocol.frame_bytes_max) return error.FrameTooLarge;
    return std.json.parseFromSlice(protocol.Response, allocator, bytes, .{
        .allocate = .alloc_always,
    });
}
