//! Client viewport ownership: per-buffer offsets across switching and cursor following when drawn.
const std = @import("std");
const junc = @import("junc");
const vaxis = @import("vaxis");
const Surface = @import("surface");
const Fixture = @import("Fixture.zig");
const allocator = std.testing.allocator;

fn command(editor: *junc.Editor, key: []const u8, text: []const u8) !void {
    if (try editor.dispatch(key, text)) |value| {
        var result = value;
        defer result.deinit(allocator);
        try std.testing.expect(result != .validation_report);
    }
}

fn repeat(editor: *junc.Editor, key: []const u8, count: usize) !void {
    for (0..count) |_| try command(editor, key, "");
}

test "switching buffers restores this client's cursor and viewport for each buffer" {
    const fixture = try Fixture.create(allocator, "first\nbuffer\n", null);
    defer fixture.destroy();
    const editor = &fixture.editor;
    try command(editor, "text", "A");
    editor.viewport.top = 1;
    editor.viewport.left = 2;
    const first = editor.connection.current().buffer;
    try editor.openFile(null);
    const second = editor.connection.current().buffer;
    try std.testing.expect(second != first);
    try std.testing.expectEqual(@as(u32, 0), editor.viewport.top);
    try std.testing.expectEqual(@as(u32, 0), editor.position());
    editor.viewport.left = 5;
    try editor.selectBuffer(first);
    try std.testing.expectEqual(@as(u32, 1), editor.viewport.top);
    try std.testing.expectEqual(@as(u32, 2), editor.viewport.left);
    try std.testing.expectEqual(@as(u32, 1), editor.position());
    try fixture.expectText("Afirst\nbuffer\n");
    try editor.selectBuffer(second);
    try std.testing.expectEqual(@as(u32, 5), editor.viewport.left);
    // Killing the selected buffer selects the other one and forgets the killed viewport.
    try editor.killBuffer(second, false);
    try std.testing.expectEqual(first, editor.connection.current().buffer);
    try std.testing.expectEqual(@as(u32, 2), editor.viewport.left);
    for (editor.viewports.items) |view| try std.testing.expect(view.buffer != second);
}

test "drawing scrolls the observed range to follow the cursor in both directions" {
    // Forty short lines and one long one; a 6x10 window leaves 5 rows and 7 text columns.
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "x" ** 30 ++ "\n");
    for (1..40) |index| try text.print(allocator, "line {d}\n", .{index});
    const fixture = try Fixture.create(allocator, text.items, null);
    defer fixture.destroy();
    const editor = &fixture.editor;
    var screen = try vaxis.Screen.init(allocator, .{ .rows = 6, .cols = 10, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    const win: vaxis.Window = .{
        .screen = &screen,
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
    };
    var surface: Surface = .{};
    defer surface.deinit(allocator);
    try command(editor, "end", "");
    try surface.draw(editor, win);
    try std.testing.expectEqual(@as(u32, 0), editor.viewport.top);
    try std.testing.expectEqual(@as(u32, 24), editor.viewport.left);
    try command(editor, "home", "");
    try repeat(editor, "down", 20);
    try surface.draw(editor, win);
    try std.testing.expectEqual(@as(u32, 16), editor.viewport.top);
    try std.testing.expectEqual(@as(u32, 0), editor.viewport.left);
    try std.testing.expectEqual(@as(u32, 16), editor.connection.view().?.first_line);
    try std.testing.expectEqualStrings("2", win.readCell(0, 4).?.char.grapheme);
    try repeat(editor, "up", 18);
    try surface.draw(editor, win);
    try std.testing.expectEqual(@as(u32, 2), editor.viewport.top);
    try std.testing.expect(!surface.redraw_requested);
}

test "page-down and page-up scroll a screenful and keep the cursor in the window" {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(allocator);
    for (0..40) |index| try text.print(allocator, "line {d}\n", .{index});
    const fixture = try Fixture.create(allocator, text.items, null);
    defer fixture.destroy();
    const editor = &fixture.editor;
    editor.viewport.height = 6;
    try command(editor, "ctrl-v", "");
    try std.testing.expectEqual(@as(u32, 4), editor.connection.current().line);
    try std.testing.expectEqual(@as(u32, 4), editor.viewport.top);
    try command(editor, "page-down", "");
    try std.testing.expectEqual(@as(u32, 8), editor.connection.current().line);
    try std.testing.expectEqual(@as(u32, 8), editor.viewport.top);
    try command(editor, "alt-v", "");
    try std.testing.expectEqual(@as(u32, 4), editor.connection.current().line);
    try std.testing.expectEqual(@as(u32, 4), editor.viewport.top);
    try command(editor, "page-up", "");
    try std.testing.expectEqual(@as(u32, 0), editor.connection.current().line);
    try std.testing.expectEqual(@as(u32, 0), editor.viewport.top);
    try repeat(editor, "ctrl-v", 20);
    const rows: u32 = 5;
    const max_top = editor.connection.current().lines - rows;
    try std.testing.expectEqual(max_top, editor.viewport.top);
    try std.testing.expect(editor.connection.current().line >= editor.viewport.top);
}
