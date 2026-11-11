//! Owning command result summary, identical for in-process tests and daemon submissions.
const std = @import("std");
const protocol = @import("protocol.zig");

pub const Result = union(enum) {
    edit_event: struct {
        old_revision: u32,
        new_revision: u32,
        source: []const u8,
        buffer_id: u32 = 0,
        interaction_revision: u32 = 0,
    },
    interaction_result: struct {
        old_revision: u32,
        new_revision: u32,
        session_id: u32,
        buffer_id: u32 = 0,
        document_revision: u32 = 0,
    },
    validation_report: struct { message: []const u8 },

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .edit_event => |event| allocator.free(event.source),
            .validation_report => |report| allocator.free(report.message),
            .interaction_result => {},
        }
        self.* = undefined;
    }
};

/// Copies the borrowed response before its frame or Litura event is released.
pub fn copy(allocator: std.mem.Allocator, event: protocol.Event) !Result {
    return switch (event.kind) {
        .edit_event => .{ .edit_event = .{
            .old_revision = event.old_revision,
            .new_revision = event.new_revision,
            .source = try allocator.dupe(u8, event.source),
        } },
        .interaction_result => .{ .interaction_result = .{
            .old_revision = event.old_revision,
            .new_revision = event.new_revision,
            .session_id = event.session,
        } },
        .validation_report => .{
            .validation_report = .{
                .message = try allocator.dupe(u8, event.message),
            },
        },
    };
}
