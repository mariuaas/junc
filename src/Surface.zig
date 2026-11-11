//! Cell layout and viewport mapping. Lua supplies validated colors, gutter policy and status.
const std = @import("std");
const vaxis = @import("vaxis");
const junc = @import("junc");
const Target = @import("junc").editing.Target;
const Surface = @This();
top: u32 = 0,
left: u32 = 0,
monochrome: bool = false,
mini_left: u32 = 0,
auxiliary: [2][1024]u8 = @splat(@splat(0)),
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
    const mini_rows: u16 = if (editor.minibuffer.context != null) @min(3, win.height) else 0;
    const status_rows: u16 = @intFromBool(frame.status_visible and win.height > mini_rows);
    const rows = win.height - status_rows - mini_rows;
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
    if (rows > 0 and self.top < editor.document.lineCount()) {
        const last_line = @min(self.top + rows, editor.document.lineCount()) - 1;
        editor.syntax.update(&editor.document, .{
            .start = try editor.document.lineStart(self.top),
            .end = try editor.document.lineEnd(last_line, true),
        }) catch |err| editor.report(@errorName(err));
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
        try self.drawLine(editor.mainTarget(), frame, &editor.syntax, win, .{
            .line = line,
            .row = row,
            .gutter = gutter,
            .first = first,
            .last = last,
            .cursor = if (editor.minibuffer.context == null) position else null,
            .left = self.left,
        });
    }
    // The software cursor uses ordinary themed cells, avoiding terminal-global OSC 12 writes.
    if (rows > 0 and editor.minibuffer.context == null) {
        const x: u16 = @intCast(cursor_column - self.left + gutter);
        const y: u16 = @intCast(lc.line - self.top);
        var cell = win.readCell(x, y) orelse vaxis.Cell{};
        cell.style = style(theme.cursor_fg, theme.cursor_bg);
        cell.style.reverse = self.monochrome;
        cell.style.bold = self.monochrome;
        win.writeCell(x, y, cell);
    }
    if (status_rows > 0) {
        const status_win = win.child(.{ .y_off = rows, .height = 1 });
        status_win.fill(.{ .style = style(theme.status_fg, theme.status_bg) });
        _ = status_win.printSegment(.{ .text = frame.status(), .style = style(theme.status_fg, theme.status_bg) }, .{ .wrap = .none });
    }
    if (mini_rows > 0) try self.drawMinibuffer(editor, win, win.height - mini_rows, mini_rows);
    editor.viewport.top = self.top;
    editor.viewport.left = self.left;
}

const Row = struct {
    line: u32,
    row: u16,
    gutter: u16,
    first: u32,
    last: u32,
    cursor: ?u32,
    left: u32,
};

fn drawLine(self: *Surface, target: Target, frame: *const junc.presentation.Frame, syntax: ?*const junc.Syntax, win: vaxis.Window, row: Row) !void {
    const theme = frame.theme;
    const start = try target.document.lineStart(row.line);
    const end = try target.document.lineEnd(row.line, false);
    var iterator = try target.document.graphemeCursor(start);
    var column: u32 = 0;
    const columns = win.width - row.gutter;
    while (iterator.position < end) {
        const cluster = try iterator.current();
        const cells = width(win, cluster, column);
        const selected = iterator.position >= row.first and iterator.position < row.last;
        var cell_style = style(theme.fg, theme.bg);
        if (if (syntax) |cache| cache.categoryAt(iterator.position) else null) |category| {
            const token = frame.syntax[@intFromEnum(category)];
            if (token.fg) |fg| cell_style.fg = color(fg);
            cell_style.bold = token.bold;
            cell_style.italic = token.italic;
            cell_style.ul_style = if (token.underline) .single else .off;
        }
        // Complete overrides: cursor > selection > syntax > base, including attributes.
        if (selected) cell_style = style(theme.selection_fg, theme.selection_bg);
        if (iterator.position == row.cursor) cell_style = style(theme.cursor_fg, theme.cursor_bg);
        if (self.monochrome) {
            cell_style.reverse = selected or iterator.position == row.cursor;
            if (iterator.position == row.cursor) cell_style.bold = true;
        }
        if (column >= row.left and column + cells <= row.left + columns) {
            const x: u16 = @intCast(column - row.left + row.gutter);
            if (std.mem.eql(u8, cluster, "\t")) {
                for (0..cells) |offset| win.writeCell(x + @as(u16, @intCast(offset)), row.row, .{ .style = cell_style });
            } else {
                const safe = if (cluster.len == 1 and (cluster[0] < 32 or cluster[0] == 127)) "�" else cluster;
                win.writeCell(x, row.row, .{ .char = .{ .grapheme = safe, .width = @intCast(cells) }, .style = cell_style });
            }
        }
        column += cells;
        if (column > row.left + columns) break;
        if (!iterator.advance()) break;
    }
}

