//! Consumer checks for Litura's session-owned endpoints and canonical-result adapter.
const std = @import("std");
const junc = @import("junc");
const Fixture = @import("Fixture.zig");
const allocator = std.testing.allocator;

test "selection endpoints retain identity until collapsed and explicit no-op movement advances interaction" {
    const fixture = try Fixture.create(allocator, "abc", null);
    defer fixture.destroy();
    const editor = &fixture.editor;
    const cursor = fixture.cursor();
    var first = (try editor.dispatch("shift-right", "")).?;
    defer first.deinit(allocator);
    const initial = try fixture.document().querySelections(allocator, fixture.session());
    defer allocator.free(initial);
    try std.testing.expectEqual(@as(usize, 1), initial.len);
    const mark = initial[0].start.anchor;
    try std.testing.expectEqual(cursor, initial[0].end.anchor);
    var next = (try editor.dispatch("shift-right", "")).?;
    defer next.deinit(allocator);
    const extended = try fixture.document().querySelections(allocator, fixture.session());
    defer allocator.free(extended);
    try std.testing.expectEqual(mark, extended[0].start.anchor);
    try std.testing.expectEqual(cursor, extended[0].end.anchor);
    try std.testing.expectEqual(@as(?u32, 0), extended[0].start.position);
    try std.testing.expectEqual(@as(?u32, 2), extended[0].end.position);
    var replacement = (try editor.paste("é")).?;
    defer replacement.deinit(allocator);
    try fixture.expectText("éc");
    try std.testing.expectEqual(@as(u32, 1), editor.position());
    try std.testing.expect(editor.mark() == null);
    try std.testing.expectEqual(.disposed, (try fixture.document().queryAnchor(mark)).status);
    try std.testing.expectEqual(cursor, fixture.cursor());
    var home = (try editor.invoke("home", "")).?;
    defer home.deinit(allocator);
    const before = fixture.connection.current();
    var noop = (try editor.invoke("home", "")).?;
    defer noop.deinit(allocator);
    const after = fixture.connection.current();
    try std.testing.expectEqual(before.revision, after.revision);
    // Explicit set_selections advances interaction revision even when its delta is empty.
    try std.testing.expectEqual(before.interaction_revision + 1, after.interaction_revision);
    try std.testing.expectEqual(noop.interaction_result.old_revision + 1, noop.interaction_result.new_revision);
}

test "detaching releases session-owned endpoints without destroying the buffer" {
    var registry = junc.Registry.init(allocator);
    defer registry.deinit();
    const buffer = try registry.create(.{ .text = "kept" });
    var attachment: junc.Registry.Attachment = .{ .allocator = allocator };
    const target = try attachment.select(&registry, buffer.id);
    attachment.deinit(&registry);
    try std.testing.expectEqual(.disposed, (try buffer.document.queryAnchor(target.cursor)).status);
    try std.testing.expectError(error.KeyError, buffer.document.querySelections(allocator, target.session));
    const text = try buffer.document.getText();
    defer allocator.free(text);
    try std.testing.expectEqualStrings("kept", text);
}

test "empty undo preserves state and projects an owned canonical rejection" {
    const fixture = try Fixture.create(allocator, "abc", null);
    defer fixture.destroy();
    const before = fixture.connection.current();
    var result = (try fixture.editor.invoke("undo", "")).?;
    defer result.deinit(allocator);
    try std.testing.expect(result == .validation_report);
    try std.testing.expect(result.validation_report.message.len > 0);
    try std.testing.expectEqual(before.interaction_revision, fixture.connection.current().interaction_revision);
    try std.testing.expectEqual(before.revision, fixture.connection.current().revision);
    try fixture.expectText("abc");
}
