//! Presentation changes must leave Litura's persistent editing state alone.
const std = @import("std");
const junc = @import("junc");
const allocator = std.testing.allocator;

fn policy(edits: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{
        "local p = (function()\n",
        junc.presentation.default_source,
        "\nend)()\n",
        edits,
        "\nreturn p",
    });
}

fn command(editor: *junc.Editor, key: []const u8, text: []const u8) !void {
    if (try editor.dispatch(key, text)) |value| {
        var result = value;
        defer result.deinit(allocator);
        try std.testing.expect(result != .validation_report);
    }
}

test "presets and terminal-derived colors are Lua policy with safe unanswered-query defaults" {
    var editor = try junc.Editor.init(allocator, "hello", null);
    defer editor.deinit();
    try std.testing.expectEqualStrings("classic", editor.preset.slice());
    try std.testing.expect(editor.presentation.gutter_visible);
    try std.testing.expect(editor.presentation.theme.fg == .default);
    try std.testing.expectEqual(@as(u8, 4), editor.presentation.theme.selection_bg.index);
    editor.terminal.foreground = .{ .rgb = .{ 1, 2, 3 } };
    editor.terminal.background = .{ .rgb = .{ 10, 20, 30 } };
    editor.terminal.palette[4] = .{ .rgb = .{ 40, 50, 60 } };
    try editor.present(.{ .width = 100, .height = 30 });
    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, editor.presentation.theme.fg.rgb);
    try std.testing.expectEqual([3]u8{ 10, 20, 30 }, editor.presentation.theme.bg.rgb);
    try std.testing.expectEqual([3]u8{ 40, 50, 60 }, editor.presentation.theme.selection_bg.rgb);
    try command(&editor, "ctrl-p", "");
    try std.testing.expectEqualStrings("minimal", editor.preset.slice());
    try std.testing.expect(!editor.presentation.gutter_visible);
    try std.testing.expectEqual([3]u8{ 24, 34, 30 }, editor.presentation.theme.bg.rgb);
    try std.testing.expectEqual(@as(u32, 0), editor.document.?.revision);
    try std.testing.expectEqual(@as(u32, 0), try editor.document.?.interactionRevision(editor.session));
}

test "successful presentation and command reload preserves document selection session viewport and history" {
    var editor = try junc.Editor.init(allocator, "", null);
    defer editor.deinit();
    try command(&editor, "text", "abc");
    try command(&editor, "shift-left", "");
    try editor.present(.{ .width = 100, .height = 30, .top = 9, .left = 2 });
    const session = editor.session;
    const cursor = editor.cursor;
    const position = try editor.position();
    const mark = try editor.mark();
    const interaction = try editor.document.?.interactionRevision(session);
    const viewport = editor.viewport;
    const revision = editor.document.?.revision;
    const history = editor.document.?.undo_stack.items.len;
    try editor.setPreset("minimal");
    const source = try policy("p.presets.minimal.status = function(s) return 'LIVE '..s.path..' r'..s.revision..' i'..s.interaction_revision end; p.presets.minimal.theme = p.presets.classic.theme");
    defer allocator.free(source);
    try editor.reloadSources("return function(e) e.command('insert', function(c,t) return e.replace(c, 'X') end) end", source);
    try std.testing.expectEqualStrings("minimal", editor.preset.slice());
    try std.testing.expect(std.mem.startsWith(u8, editor.presentation.status(), "LIVE [scratch] r1 i"));
    try std.testing.expectEqual(session, editor.session);
    try std.testing.expectEqual(cursor, editor.cursor);
    try std.testing.expectEqual(position, try editor.position());
    try std.testing.expectEqual(mark, try editor.mark());
    try std.testing.expectEqual(interaction, try editor.document.?.interactionRevision(session));
    try std.testing.expectEqual(revision, editor.document.?.revision);
    try std.testing.expectEqualDeep(viewport, editor.viewport);
    try std.testing.expectEqual(history, editor.document.?.undo_stack.items.len);
    const text = try editor.document.?.getText();
    defer allocator.free(text);
    try std.testing.expectEqualStrings("abc", text);
    try command(&editor, "text", "z");
    try command(&editor, "ctrl-z", "");
    const restored = try editor.document.?.getText();
    defer allocator.free(restored);
    try std.testing.expectEqualStrings("abc", restored);
}

test "invalid Lua or presentation retains previous VM frame and command implementations" {
    var editor = try junc.Editor.init(allocator, "", null);
    defer editor.deinit();
    const state = editor.state;
    const before = editor.presentation;
    try std.testing.expectError(error.LuaError, editor.reloadSources(null, "not valid Lua !!!"));
    const invalid = [_][]const u8{
        "p.presets.minimal.theme = function(t) return {fg='purple'} end",
        "p.presets.classic.gutter.visible = 'yes'",
        "p.presets.classic.status = 42",
        "p.presets.minimal.status = function(s) error('bad status') end",
        "p.presets.classic.status = function(s) return {} end",
        "p.presets.classic.status = function(s) return '\\27[2J' end",
        "p.presets.classic.status = function(s) return string.rep('x',4097) end",
        "p.presets.classic.theme = function(t) local c=p.presets.minimal.theme(t); c.bg=256; return c end",
        "p.presets.classic.gutter = setmetatable({}, {__index=function() error('bad') end})",
        "p.next = nil",
    };
    for (invalid) |edits| {
        const source = try policy(edits);
        defer allocator.free(source);
        try std.testing.expectError(error.InvalidPresentation, editor.reloadSources("return function(e) e.command('insert', function(c,t) return e.replace(c, 'X') end) end", source));
        try std.testing.expectEqual(state, editor.state);
        try std.testing.expectEqualDeep(before, editor.presentation);
        try std.testing.expectEqual(@as(u32, 0), editor.document.?.revision);
        try std.testing.expectEqual(@as(u32, 0), try editor.document.?.interactionRevision(editor.session));
    }
    try command(&editor, "text", "a");
    const text = try editor.document.?.getText();
    defer allocator.free(text);
    try std.testing.expectEqualStrings("a", text);
    try std.testing.expectError(error.InvalidPresentation, editor.setPreset("missing"));
    try std.testing.expectEqualStrings("classic", editor.preset.slice());
}

test "a later status callback failure leaves the last complete presentation frame active" {
    var editor = try junc.Editor.init(allocator, "", null);
    defer editor.deinit();
    const source = try policy("p.presets.classic.status = function(s) if s.revision > 0 then error('late failure') end return 'ready' end");
    defer allocator.free(source);
    try editor.reloadSources(null, source);
    const frame = editor.presentation;
    try command(&editor, "text", "a");
    try std.testing.expectError(error.InvalidPresentation, editor.present(.{
        .width = 40,
        .height = 10,
    }));
    try std.testing.expectEqualDeep(frame, editor.presentation);
    try std.testing.expectEqual(@as(u32, 1), editor.document.?.revision);
}
