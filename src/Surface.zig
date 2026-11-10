//! Cell layout and viewport mapping. Lua supplies validated colors, gutter policy and status.
const std = @import("std");
const vaxis = @import("vaxis");
const junc = @import("junc");
const Surface = @This();
top: u32 = 0,
left: u32 = 0,
monochrome: bool = false,
// libvaxis cells borrow strings until render completes, so row labels live on the surface.
gutter_bytes: std.ArrayListUnmanaged([12]u8) = .empty,

pub fn deinit(self: *Surface, allocator: std.mem.Allocator) void {
    self.gutter_bytes.deinit(allocator);
    self.* = undefined;
}

fn color(value: junc.presentation.Color) vaxis.Color {
    return switch (value) {
        .default => .default,
        .index => |index| .{ .index = index },
        .rgb => |rgb| .{ .rgb = rgb },
    };
}

fn style(fg: junc.presentation.Color, bg: junc.presentation.Color) vaxis.Style {
    return .{ .fg = color(fg), .bg = color(bg) };
}

fn width(win: vaxis.Window, cluster: []const u8, column: u32) u32 {
    if (std.mem.eql(u8, cluster, "\t")) return 4 - column % 4;
    if (cluster.len == 1 and (cluster[0] < 32 or cluster[0] == 127)) return 1;
    return @max(1, win.gwidth(cluster));
}

pub fn draw(self: *Surface, editor: *junc.Editor, win: vaxis.Window) !void {
    editor.present(.{ .width = win.width, .height = win.height, .top = self.top, .left = self.left }) catch |err| {
        editor.report(@errorName(err));
    };
    const frame = &editor.presentation;
    const theme = frame.theme;
    win.fill(.{ .style = style(theme.fg, theme.bg) });
    win.hideCursor();
    if (win.width == 0 or win.height == 0) return;
    const rows = win.height - @as(u16, @intFromBool(frame.status_visible));
    var digits: u16 = 1;
    var count = editor.document.lineCount();
    while (count >= 10) : (count /= 10) digits += 1;
    const gutter: u16 = if (frame.gutter_visible)
        @min(if (frame.line_numbers) digits + 1 else 1, win.width -| 1)
    else
        0;
    const columns = win.width - gutter;
    const position = try editor.position();
    const lc = try editor.document.positionToLineCol(position);
    if (lc.line < self.top) self.top = lc.line;
    if (lc.line >= self.top + rows) self.top = lc.line -| (rows -| 1);
    var cursor_column: u32 = 0;
    var cursor = try editor.document.graphemeCursor(try editor.document.lineStart(lc.line));
    while (cursor.position < position) {
        cursor_column += width(win, try cursor.current(), cursor_column);
        if (!cursor.advance()) break;
    }
    if (cursor_column < self.left) self.left = cursor_column;
    if (cursor_column >= self.left + columns) self.left = cursor_column - columns + 1;
    if (editor.viewport.top != self.top or editor.viewport.left != self.left) {
        editor.present(.{ .width = win.width, .height = win.height, .top = self.top, .left = self.left }) catch |err| {
            editor.report(@errorName(err));
        };
    }
    const mark = try editor.mark();
    const first = @min(position, mark orelse position);
    const last = @max(position, mark orelse position);
    try self.gutter_bytes.resize(editor.allocator, rows);
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const line = self.top + row;
        const gutter_style = style(theme.gutter_fg, theme.gutter_bg);
        for (0..gutter) |x| win.writeCell(@intCast(x), row, .{ .style = gutter_style });
        if (line >= editor.document.lineCount()) continue;
        if (gutter > 0 and frame.line_numbers) {
            const label = try std.fmt.bufPrint(&self.gutter_bytes.items[row], "{d}", .{line + 1});
            const number_win = win.child(.{ .x_off = 0, .y_off = row, .width = gutter - 1, .height = 1 });
            _ = number_win.printSegment(.{ .text = label, .style = gutter_style }, .{ .wrap = .none });
        }
        try self.drawLine(editor, win, .{ .line = line, .row = row, .gutter = gutter, .first = first, .last = last, .cursor = position });
    }
    // The software cursor uses ordinary themed cells, avoiding terminal-global OSC 12 writes.
    if (rows > 0) {
        const x: u16 = @intCast(cursor_column - self.left + gutter);
        const y: u16 = @intCast(lc.line - self.top);
        var cell = win.readCell(x, y) orelse vaxis.Cell{};
        cell.style = style(theme.cursor_fg, theme.cursor_bg);
        cell.style.reverse = self.monochrome;
        cell.style.bold = self.monochrome;
        win.writeCell(x, y, cell);
    }
    if (frame.status_visible) {
        const status_win = win.child(.{ .y_off = rows, .height = 1 });
        status_win.fill(.{ .style = style(theme.status_fg, theme.status_bg) });
        _ = status_win.printSegment(.{ .text = frame.status(), .style = style(theme.status_fg, theme.status_bg) }, .{ .wrap = .none });
    }
    editor.viewport.top = self.top;
    editor.viewport.left = self.left;
}

const Row = struct { line: u32, row: u16, gutter: u16, first: u32, last: u32, cursor: u32 };

fn drawLine(self: *Surface, editor: *junc.Editor, win: vaxis.Window, row: Row) !void {
    const theme = editor.presentation.theme;
    const start = try editor.document.lineStart(row.line);
    const end = try editor.document.lineEnd(row.line, false);
    var iterator = try editor.document.graphemeCursor(start);
    var column: u32 = 0;
    const columns = win.width - row.gutter;
    while (iterator.position < end) {
        const cluster = try iterator.current();
        const cells = width(win, cluster, column);
        const selected = iterator.position >= row.first and iterator.position < row.last;
        var cell_style = if (iterator.position == row.cursor)
            style(theme.cursor_fg, theme.cursor_bg)
        else if (selected)
            style(theme.selection_fg, theme.selection_bg)
        else
            style(theme.fg, theme.bg);
        if (self.monochrome) {
            cell_style.reverse = selected or iterator.position == row.cursor;
            cell_style.bold = iterator.position == row.cursor;
        }
        if (column >= self.left and column + cells <= self.left + columns) {
            const x: u16 = @intCast(column - self.left + row.gutter);
            if (std.mem.eql(u8, cluster, "\t")) {
                for (0..cells) |offset| win.writeCell(x + @as(u16, @intCast(offset)), row.row, .{ .style = cell_style });
            } else {
                const safe = if (cluster.len == 1 and (cluster[0] < 32 or cluster[0] == 127)) "�" else cluster;
                win.writeCell(x, row.row, .{ .char = .{ .grapheme = safe, .width = @intCast(cells) }, .style = cell_style });
            }
        }
        column += cells;
        if (column > self.left + columns) break;
        if (!iterator.advance()) break;
    }
}