// Uses the same grapheme-to-cell renderer as document rows, with a clipped prompt prefix.
fn drawMinibuffer(self: *Surface, editor: *junc.Editor, win: vaxis.Window, row: u16, rows: u16) !void {
    const mini = &editor.minibuffer;
    var frame = editor.presentation;
    const appearance = frame.minibuffer;
    if (appearance.fg) |fg| frame.theme.fg = fg;
    if (appearance.bg) |bg| frame.theme.bg = bg;
    const input_win = win.child(.{ .y_off = row, .height = rows });
    input_win.fill(.{ .style = style(frame.theme.fg, frame.theme.bg) });
    var prompt_width: u32 = 0;
    var prompt_clusters = junc.litura.segmentation.graphemeIterator(mini.prompt());
    while (prompt_clusters.next()) |cluster| prompt_width += width(win, cluster, prompt_width);
    const prefix: u16 = @intCast(@min(prompt_width, win.width -| 1));
    const prompt_win = input_win.child(.{ .width = prefix, .height = 1 });
    _ = prompt_win.printSegment(.{ .text = mini.prompt(), .style = style(appearance.prompt_fg orelse frame.theme.gutter_fg, frame.theme.bg) }, .{ .wrap = .none });
    const target = mini.target();
    const position = try target.position();
    const lc = try target.document.positionToLineCol(position);
    var cursor_column: u32 = 0;
    var cursor = try target.document.graphemeCursor(try target.document.lineStart(lc.line));
    while (cursor.position < position) {
        cursor_column += width(win, try cursor.current(), cursor_column);
        if (!cursor.advance()) break;
    }
    if (cursor_column < self.mini_left) self.mini_left = cursor_column;
    const columns = win.width - prefix;
    if (cursor_column >= self.mini_left + columns) self.mini_left = cursor_column - columns + 1;
    const mark = try target.mark();
    try self.drawLine(target, &frame, null, input_win, .{
        .line = lc.line,
        .row = 0,
        .gutter = prefix,
        .first = @min(position, mark orelse position),
        .last = @max(position, mark orelse position),
        .cursor = position,
        .left = self.mini_left,
    });
    const x: u16 = @intCast(cursor_column - self.mini_left + prefix);
    var cell = input_win.readCell(x, 0) orelse vaxis.Cell{};
    cell.style = style(frame.theme.cursor_fg, frame.theme.cursor_bg);
    cell.style.reverse = self.monochrome;
    cell.style.bold = self.monochrome;
    input_win.writeCell(x, 0, cell);
    var index: u16 = 1;
    while (index < rows) : (index += 1) {
        const bytes = &self.auxiliary[index - 1];
        const label: []const u8 = if (mini.candidates.items.len > 0) candidates: {
            const selected = mini.candidate_index orelse 0;
            const offset = (selected + index - 1) % mini.candidates.items.len;
            break :candidates std.fmt.bufPrint(bytes, "{s}{s}", .{
                if (mini.candidate_index == offset) "> " else "  ", mini.candidates.items[offset],
            }) catch "Completion is too long";
        } else output: {
            const count = mini.output.items.len;
            const visible = @min(count, rows - 1);
            if (index > visible) break :output "";
            break :output mini.output.items[count - visible + index - 1];
        };
        const line = input_win.child(.{ .y_off = index, .height = 1 });
        _ = line.printSegment(.{ .text = label, .style = style(appearance.output_fg orelse frame.theme.gutter_fg, frame.theme.bg) }, .{ .wrap = .none });
    }
}
