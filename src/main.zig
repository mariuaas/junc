//! Process wiring and one low-level libvaxis editing surface.
const std = @import("std");
const vaxis = @import("vaxis");
const junc = @import("junc");
const Surface = @import("surface");
const Event = union(enum) { key_press: vaxis.Key, winsize: vaxis.Winsize, color_report: vaxis.Color.Report };
pub const panic = vaxis.panic_handler;
pub const std_options: std.Options = .{ .log_level = .warn };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len > 2) return error.ExpectedOneFile;
    const path: ?[]const u8 = if (args.len == 2) args[1] else null;
    const text = if (path) |file| std.Io.Dir.cwd().readFileAlloc(init.io, file, allocator, .limited(junc.litura.BufferEngine.max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    } else try allocator.dupe(u8, "");
    defer allocator.free(text);
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    var editor = try junc.Editor.init(allocator, text, path);
    defer editor.deinit();
    editor.reloadFiles(.{ .commands = false }) catch |err| editor.report(@errorName(err));
    var surface: Surface = .{};
    defer surface.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(init.io, &buffer);
    defer tty.deinit();
    var vx = try vaxis.init(init.io, allocator, init.environ_map, .{});
    defer vx.deinit(allocator, tty.writer());
    var loop: vaxis.Loop(Event) = .init(init.io, &tty, &vx);
    // This revision's SIGWINCH callback invokes blocking Io operations from a
    // signal handler. Poll size on the main thread to avoid resize deadlocks.
    vaxis.Tty.resetSignalHandler();
    try loop.start();
    defer loop.stop();
    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromMilliseconds(200));
    try vx.resize(allocator, tty.writer(), try tty.getWinsize());
    try vx.queryColor(tty.writer(), .fg);
    try vx.queryColor(tty.writer(), .bg);
    for (0..16) |index| try vx.queryColor(tty.writer(), .{ .index = @intCast(index) });
    surface.monochrome = vx.caps.no_color;
    var redraw = true;
    while (!editor.quit) {
        const size = try tty.getWinsize();
        if (size.cols != vx.window().width or size.rows != vx.window().height) {
            try vx.resize(allocator, tty.writer(), size);
            redraw = true;
        }
        if (redraw) {
            try surface.draw(&editor, vx.window());
            try vx.render(tty.writer());
            redraw = false;
        }
        const event = try loop.tryEvent() orelse {
            try init.io.sleep(.fromMilliseconds(16), .real);
            continue;
        };
        redraw = true;
        switch (event) {
            .color_report => |report| switch (report.kind) {
                .fg => editor.terminal.foreground = .{ .rgb = report.value },
                .bg => editor.terminal.background = .{ .rgb = report.value },
                .index => |index| if (index < 16) {
                    editor.terminal.palette[index] = .{ .rgb = report.value };
                },
                .cursor => {},
            },
            .winsize => |reported_size| try vx.resize(allocator, tty.writer(), reported_size),
            .key_press => |key| {
                var name_buffer: [64]u8 = undefined;
                const name = keyName(key, &name_buffer);
                var utf8: [4]u8 = undefined;
                const input = key.text orelse if (!key.mods.ctrl and !key.mods.alt and key.codepoint >= 32 and key.codepoint < 0x110000 and (key.codepoint < 57344 or key.codepoint > 57454))
                    utf8[0 .. std.unicode.utf8Encode(key.codepoint, &utf8) catch 0]
                else
                    "";
                if (editor.dispatch(name, input)) |result| {
                    if (result) |value| {
                        var owned = value;
                        defer owned.deinit(allocator);
                        if (owned == .validation_report) editor.report(owned.validation_report.message);
                    }
                } else |err| {
                    if (err != error.LuaError) editor.report(@errorName(err));
                }
            },
        }
    }
}

fn keyName(key: vaxis.Key, buffer: []u8) []const u8 {
    if (key.matches('x', .{ .alt = true })) return "alt-x";
    if (key.matches(':', .{ .alt = true })) return "alt-colon";
    const special: ?[]const u8 = switch (key.codepoint) {
        vaxis.Key.left => "left",
        vaxis.Key.right => "right",
        vaxis.Key.up => "up",
        vaxis.Key.down => "down",
        vaxis.Key.home => "home",
        vaxis.Key.end => "end",
        vaxis.Key.backspace => "backspace",
        vaxis.Key.delete => "delete",
        vaxis.Key.enter => "enter",
        vaxis.Key.tab => "tab",
        vaxis.Key.escape => "escape",
        else => null,
    };
    if (special) |name| {
        return std.fmt.bufPrint(buffer, "{s}{s}{s}{s}", .{
            if (key.mods.ctrl) "ctrl-" else "",
            if (key.mods.alt) "alt-" else "",
            if (key.mods.shift) "shift-" else "",
            name,
        }) catch "";
    }
    if (key.mods.ctrl or key.mods.alt) {
        var bytes: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(key.codepoint, &bytes) catch return "";
        return std.fmt.bufPrint(buffer, "{s}{s}{s}{s}", .{
            if (key.mods.ctrl) "ctrl-" else "",
            if (key.mods.alt) "alt-" else "",
            if (key.mods.shift) "shift-" else "",
            if (key.codepoint == ' ') "space" else bytes[0..length],
        }) catch "";
    }
    return "text";
}
