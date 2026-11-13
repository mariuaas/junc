//! Cursor-set behavior through Lua, the host adapter and real libvaxis cells.
const std = @import("std");
const junc = @import("junc");
const Fixture = @import("Fixture.zig");
const vaxis = @import("vaxis");
const Surface = @import("surface");
const allocator = std.testing.allocator;

fn command(f: *Fixture, name: []const u8, text: []const u8) !void {
    if (try f.editor.invoke(name, text)) |value| {
        var result = value;
        defer result.deinit(allocator);
        try std.testing.expect(result != .validation_report);
    }
}
fn count(f: *Fixture, expected: usize) !void {
    try std.testing.expectEqual(expected, f.connection.current().selections.len);
}

test "vertical cursors edit Unicode in one revision and undo step and retain their session across reload" {
    const f = try Fixture.create(allocator, "界é\nab\n👩‍💻z", null);
    defer f.destroy();
    const session = f.session();
    const primary = f.cursor();
    try command(f, "right", "");
    try command(f, "cursor-add-below", "");
    try count(f, 2);
    try command(f, "cursor-add-below", "");
    try command(f, "cursor-add-above", "");
    try count(f, 3);
    try command(f, "insert", "X");
    try f.expectText("界Xé\naXb\n👩‍💻Xz");
    try std.testing.expectEqual(@as(u32, 1), f.document().revision);
    for (f.connection.current().selections, [_]u32{ 2, 6, 10 }) |selection, position| {
        try std.testing.expectEqual(position, selection.cursor);
    }
    try command(f, "undo", "");
    try f.expectText("界é\nab\n👩‍💻z");
    try command(f, "redo", "");
    try f.expectText("界Xé\naXb\n👩‍💻Xz");
    const before = f.connection.current();
    try f.editor.reload("return function(e) e.command('live',function(c) assert(#c.selections==3); return e.replace(c,'Y') end) end");
    try std.testing.expectEqual(session, f.session());
    try std.testing.expectEqual(primary, f.cursor());
    try std.testing.expectEqual(before.interaction_revision, f.connection.current().interaction_revision);
    try command(f, "live", "");
    try f.expectText("界XYé\naXYb\n👩‍💻XYz");
    try std.testing.expectError(error.LuaError, f.editor.reload("invalid lua!"));
    try count(f, 3);
    try command(f, "cursor-single", "");
    try count(f, 1);
    try std.testing.expectEqual(primary, f.cursor());
}

test "next occurrence uses Litura words and exact search then replaces every selection atomically" {
    const f = try Fixture.create(allocator, "foo 界 foo foo", null);
    defer f.destroy();
    try command(f, "cursor-add-next", "");
    try count(f, 1);
    try std.testing.expectEqualStrings("foo", f.connection.current().selection);
    try command(f, "cursor-add-next", "");
    try command(f, "cursor-add-next", "");
    try count(f, 3);
    try std.testing.expectEqual(@as(u32, 0), f.document().revision);
    try std.testing.expectError(error.ServerRejected, f.editor.invoke("cursor-add-next", ""));
    try count(f, 3);
    try command(f, "wrap", "");
    try f.expectText("(foo) 界 (foo) (foo)");
    try command(f, "undo", "");
    try f.expectText("foo 界 foo foo");
}

test "overlapping deletions and coincident navigation collapse to the retained primary cursor" {
    const f = try Fixture.create(allocator, "abcd", null);
    defer f.destroy();
    try f.editor.reload(
        \\return function(e)
        \\ e.command('pair',function(c) return {kind='selections',edits={
        \\ {kind='move',cursor_anchor=c.cursor_anchor,position=1},
        \\ {kind='move',position=2}}} end)
        \\end
    );
    try command(f, "pair", "");
    try command(f, "backspace", "");
    try f.expectText("cd");
    try count(f, 1);
    try std.testing.expectEqual(@as(u32, 1), f.document().revision);
    try command(f, "undo", "");
    try f.expectText("abcd");
    try command(f, "pair", "");
    try command(f, "buffer-start", "");
    try count(f, 1);
    try std.testing.expectEqual(@as(u32, 0), f.editor.position());
}

