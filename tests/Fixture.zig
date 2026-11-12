//! An editor attached to an in-process host holding one buffer, without a daemon or terminal. The
//! host, connection and editor reference each other, so they live together at a stable address.
const std = @import("std");
const junc = @import("junc");
const Fixture = @This();

allocator: std.mem.Allocator,
host: junc.InProcessHost,
connection: junc.Connection,
editor: junc.Editor,

/// Allocates the fixture; release it with destroy. A path names the buffer but is not read.
pub fn create(allocator: std.mem.Allocator, text: []const u8, path: ?[]const u8) !*Fixture {
    const self = try allocator.create(Fixture);
    errdefer allocator.destroy(self);
    self.allocator = allocator;
    self.host = try junc.InProcessHost.init(allocator, .{ .text = text, .path = path });
    errdefer self.host.deinit();
    self.connection = try junc.Connection.attach(allocator, &self.host);
    errdefer self.connection.deinit();
    self.editor = try junc.Editor.init(allocator, &self.connection);
    return self;
}

pub fn destroy(self: *Fixture) void {
    self.editor.deinit();
    self.connection.deinit();
    self.host.deinit();
    self.allocator.destroy(self);
}

/// The authoritative buffer this editor has selected.
pub fn buffer(self: *Fixture) *junc.Registry.Buffer {
    // The host selects a replacement before killing a selected buffer, so the selection exists.
    return self.host.registry.get(self.connection.current().buffer) catch unreachable;
}

pub fn document(self: *Fixture) *junc.litura.BufferEngine {
    return &self.buffer().document;
}

/// This editor's interaction session and cursor anchor in the selected buffer.
pub fn session(self: *Fixture) u32 {
    return self.connection.current().session;
}

pub fn cursor(self: *Fixture) junc.litura.anchors.AnchorId {
    return .{ .value = self.connection.current().cursor_anchor };
}

pub fn expectText(self: *Fixture, expected: []const u8) !void {
    const text = try self.document().getText();
    defer self.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}
