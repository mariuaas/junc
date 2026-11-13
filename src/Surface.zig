//! Cell layout and viewport following. Renders immutable views of the selected buffer and the
//! minibuffer through one grapheme-to-cell path. Lua supplies colors, gutter policy and status.
const std = @import("std");
const vaxis = @import("vaxis");
const junc = @import("junc");
const protocol = junc.protocol;
const Surface = @This();
monochrome: bool = false,
/// Horizontal scroll of the minibuffer input, in cells. The document's lives on the editor.
mini_left: u32 = 0,
redraw_requested: bool = false,
auxiliary: [2][1024]u8 = @splat(@splat(0)),
// libvaxis cells borrow strings until render completes, so row labels live on the surface.
gutter_bytes: std.ArrayListUnmanaged([12]u8) = .empty,

/// Releases row-label storage using the allocator supplied to draw; no terminal is owned here.
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

// Grapheme at a document position inside the view, as UTF-8 borrowed from the view text.
fn grapheme(view: *const protocol.View, position: u32) []const u8 {
    std.debug.assert(position >= view.start);
    std.debug.assert(position < view.end);
    const index = position - view.start;
    return view.text[view.boundaries[index]..view.boundaries[index + 1]];
}

// Cell column of position, measured from the start of its line.
fn columnOf(win: vaxis.Window, view: *const protocol.View, line: protocol.Line, position: u32) u32 {
    var column: u32 = 0;
    var index = line.start;
    while (index < @min(position, line.end)) : (index += 1) {
        column += width(win, grapheme(view, index), column);
    }
    return column;
}

fn lineIn(view: *const protocol.View, line: u32) ?protocol.Line {
    if (line < view.first_line or line - view.first_line >= view.lines.len) return null;
    return view.lines[line - view.first_line];
}

// Smallest scroll from top that shows line within rows.
fn follow(top: u32, line: u32, rows: u16) u32 {
    if (line < top) return line;
    if (line - top >= rows) return line - (rows - 1);
    return top;
}