test "ambiguous touching replacements reject atomically and minibuffer input remains isolated" {
    const f = try Fixture.create(allocator, "abcd", null);
    defer f.destroy();
    try f.editor.reload(
        \\return function(e)
        \\ e.command('pair',function(c) return {kind='selections',edits={
        \\ {kind='move',cursor_anchor=c.cursor_anchor,position=1,mark=0},
        \\ {kind='move',position=2,mark=1}}} end)
        \\end
    );
    try command(f, "pair", "");
    const before = f.connection.current();
    try std.testing.expectError(error.ServerRejected, f.editor.invoke("insert", "é"));
    try f.expectText("abcd");
    try std.testing.expectEqual(before.revision, f.connection.current().revision);
    try std.testing.expectEqual(before.interaction_revision, f.connection.current().interaction_revision);
    try f.editor.openMinibuffer(.lua);
    var paste = (try f.editor.paste("unexecuted")).?;
    defer paste.deinit(allocator);
    try f.expectText("abcd");
    try count(f, 2);
    try std.testing.expectEqual(before.interaction_revision, f.connection.current().interaction_revision);
}

test "secondary wide grapheme and end-of-line carets render above syntax and selections" {
    const f = try Fixture.create(allocator, "界x\n\n界x", "sample.lua");
    defer f.destroy();
    try command(f, "cursor-add-below", "");
    try command(f, "cursor-add-below", "");
    try count(f, 3);
    try f.editor.setPreset("minimal");
    var screen = try vaxis.Screen.init(allocator, .{ .rows = 5, .cols = 12, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{ .screen = &screen, .x_off = 0, .y_off = 0, .width = 12, .height = 5, .parent_x_off = 0, .parent_y_off = 0 };
    var surface: Surface = .{};
    defer surface.deinit(allocator);
    try surface.draw(&f.editor, win);
    try std.testing.expectEqualStrings("界", win.readCell(0, 2).?.char.grapheme);
    try std.testing.expectEqual(@as(u8, 2), win.readCell(0, 2).?.char.width);
    try std.testing.expect(win.readCell(0, 2).?.style.bold);
    try std.testing.expectEqual(vaxis.Style.Underline.single, win.readCell(0, 2).?.style.ul_style);
    try std.testing.expectEqual(vaxis.Style.Underline.single, win.readCell(0, 1).?.style.ul_style);
    try std.testing.expect(!win.readCell(0, 0).?.style.bold);
}

test "separate combining accents use symbolic endpoints for every cursor" {
    const f = try Fixture.create(allocator, "e\ne", null);
    defer f.destroy();
    try command(f, "right", "");
    try command(f, "cursor-add-below", "");
    try command(f, "insert", "́");
    try f.expectText("é\né");
    try std.testing.expectEqual(@as(u32, 3), f.document().graphemeCount());
    const state = f.connection.current();
    try std.testing.expectEqual(@as(u32, 1), state.selections[0].cursor);
    try std.testing.expectEqual(@as(u32, 3), state.selections[1].cursor);
    try command(f, "backspace", "");
    try f.expectText("\n");
    try command(f, "undo", "");
    try f.expectText("é\né");
}

test "many selections cross the Lua bridge with bounded stack usage and one transaction" {
    const f = try Fixture.create(allocator, "a\n" ** 128, null);
    defer f.destroy();
    try f.editor.reload(
        \\return function(e)
        \\ e.command('many',function(c)
        \\   local edits={{kind='move',cursor_anchor=c.cursor_anchor,position=0}}
        \\   for i=1,127 do edits[#edits+1]={kind='move',position=i*2} end
        \\   return {kind='selections',edits=edits}
        \\ end)
        \\end
    );
    try command(f, "many", "");
    try count(f, 128);
    try command(f, "insert", "界");
    try f.expectText("界a\n" ** 128);
    try std.testing.expectEqual(@as(u32, 1), f.document().revision);
    try command(f, "undo", "");
    try f.expectText("a\n" ** 128);
}

test "foreign cursor identities stale contexts and omitted selections reject before mutation" {
    const f = try Fixture.create(allocator, "a\nb", null);
    defer f.destroy();
    try command(f, "cursor-add-below", "");
    try f.editor.reload(
        \\return function(e)
        \\ e.command('foreign',function(c) return {kind='batch',edits={
        \\ {kind='keep',cursor_anchor=c.cursor_anchor},
        \\ {kind='move',cursor_anchor=4294967295,position=0}}} end)
        \\ e.command('omitted',function(c) return {kind='batch',edits={
        \\ {kind='replace',cursor_anchor=c.cursor_anchor,start=0,finish=0,text='X'}}} end)
        \\ e.command('capture-multi',function(c) saved_multi=e.replace(c,'X') end)
        \\ e.command('stale-multi',function() return saved_multi end)
        \\end
    );
    const before = f.connection.current();
    try std.testing.expectError(error.ServerRejected, f.editor.invoke("foreign", ""));
    try std.testing.expectError(error.ServerRejected, f.editor.invoke("omitted", ""));
    try f.expectText("a\nb");
    try std.testing.expectEqual(before.revision, f.connection.current().revision);
    try std.testing.expectEqual(before.interaction_revision, f.connection.current().interaction_revision);
    try command(f, "capture-multi", "");
    try command(f, "right", "");
    try std.testing.expectError(error.ServerRejected, f.editor.invoke("stale-multi", ""));
    try f.expectText("a\nb");
    try count(f, 2);
}

// Fail each host allocation in turn. A response allocation can fail after publication, so the
// observable outcome must be either the whole edit or none of it, never one cursor's half-edit.
fn batchWithFailure(offset: ?usize) !usize {
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var registry = junc.Registry.init(failing.allocator());
    defer registry.deinit();
    const buffer = try registry.create(.{ .text = "abcd" });
    var attachment: junc.Registry.Attachment = .{ .allocator = failing.allocator() };
    defer {
        failing.fail_index = std.math.maxInt(usize);
        attachment.deinit(&registry);
    }
    const target = try attachment.select(&registry, buffer.id);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const selected = junc.server.respond(&registry, &attachment, arena.allocator(), .{
        .id = 1,
        .op = .submit,
        .buffer = buffer.id,
        .edit = .{ .kind = .selections, .origin = 0, .interaction_origin = 0, .source = "test", .edits = &.{
            .{ .cursor_anchor = target.cursor.value, .position = 1 },
            .{ .position = 3 },
        } },
    });
    try std.testing.expect(selected.failure == null);
    const state = selected.state.?;
    const actions = [_]junc.protocol.CursorEdit{
        .{ .kind = .replace, .cursor_anchor = state.selections[0].cursor_anchor, .start = 1, .finish = 1, .text = "X" },
        .{ .kind = .replace, .cursor_anchor = state.selections[1].cursor_anchor, .start = 3, .finish = 3, .text = "X" },
    };
    const before = failing.alloc_index;
    if (offset) |index| failing.fail_index = before + index;
    if (junc.server.handle(&registry, &attachment, arena.allocator(), .{
        .id = 2,
        .op = .submit,
        .buffer = buffer.id,
        .edit = .{ .kind = .batch, .origin = 0, .interaction_origin = state.interaction_revision, .source = "test", .edits = &actions },
    })) |_| {} else |err| {
        try std.testing.expect(err == error.OutOfMemory);
    }
    const allocations = failing.alloc_index - before;
    failing.fail_index = std.math.maxInt(usize);
    const text = try buffer.document.getText();
    defer failing.allocator().free(text);
    if (buffer.document.revision == 0) {
        try std.testing.expectEqualStrings("abcd", text);
        try std.testing.expectEqual(state.interaction_revision, try buffer.document.interactionRevision(target.session));
    } else {
        try std.testing.expectEqual(@as(u32, 1), buffer.document.revision);
        try std.testing.expectEqualStrings("aXbcXd", text);
        try std.testing.expectEqual(state.interaction_revision + 1, try buffer.document.interactionRevision(target.session));
    }
    return allocations;
}

test "allocation exhaustion never publishes only part of a multi-cursor edit" {
    const allocations = try batchWithFailure(null);
    for (0..allocations) |index| _ = try batchWithFailure(index);
}

test "a containing deletion unions all overlapping groups and retains the primary endpoint" {
    const f = try Fixture.create(allocator, "abcdef", null);
    defer f.destroy();
    const primary = f.cursor();
    try f.editor.reload(
        \\return function(e) e.command('overlaps',function(c) return {kind='selections',edits={
        \\ {kind='move',cursor_anchor=c.cursor_anchor,position=3,mark=2},
        \\ {kind='move',position=5,mark=4},
        \\ {kind='move',position=6,mark=0}}} end) end
    );
    try command(f, "overlaps", "");
    try command(f, "delete", "");
    try f.expectText("");
    try count(f, 1);
    try std.testing.expectEqual(primary, f.cursor());
    try command(f, "undo", "");
    try f.expectText("abcdef");
}

test "occurrence selections can move many lines then extend the cursor set again" {
    const f = try Fixture.create(allocator, "const value = 1;\n" ** 60, "movement.zig");
    defer f.destroy();
    for (0..5) |_| try command(f, "cursor-add-next", "");
    try count(f, 5);
    for (0..20) |_| try command(f, "down", "");
    for (0..3) |_| try command(f, "left", "");
    for (0..2) |_| try command(f, "right", "");
    try command(f, "cursor-add-next", "");
    try count(f, 5);
    try command(f, "cursor-add-next", "");
    try count(f, 6);
    const values = try f.document().querySelections(allocator, f.session());
    defer allocator.free(values);
    for (values) |value| {
        try std.testing.expect(value.start.position != null);
        try std.testing.expect(value.end.position != null);
    }
    try std.testing.expectEqual(@as(u32, 0), f.document().revision);
}
