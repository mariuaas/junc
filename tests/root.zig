const std = @import("std");
const junc = @import("junc");
test "ordinary typing and a separately loaded extension share observable submission results" {
    var editor = try junc.Editor.init(std.testing.allocator, "", null);
    defer editor.deinit();
    var ordinary = (try editor.dispatch("text", "abc")).?;
    defer ordinary.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), ordinary.edit_event.new_revision);
    var select = (try editor.dispatch("ctrl-a", "")).?;
    defer select.deinit(std.testing.allocator);
    try std.testing.expect(select.interaction_result.new_revision > select.interaction_result.old_revision);
    var extension = (try editor.dispatch("ctrl-w", "")).?;
    defer extension.deinit(std.testing.allocator);
    try std.testing.expectEqual(ordinary.edit_event.new_revision, extension.edit_event.old_revision);
    const text = try editor.document.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("(abc)", text);
    try std.testing.expectEqual(@as(u32, 5), try editor.position());
}
test "reload preserves document and history and failed reload preserves commands" {
    var editor = try junc.Editor.init(std.testing.allocator, "hello", null);
    defer editor.deinit();
    const state = editor.state;
    try std.testing.expectError(error.LuaError, editor.reload("this is not Lua"));
    try std.testing.expectEqual(state, editor.state);
    try editor.reload("return function(e) e.command('insert', function(c,t) return e.replace(c, 'X') end) end");
    var result = (try editor.dispatch("text", "a")).?;
    defer result.deinit(std.testing.allocator);
    try editor.reload(null);
    var undo = (try editor.dispatch("ctrl-z", "")).?;
    defer undo.deinit(std.testing.allocator);
    const text = try editor.document.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}
test "grapheme navigation and deletion preserve Unicode clusters" {
    var editor = try junc.Editor.init(std.testing.allocator, "", null);
    defer editor.deinit();
    for ([_][2][]const u8{ .{ "text", "界é👩‍💻" }, .{ "left", "" }, .{ "backspace", "" }, .{ "enter", "" }, .{ "delete", "" } }) |input| {
        var result = (try editor.dispatch(input[0], input[1])).?;
        result.deinit(std.testing.allocator);
    }
    const text = try editor.document.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("界\n", text);
}
test "built-in and equivalent extension receive the same revision and result API in Lua" {
    var editor = try junc.Editor.init(std.testing.allocator, "", null);
    defer editor.deinit();
    try editor.reload(
        \\return function(e)
        \\  e.command('equivalent', function(c,t)
        \\    assert(e.last_result.kind == 'edit_event')
        \\    assert(e.last_result.source == 'insert')
        \\    assert(e.last_result.new_revision == c.revision)
        \\    assert(e.last_result.interaction_revision == c.interaction_revision)
        \\    return e.replace(c,t)
        \\  end)
        \\  e.bind('extension-key','equivalent')
        \\  e.command('verify', function(c)
        \\    assert(e.last_result.source == 'equivalent')
        \\    assert(e.last_result.old_revision == 1 and e.last_result.new_revision == 2)
        \\  end)
        \\  e.bind('verify','verify')
        \\end
    );
    var ordinary = (try editor.dispatch("text", "a")).?;
    defer ordinary.deinit(std.testing.allocator);
    var extension = (try editor.dispatch("extension-key", "a")).?;
    defer extension.deinit(std.testing.allocator);
    _ = try editor.dispatch("verify", "");
    const text = try editor.document.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("aa", text);
}

test "invalid extension intents and malformed values preserve document state" {
    var editor = try junc.Editor.init(std.testing.allocator, "abc", null);
    defer editor.deinit();
    try editor.reload("return function(e) e.command('insert', function() return {kind='move',position=999} end) end");
    var result = (try editor.dispatch("text", "a")).?;
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .validation_report);
    try std.testing.expectEqual(@as(u32, 0), editor.document.revision);
    try std.testing.expectEqual(@as(u32, 0), try editor.position());
    try editor.reload("return function(e) e.command('insert', function() return {kind='move',position=0/0} end) end");
    try std.testing.expectError(error.InvalidCommand, editor.dispatch("text", "a"));
}

test "stale interaction submissions are rejected through Litura public API" {
    var editor = try junc.Editor.init(std.testing.allocator, "abc", null);
    defer editor.deinit();
    const origin = try editor.document.interactionRevision(editor.session);
    var move = (try editor.dispatch("right", "")).?;
    defer move.deinit(std.testing.allocator);
    var stale = try editor.document.submit(.{ .payload = .{ .interaction_mutation = .{
        .session_id = editor.session,
        .origin = origin,
        .ops = &.{.{ .move_cursor_anchor = .{ .cursor = editor.cursor, .position = 3 } }},
    } }, .origin = editor.document.revision });
    defer stale.deinit(std.testing.allocator);
    try std.testing.expect(stale == .validation_report);
    try std.testing.expectEqual(@as(u32, 1), try editor.position());
}
test "separate combining input preserves grapheme cursor deletion and undo" {
    var editor = try junc.Editor.init(std.testing.allocator, "", null);
    defer editor.deinit();
    for ([_][]const u8{ "e", "́" }) |input| {
        var result = (try editor.dispatch("text", input)).?;
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result == .edit_event);
        try std.testing.expectEqual(@as(u32, 1), editor.document.graphemeCount());
        try std.testing.expectEqual(@as(u32, 1), try editor.position());
    }
    var erase = (try editor.dispatch("backspace", "")).?;
    defer erase.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), editor.document.graphemeCount());
    var undo_delete = (try editor.dispatch("ctrl-z", "")).?;
    defer undo_delete.deinit(std.testing.allocator);
    try expectText(&editor, "é");
    var undo_accent = (try editor.dispatch("ctrl-z", "")).?;
    defer undo_accent.deinit(std.testing.allocator);
    try expectText(&editor, "e");
    var redo_accent = (try editor.dispatch("ctrl-y", "")).?;
    defer redo_accent.deinit(std.testing.allocator);
    try expectText(&editor, "é");
    try std.testing.expectEqual(@as(u32, 1), editor.document.graphemeCount());
    try std.testing.expectEqual(@as(u32, 1), try editor.position());
}

fn expectText(editor: *junc.Editor, expected: []const u8) !void {
    const text = try editor.document.getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "replacement cursor projects inside a splice containing right context" {
    var editor = try junc.Editor.init(std.testing.allocator, "🇳🇴🇸🇪", null);
    defer editor.deinit();
    var insert = (try editor.dispatch("text", "🇦")).?;
    defer insert.deinit(std.testing.allocator);
    try std.testing.expect(insert == .edit_event);
    try std.testing.expectEqual(@as(u32, 3), editor.document.graphemeCount());
    try std.testing.expectEqual(@as(u32, 1), try editor.position());
    try expectText(&editor, "🇦🇳🇴🇸🇪");
}

test "deleting a separator collapses the cursor onto the joined cluster" {
    var editor = try junc.Editor.init(std.testing.allocator, "e\ń", null);
    defer editor.deinit();
    for ([_][]const u8{ "right", "right", "backspace" }) |key| {
        var result = (try editor.dispatch(key, "")).?;
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result != .validation_report);
    }
    try expectText(&editor, "é");
    try std.testing.expectEqual(@as(u32, 1), editor.document.graphemeCount());
    try std.testing.expectEqual(@as(u32, 1), try editor.position());
}

comptime {
    _ = @import("presentation_test.zig");
    _ = @import("syntax_test.zig");
    _ = @import("minibuffer_test.zig");
    _ = @import("keymap_test.zig");
}
