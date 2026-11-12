const std = @import("std");
const junc = @import("junc");
const Fixture = @import("Fixture.zig");
test "ordinary typing and a separately loaded extension share observable submission results" {
    const fixture = try Fixture.create(std.testing.allocator, "", null);
    defer fixture.destroy();
    const editor = &fixture.editor;
    var ordinary = (try editor.dispatch("text", "abc")).?;
    defer ordinary.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), ordinary.edit_event.new_revision);
    var select = (try editor.dispatch("ctrl-a", "")).?;
    defer select.deinit(std.testing.allocator);
    try std.testing.expect(select.interaction_result.new_revision > select.interaction_result.old_revision);
    var extension = (try editor.dispatch("ctrl-w", "")).?;
    defer extension.deinit(std.testing.allocator);
    try std.testing.expectEqual(ordinary.edit_event.new_revision, extension.edit_event.old_revision);
    const text = try fixture.document().getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("(abc)", text);
    try std.testing.expectEqual(@as(u32, 5), editor.position());
}
test "reload preserves document and history and failed reload preserves commands" {
    const fixture = try Fixture.create(std.testing.allocator, "hello", null);
    defer fixture.destroy();
    const editor = &fixture.editor;
    const state = editor.state;
    try std.testing.expectError(error.LuaError, editor.reload("this is not Lua"));
    try std.testing.expectEqual(state, editor.state);
    try editor.reload("return function(e) e.command('insert', function(c,t) return e.replace(c, 'X') end) end");
    var result = (try editor.dispatch("text", "a")).?;
    defer result.deinit(std.testing.allocator);
    try editor.reload(null);
    var undo = (try editor.dispatch("ctrl-z", "")).?;
    defer undo.deinit(std.testing.allocator);
    const text = try fixture.document().getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}
test "grapheme navigation and deletion preserve Unicode clusters" {
    const fixture = try Fixture.create(std.testing.allocator, "", null);
    defer fixture.destroy();
    const editor = &fixture.editor;
    for ([_][2][]const u8{ .{
        "text",
        "界é👩‍💻",
    }, .{
        "left",
        "",
    }, .{
        "backspace",
        "",
    }, .{
        "enter",
        "",
    }, .{
        "delete",
        "",
    } }) |input| {
        var result = (try editor.dispatch(input[0], input[1])).?;
        result.deinit(std.testing.allocator);
    }
    const text = try fixture.document().getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("界\n", text);
}
test "built-in and equivalent extension receive the same revision and result API in Lua" {
    const fixture = try Fixture.create(std.testing.allocator, "", null);
    defer fixture.destroy();
    const editor = &fixture.editor;
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
    const text = try fixture.document().getText();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("aa", text);
}

test "invalid extension intents and malformed values preserve document state" {
    const fixture = try Fixture.create(std.testing.allocator, "abc", null);
    defer fixture.destroy();
    const editor = &fixture.editor;
    try editor.reload("return function(e) e.command('insert', function() return {kind='move',position=999} end) end");
    var result = (try editor.dispatch("text", "a")).?;
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .validation_report);
    try std.testing.expectEqual(@as(u32, 0), fixture.document().revision);
    try std.testing.expectEqual(@as(u32, 0), editor.position());
    try editor.reload("return function(e) e.command('insert', function() return {kind='move',position=0/0} end) end");
    try std.testing.expectError(error.InvalidCommand, editor.dispatch("text", "a"));
}

test "stale interaction submissions are rejected through Litura public API" {
    const fixture = try Fixture.create(std.testing.allocator, "abc", null);
    defer fixture.destroy();
    const editor = &fixture.editor;
    const origin = try fixture.document().interactionRevision(fixture.session());
    var move = (try editor.dispatch("right", "")).?;
    defer move.deinit(std.testing.allocator);
    var stale = try fixture.document().submit(.{ .payload = .{ .interaction_mutation = .{
        .session_id = fixture.session(),
        .origin = origin,
        .ops = &.{.{ .move_cursor_anchor = .{ .cursor = fixture.cursor(), .position = 3 } }},
    } }, .origin = fixture.document().revision });
    defer stale.deinit(std.testing.allocator);
    try std.testing.expect(stale == .validation_report);
    try std.testing.expectEqual(@as(u32, 1), editor.position());
}