/// Draws one frame, allocating row labels and resolving Lua policy before cell construction.
/// Observes the selected buffer at most twice; cells borrow that view, the minibuffer view and
/// this surface until libvaxis render completes. Writes the followed offsets to editor.viewport.
pub fn draw(self: *Surface, editor: *junc.Editor, win: vaxis.Window) !void {
    self.redraw_requested = false;
    // Retire cells borrowing the previous views before observing replacements.
    win.fill(.{});
    var queried: u16 = 0;
    if (win.width > 0 and win.height > 0) {
        // Rows from the previous frame's layout; a changed layout requests one more frame.
        const mini: u16 = if (editor.minibuffer.context != null) @min(3, win.height) else 0;
        const status: u16 = @intFromBool(editor.presentation.status_visible and win.height > mini);
        queried = @max(1, win.height - mini - status);
        editor.viewport.top = try observe(editor.connection, editor.viewport.top, queried);
    }
    editor.present(.{
        .width = win.width,
        .height = win.height,
        .top = editor.viewport.top,
        .left = editor.viewport.left,
    }) catch |err| {
        editor.report(@errorName(err));
    };
    const frame = &editor.presentation;
    const theme = frame.theme;
    win.fill(.{ .style = style(theme.fg, theme.bg) });
    win.hideCursor();
    if (win.width == 0 or win.height == 0) return;
    const state = editor.connection.current();
    const view = editor.connection.view() orelse return error.ViewNotPrepared;
    const mini_rows: u16 = if (editor.minibuffer.context != null) @min(3, win.height) else 0;
    const status_rows: u16 = @intFromBool(frame.status_visible and win.height > mini_rows);
    const rows = win.height - status_rows - mini_rows;
    self.redraw_requested = queried != @max(rows, 1);
    var digits: u16 = 1;
    var count = state.lines;
    while (count >= 10) : (count /= 10) digits += 1;
    const gutter: u16 = if (frame.gutter_visible)
        @min(if (frame.line_numbers) digits + 1 else 1, win.width -| 1)
    else
        0;
    const columns = win.width - gutter;
    const top = editor.viewport.top;
    var left = editor.viewport.left;
    // A peer edit between observations can leave the cursor line unobserved until the next frame.
    const cursor_line = lineIn(view, state.line);
    const cursor_column = if (cursor_line) |line| columnOf(win, view, line, state.cursor) else null;
    if (cursor_column) |column| {
        if (column < left) left = column;
        if (column >= left + columns) left = column - columns + 1;
    } else self.redraw_requested = true;
    if (left != editor.viewport.left) {
        editor.present(.{
            .width = win.width,
            .height = win.height,
            .top = top,
            .left = left,
        }) catch |err| {
            editor.report(@errorName(err));
        };
    }
    try self.drawRows(editor, view, win, .{
        .rows = rows,
        .top = top,
        .left = left,
        .gutter = gutter,
        .position = state.cursor,
        .mark = state.mark,
        .gutter_style = style(theme.gutter_fg, theme.gutter_bg),
    });
    // The software cursor uses ordinary themed cells, avoiding terminal-global OSC 12 writes.
    if (cursor_column) |column| {
        if (rows > 0 and editor.minibuffer.context == null and
            state.line >= top and state.line - top < rows)
        {
            const x: u16 = @intCast(column - left + gutter);
            const y: u16 = @intCast(state.line - top);
            var cell = win.readCell(x, y) orelse vaxis.Cell{};
            cell.style = style(theme.cursor_fg, theme.cursor_bg);
            cell.style.reverse = self.monochrome;
            cell.style.bold = self.monochrome;
            win.writeCell(x, y, cell);
        }
    }
    // End-of-line secondary carets need a cell even where there is no text grapheme.
    if (editor.minibuffer.context == null) for (state.selections) |selection| {
        if (selection.cursor_anchor == state.cursor_anchor) continue;
        if (selection.line < top or selection.line - top >= rows) continue;
        const line = lineIn(view, selection.line) orelse continue;
        if (selection.cursor != line.end) continue;
        const column = columnOf(win, view, line, selection.cursor);
        if (column < left or column >= left + columns) continue;
        const x: u16 = @intCast(column - left + gutter);
        const y: u16 = @intCast(selection.line - top);
        var cell = win.readCell(x, y) orelse vaxis.Cell{};
        cell.style = style(theme.cursor_fg, theme.cursor_bg);
        cell.style.bold = true;
        cell.style.ul_style = .single;
        cell.style.reverse = self.monochrome;
        win.writeCell(x, y, cell);
    };
    if (status_rows > 0) {
        const status_win = win.child(.{ .y_off = rows, .height = 1 });
        status_win.fill(.{ .style = style(theme.status_fg, theme.status_bg) });
        _ = status_win.printSegment(.{
            .text = frame.status(),
            .style = style(theme.status_fg, theme.status_bg),
        }, .{
            .wrap = .none,
        });
    }
    if (mini_rows > 0) try self.drawMinibuffer(editor, win, win.height - mini_rows, mini_rows);
    editor.viewport.left = left;
}

// Observes rows lines scrolled to show the cursor and returns the first observed line. The cursor
// line comes from the latest snapshot, which a peer edit may have outdated; the observation's fresh
// snapshot gets one follow-up request if it moved the cursor out of range.
fn observe(connection: *junc.Connection, top: u32, rows: u16) !u32 {
    try connection.prepareView(follow(top, connection.current().line, rows), rows);
    const first = (connection.view() orelse return error.ViewNotPrepared).first_line;
    const line = connection.current().line;
    if (follow(first, line, rows) == first) return first;
    try connection.prepareView(follow(first, line, rows), rows);
    return (connection.view() orelse return error.ViewNotPrepared).first_line;
}

fn drawRows(self: *Surface, editor: *junc.Editor, view: *const protocol.View, win: vaxis.Window, options: struct {
    rows: u16,
    top: u32,
    left: u32,
    gutter: u16,
    position: u32,
    mark: ?u32,
    gutter_style: vaxis.Style,
}) !void {
    const frame = &editor.presentation;
    const first = @min(options.position, options.mark orelse options.position);
    const last = @max(options.position, options.mark orelse options.position);
    try self.gutter_bytes.resize(editor.allocator, options.rows);
    var row: u16 = 0;
    while (row < options.rows) : (row += 1) {
        const number = options.top + row;
        const gutter_style = options.gutter_style;
        for (0..options.gutter) |x| win.writeCell(@intCast(x), row, .{ .style = gutter_style });
        const line = lineIn(view, number) orelse continue;
        if (options.gutter > 0 and frame.line_numbers) {
            const label = try std.fmt.bufPrint(&self.gutter_bytes.items[row], "{d}", .{number + 1});
            const number_win = win.child(.{
                .x_off = 0,
                .y_off = row,
                .width = options.gutter - 1,
                .height = 1,
            });
            _ = number_win.printSegment(.{
                .text = label,
                .style = gutter_style,
            }, .{
                .wrap = .none,
            });
        }
        self.drawLine(view, line, frame, win, .{
            .row = row,
            .gutter = options.gutter,
            .first = first,
            .last = last,
            .cursor = if (editor.minibuffer.context == null) options.position else null,
            .left = options.left,
            .selections = editor.connection.current().selections,
            .show_cursors = editor.minibuffer.context == null,
        });
    }
}

