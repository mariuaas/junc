//! Literal terminal paste framing and the shared Lua/Litura mutation path, without a terminal.
const std = @import("std");
const junc = @import("junc");
const Decoder = @import("terminal_input").Decoder;
const Fixture = @import("Fixture.zig");
const allocator = std.testing.allocator;
const start = "\x1b[200~";
const finish = "\x1b[201~";

test "paste framing preserves literal Unicode and controls at every payload split" {
    const text = "界é👩‍💻\r\n\t\x00\x11\x13\x1b[A\x1b[20x\x1b[200~end";
    const body = text ++ finish ++ "Z";
    for (1..text.len + finish.len) |split| {
        var decoder = Decoder.init(allocator);
        defer decoder.deinit();
        _ = try decoder.parse(start, .{});
        const first = try decoder.parse(body[0..split], .{});
        try std.testing.expectEqual(@as(?@import("vaxis").Event, null), first.event);
        try std.testing.expectEqual(split, first.n);
        const second = try decoder.parse(body[split..], .{});
        const pasted = second.event.?.paste;
        defer allocator.free(pasted);
        try std.testing.expectEqualStrings(text, pasted);
        try std.testing.expectEqual(text.len + finish.len - split, second.n);
        try std.testing.expect(!decoder.active);
        const trailing = try decoder.parse(body[split + second.n ..], .{});
        try std.testing.expectEqualStrings("Z", trailing.event.?.key_press.text.?);
    }
}

test "fragmented start markers and UTF8 wait for completion and unfinished pastes emit nothing" {
    for (1..start.len) |length| {
        var decoder = Decoder.init(allocator);
        defer decoder.deinit();
        try std.testing.expectEqual(@as(usize, 0), (try decoder.parse(start[0..length], .{})).n);
        _ = try decoder.parse(start, .{});
        const result = try decoder.parse("unfinished\x1b[20", .{});
        try std.testing.expect(result.event == null);
        try std.testing.expect(decoder.active);
    }
    var decoder = Decoder.init(allocator);
    defer decoder.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try decoder.parse("界"[0..2], .{})).n);
    try std.testing.expectEqualStrings("界", (try decoder.parse("界", .{})).event.?.key_press.text.?);
    try std.testing.expect((try decoder.parse("\x1b", .{ .lone_escape = true })).event.? == .key_press);
}

fn allocatePaste(test_allocator: std.mem.Allocator) !void {
    var decoder = Decoder.init(test_allocator);
    defer decoder.deinit();
    _ = try decoder.parse(start, .{});
    const event = (try decoder.parse("payload\x1b[201~", .{})).event.?;
    test_allocator.free(event.paste);
}

test "paste allocation failures leave no owned payload behind" {
    try std.testing.checkAllAllocationFailures(allocator, allocatePaste, .{});
}

test "paste is one Lua defined replacement undo step and bypasses keymaps and pending prefixes" {
    const fixture = try Fixture.create(allocator, "old", null);
    defer fixture.destroy();
    const editor = &fixture.editor;
    try editor.reload(
        \\return function(e)
        \\  e.keymap('trap',{x='quit'}); e.push_keymap('trap')
        \\  e.command('check-paste',function(c) assert(e.keymap_state(c.surface).pending==nil) end)
        \\end
    );
    var select = (try editor.invoke("select-all", "")).?;
    defer select.deinit(allocator);
    try std.testing.expect(try editor.paste("") == null);
    try std.testing.expect(editor.mark() != null);
    try std.testing.expectError(error.InvalidUtf8, editor.paste("\xff"));
    try fixture.expectText("old");
    _ = try editor.dispatch("ctrl-x", "");
    var result = (try editor.paste("x界é\r\nline\rtab\t\x11\x1b[A")).?;
    defer result.deinit(allocator);
    const expected = "x界é\nline\ntab\t\x11\x1b[A";
    try fixture.expectText(expected);
    try std.testing.expectEqual(@as(u32, 1), fixture.document().revision);
    try std.testing.expectEqualStrings("paste", result.edit_event.source);
    try std.testing.expectEqual(fixture.document().graphemeCount(), editor.position());
    try std.testing.expect(editor.mark() == null);
    try std.testing.expect(!editor.quit);
    _ = try editor.invoke("check-paste", "");
    var undo = (try editor.invoke("undo", "")).?;
    defer undo.deinit(allocator);
    try fixture.expectText("old");
    var redo = (try editor.invoke("redo", "")).?;
    defer redo.deinit(allocator);
    try fixture.expectText(expected);
}

test "paste follows minibuffer focus without evaluating text or changing the main document" {
    const fixture = try Fixture.create(allocator, "main", null);
    defer fixture.destroy();
    const editor = &fixture.editor;
    const before = fixture.connection.current();
    try editor.openMinibuffer(.lua);
    const revision = editor.minibuffer.document.revision;
    var result = (try editor.paste("print('unexecuted')\r\n\x11")).?;
    defer result.deinit(allocator);
    const text = try editor.minibuffer.document.getText();
    defer allocator.free(text);
    try std.testing.expectEqualStrings("print('unexecuted')\n\x11", text);
    try std.testing.expectEqual(revision + 1, editor.minibuffer.document.revision);
    try std.testing.expect(editor.minibuffer.context == .lua);
    try std.testing.expectEqual(@as(usize, 0), editor.minibuffer.history.items.len);
    try std.testing.expectEqual(@as(usize, 0), editor.minibuffer.output.items.len);
    try std.testing.expectEqual(before.revision, fixture.connection.current().revision);
    try std.testing.expectEqual(before.interaction_revision, fixture.connection.current().interaction_revision);
    try fixture.expectText("main");
    try std.testing.expect(!editor.quit);
}

test "Lua can replace paste behavior without replacing the editing session" {
    const fixture = try Fixture.create(allocator, "kept", null);
    defer fixture.destroy();
    const session = fixture.session();
    try fixture.editor.reload(
        "return function(e) e.command('paste',function(c,t) return e.replace(c,'['..t..']') end) end",
    );
    var result = (try fixture.editor.paste("custom")).?;
    defer result.deinit(allocator);
    try fixture.expectText("[custom]kept");
    try std.testing.expectEqual(session, fixture.session());
    try std.testing.expectEqual(@as(u32, 1), fixture.document().revision);
}