test "computed intent strings survive Lua collection while later fields are decoded" {
    // A metatable computes source, then text triggers collection and same-sized string allocations.
    const fixture = try Fixture.create(std.testing.allocator, "", null);
    defer fixture.destroy();
    const editor = &fixture.editor;
    try editor.reload(
        \\return function(e)
        \\  e.command('insert', function(c)
        \\    local intent = {kind='replace', start=c.first, finish=c.last}
        \\    return setmetatable(intent, {
        \\      __newindex=function(t,k,v) if k~='source' then rawset(t,k,v) end end,
        \\      __index=function(_,k)
        \\        if k=='source' then return string.rep('source-',64) end
        \\        if k=='text' then
        \\          collectgarbage('collect')
        \\          local strings={}
        \\          for i=1,64 do
        \\            local prefix=tostring(i)
        \\            strings[i]=prefix..string.rep('x',448-#prefix)
        \\          end
        \\          return 'X'
        \\        end
        \\      end,
        \\    })
        \\  end)
        \\end
    );
    var result = (try editor.dispatch("text", "ignored")).?;
    defer result.deinit(std.testing.allocator);
    const expected = "source-" ** 64;
    try std.testing.expectEqualStrings(expected, result.edit_event.source);
    try fixture.expectText("X");
}

test "computed intent field errors preserve the document and leave the command usable" {
    const fixture = try Fixture.create(std.testing.allocator, "safe", null);
    defer fixture.destroy();
    const editor = &fixture.editor;
    try editor.reload(
        \\return function(e)
        \\  local failed=false
        \\  e.command('insert', function(c)
        \\    return setmetatable({kind='replace', start=c.first, finish=c.last}, {
        \\      __index=function(_,key)
        \\        if key=='text' then
        \\          if not failed then failed=true; error('computed field failed') end
        \\          return 'X'
        \\        end
        \\      end,
        \\    })
        \\  end)
        \\end
    );
    try std.testing.expectError(error.LuaError, editor.dispatch("text", "ignored"));
    try std.testing.expect(std.mem.indexOf(u8, editor.status(), "computed field failed") != null);
    try std.testing.expectEqual(@as(u32, 0), fixture.document().revision);
    try fixture.expectText("safe");
    var result = (try editor.dispatch("text", "ignored")).?;
    defer result.deinit(std.testing.allocator);
    try fixture.expectText("Xsafe");
}
test "separate combining input preserves grapheme cursor deletion and undo" {
    const fixture = try Fixture.create(std.testing.allocator, "", null);
    defer fixture.destroy();
    const editor = &fixture.editor;
    for ([_][]const u8{ "e", "́" }) |input| {
        var result = (try editor.dispatch("text", input)).?;
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result == .edit_event);
        try std.testing.expectEqual(@as(u32, 1), fixture.document().graphemeCount());
        try std.testing.expectEqual(@as(u32, 1), editor.position());
    }
    var erase = (try editor.dispatch("backspace", "")).?;
    defer erase.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), fixture.document().graphemeCount());
    var undo_delete = (try editor.dispatch("ctrl-z", "")).?;
    defer undo_delete.deinit(std.testing.allocator);
    try fixture.expectText("é");
    var undo_accent = (try editor.dispatch("ctrl-z", "")).?;
    defer undo_accent.deinit(std.testing.allocator);
    try fixture.expectText("e");
    var redo_accent = (try editor.dispatch("ctrl-y", "")).?;
    defer redo_accent.deinit(std.testing.allocator);
    try fixture.expectText("é");
    try std.testing.expectEqual(@as(u32, 1), fixture.document().graphemeCount());
    try std.testing.expectEqual(@as(u32, 1), editor.position());
}

test "replacement cursor projects inside a splice containing right context" {
    const fixture = try Fixture.create(std.testing.allocator, "🇳🇴🇸🇪", null);
    defer fixture.destroy();
    const editor = &fixture.editor;
    var insert = (try editor.dispatch("text", "🇦")).?;
    defer insert.deinit(std.testing.allocator);
    try std.testing.expect(insert == .edit_event);
    try std.testing.expectEqual(@as(u32, 3), fixture.document().graphemeCount());
    try std.testing.expectEqual(@as(u32, 1), editor.position());
    try fixture.expectText("🇦🇳🇴🇸🇪");
}

test "deleting a separator collapses the cursor onto the joined cluster" {
    const fixture = try Fixture.create(std.testing.allocator, "e\ń", null);
    defer fixture.destroy();
    const editor = &fixture.editor;
    for ([_][]const u8{ "right", "right", "backspace" }) |key| {
        var result = (try editor.dispatch(key, "")).?;
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result != .validation_report);
    }
    try fixture.expectText("é");
    try std.testing.expectEqual(@as(u32, 1), fixture.document().graphemeCount());
    try std.testing.expectEqual(@as(u32, 1), editor.position());
}

comptime {
    _ = @import("presentation_test.zig");
    _ = @import("syntax_test.zig");
    _ = @import("minibuffer_test.zig");
    _ = @import("keymap_test.zig");
    _ = @import("server_test.zig");
    _ = @import("viewport_test.zig");
}