const Row = struct {
    row: u16,
    gutter: u16,
    first: u32,
    last: u32,
    cursor: ?u32,
    left: u32,
    selections: []const protocol.Selection = &.{},
    show_cursors: bool = true,
};

// Cells borrow the view's text; tokens style graphemes below selection and cursor.
fn drawLine(
    self: *Surface,
    view: *const protocol.View,
    line: protocol.Line,
    frame: *const junc.presentation.Frame,
    win: vaxis.Window,
    row: Row,
) void {
    const theme = frame.theme;
    var column: u32 = 0;
    const columns = win.width - row.gutter;
    var position = line.start;
    while (position < line.end) : (position += 1) {
        const cluster = grapheme(view, position);
        const cells = width(win, cluster, column);
        var selected = position >= row.first and position < row.last;
        var secondary = false;
        for (row.selections) |selection| {
            if (position >= selection.first and position < selection.last) selected = true;
            if (row.show_cursors and position == selection.cursor and position != row.cursor) secondary = true;
        }
        const caret = position == row.cursor or secondary;
        var cell_style = style(theme.fg, theme.bg);
        if (junc.syntax.categoryAt(view.tokens, position)) |category| {
            const token = frame.syntax[@intFromEnum(category)];
            if (token.fg) |fg| cell_style.fg = color(fg);
            cell_style.bold = token.bold;
            cell_style.italic = token.italic;
            cell_style.ul_style = if (token.underline) .single else .off;
        }
        // Complete overrides: cursor > selection > syntax > base, including attributes.
        if (selected) cell_style = style(theme.selection_fg, theme.selection_bg);
        if (caret) cell_style = style(theme.cursor_fg, theme.cursor_bg);
        if (secondary) {
            cell_style.bold = true;
            cell_style.ul_style = .single;
        }
        if (self.monochrome) {
            cell_style.reverse = selected or caret;
            if (caret) cell_style.bold = true;
        }
        if (column >= row.left and column + cells <= row.left + columns) {
            const x: u16 = @intCast(column - row.left + row.gutter);
            if (std.mem.eql(u8, cluster, "\t")) {
                for (0..cells) |offset| win.writeCell(x + @as(u16, @intCast(offset)), row.row, .{
                    .style = cell_style,
                });
            } else {
                const control = cluster.len == 1 and (cluster[0] < 32 or cluster[0] == 127);
                const safe = if (control) "�" else cluster;
                win.writeCell(x, row.row, .{
                    .char = .{
                        .grapheme = safe,
                        .width = @intCast(cells),
                    },
                    .style = cell_style,
                });
            }
        }
        column += cells;
        if (column > row.left + columns) break;
    }
}

// Uses the same grapheme-to-cell renderer as document rows, with a clipped prompt prefix.
fn drawMinibuffer(
    self: *Surface,
    editor: *junc.Editor,
    win: vaxis.Window,
    row: u16,
    rows: u16,
) !void {
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
    _ = prompt_win.printSegment(.{
        .text = mini.prompt(),
        .style = style(appearance.prompt_fg orelse frame.theme.gutter_fg, frame.theme.bg),
    }, .{
        .wrap = .none,
    });
    const input = try mini.observe();
    const line = input.view.lines[0];
    const cursor_column = columnOf(win, &input.view, line, input.cursor);
    if (cursor_column < self.mini_left) self.mini_left = cursor_column;
    const columns = win.width - prefix;
    if (cursor_column >= self.mini_left + columns) self.mini_left = cursor_column - columns + 1;
    self.drawLine(&input.view, line, &frame, input_win, .{
        .row = 0,
        .gutter = prefix,
        .first = @min(input.cursor, input.mark orelse input.cursor),
        .last = @max(input.cursor, input.mark orelse input.cursor),
        .cursor = input.cursor,
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
        const line_win = input_win.child(.{ .y_off = index, .height = 1 });
        _ = line_win.printSegment(.{
            .text = label,
            .style = style(appearance.output_fg orelse frame.theme.gutter_fg, frame.theme.bg),
        }, .{
            .wrap = .none,
        });
    }
}
