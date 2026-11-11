//! Live registry, REPL and persistent input sessions, exercised without a terminal.
const std = @import("std");
const junc = @import("junc");
const allocator = std.testing.allocator;

fn input(editor: *junc.Editor, key: []const u8, text: []const u8) !void {
    if (try editor.dispatch(key, text)) |value| {
        var result = value;
        defer result.deinit(allocator);
        try std.testing.expect(result != .validation_report);
    }
}

fn textIs(document: *junc.litura.BufferEngine, expected: []const u8) !void {
    const text = try document.getText();
    defer allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

fn lastOutput(editor: *junc.Editor) []const u8 {
    const items = editor.minibuffer.output.items;
    return items[items.len - 1];
}

fn evaluate(editor: *junc.Editor, source: []const u8) !void {
    try editor.openMinibuffer(.lua);
    try input(editor, "text", source);
    try input(editor, "enter", "");
}

test "persistent Litura minibuffer edits Unicode and isolates main document selection and history" {
    var editor = try junc.Editor.init(allocator, "main", null);
    defer editor.deinit();
    try input(&editor, "text", "X");
    try input(&editor, "shift-right", "");
    const position = try editor.position();
    const mark = try editor.mark();
    const revision = editor.document.revision;
    const interaction = try editor.document.interactionRevision(editor.session);
    const undo_count = editor.document.undo_stack.items.len;
    const session = editor.minibuffer.session;
    const cursor = editor.minibuffer.cursor;
    try input(&editor, "alt-colon", "");
    try input(&editor, "text", "界e");
    try input(&editor, "text", "́");
    try std.testing.expectEqual(@as(u32, 2), editor.minibuffer.document.graphemeCount());
    try std.testing.expectEqual(@as(u32, 2), try editor.minibuffer.target().position());
    try input(&editor, "backspace", "");
    try textIs(&editor.minibuffer.document, "界");
    try input(&editor, "ctrl-z", "");
    try textIs(&editor.minibuffer.document, "界é");
    try input(&editor, "ctrl-a", "");
    try input(&editor, "text", "return 2+3");
    try input(&editor, "enter", "");
    try std.testing.expectEqualStrings("5", lastOutput(&editor));
    try input(&editor, "escape", "");
    try input(&editor, "ctrl-l", "");
    try std.testing.expectEqual(session, editor.minibuffer.session);
    try std.testing.expectEqual(cursor, editor.minibuffer.cursor);
    try std.testing.expectEqual(revision, editor.document.revision);
    try std.testing.expectEqual(interaction, try editor.document.interactionRevision(editor.session));
    try std.testing.expectEqual(position, try editor.position());
    try std.testing.expectEqual(mark, try editor.mark());
    try std.testing.expectEqual(undo_count, editor.document.undo_stack.items.len);
    try textIs(&editor.document, "Xmain");
}

test "command discovery completion and description reflect extension metadata and current bindings" {
    var editor = try junc.Editor.init(allocator, "", null);
    defer editor.deinit();
    try editor.reload(
        \\return function(e)
        \\ e.command('stitch-example', function(c,t) return e.replace(c,'stitched') end,
        \\   {description='Stitch text',category='example'})
        \\ e.bind('ctrl-b','stitch-example')
        \\end
    );
    try input(&editor, "alt-x", "");
    try input(&editor, "text", "stitch-");
    try input(&editor, "tab", "");
    try textIs(&editor.minibuffer.document, "stitch-example");
    try input(&editor, "enter", "");
    try textIs(&editor.document, "stitched");
    try std.testing.expect(editor.minibuffer.context == null);
    try input(&editor, "ctrl-b", "");
    try textIs(&editor.document, "stitchedstitched");
    try evaluate(&editor, "editor.command_info('stitch-example').description");
    try std.testing.expectEqualStrings("Stitch text", lastOutput(&editor));
    try input(&editor, "ctrl-g", "");
    _ = try editor.invoke("describe-command", "");
    try std.testing.expect(editor.minibuffer.context == .prompt);
    try input(&editor, "text", "stitch-");
    try input(&editor, "tab", "");
    try input(&editor, "enter", "");
    try std.testing.expect(std.mem.indexOf(u8, lastOutput(&editor), "ctrl-b") != null);
    try std.testing.expect(std.mem.indexOf(u8, lastOutput(&editor), "Stitch text") != null);
    try input(&editor, "ctrl-o", "");
    try input(&editor, "text", "does-not-exist");
    try input(&editor, "enter", "");
    try std.testing.expect(editor.minibuffer.context == .command);
    try std.testing.expect(std.mem.indexOf(u8, lastOutput(&editor), "Unknown") != null);
}

test "live Lua expressions statements errors registration binding and invocation share the submission bridge" {
    var editor = try junc.Editor.init(allocator, "", null);
    defer editor.deinit();
    try evaluate(&editor, "answer = 40");
    try evaluate(&editor, "answer+2, nil, 'yes'");
    try std.testing.expectEqualStrings("42    nil    yes", lastOutput(&editor));
    try evaluate(&editor, "print('captured'); return editor.state().revision");
    try std.testing.expectEqualStrings("0", lastOutput(&editor));
    try std.testing.expectEqualStrings("captured", editor.minibuffer.output.items[
        editor.minibuffer.output.items.len - 2
    ]);
    try evaluate(&editor, "error('useful failure')");
    try std.testing.expect(std.mem.indexOf(u8, lastOutput(&editor), "useful failure") != null);
    try evaluate(&editor, "this is invalid Lua !!!");
    try std.testing.expect(std.mem.indexOf(u8, lastOutput(&editor), "minibuffer") != null);
    try evaluate(&editor, "editor.command('live', function(c,t) return editor.replace(c,'LIVE') end); editor.bind('ctrl-b','live')");
    try evaluate(&editor, "editor.invoke('live').revision");
    try std.testing.expectEqualStrings("1", lastOutput(&editor));
    try textIs(&editor.document, "LIVE");
    try input(&editor, "ctrl-g", "");
    try input(&editor, "ctrl-b", "");
    try textIs(&editor.document, "LIVELIVE");
    try evaluate(&editor, "editor.last_result.kind");
    // Input edits also have observable submission results in this same Lua environment.
    try std.testing.expectEqualStrings("edit_event", lastOutput(&editor));
    try std.testing.expectEqual(@as(u32, 2), editor.document.revision);
}

test "completion ambiguity cycling and history namespaces preserve drafts across close and reopen" {
    var editor = try junc.Editor.init(allocator, "", null);
    defer editor.deinit();
    try input(&editor, "ctrl-o", "");
    try input(&editor, "text", "select-");
    try input(&editor, "tab", "");
    try std.testing.expect(editor.minibuffer.candidates.items.len > 1);
    try input(&editor, "down", "");
    try std.testing.expectEqual(@as(?usize, 0), editor.minibuffer.candidate_index);
    try input(&editor, "tab", "");
    try std.testing.expectEqual(@as(?usize, 1), editor.minibuffer.candidate_index);
    try input(&editor, "ctrl-g", "");
    try evaluate(&editor, "10+1");
    try evaluate(&editor, "20+2");
    try input(&editor, "text", "draft");
    try input(&editor, "up", "");
    try textIs(&editor.minibuffer.document, "20+2");
    try input(&editor, "up", "");
    try textIs(&editor.minibuffer.document, "10+1");
    try input(&editor, "down", "");
    try input(&editor, "down", "");
    try textIs(&editor.minibuffer.document, "draft");
    try input(&editor, "escape", "");
    try input(&editor, "ctrl-l", "");
    try input(&editor, "up", "");
    try textIs(&editor.minibuffer.document, "20+2");
    try input(&editor, "ctrl-o", "");
    try input(&editor, "up", "");
    try textIs(&editor.minibuffer.document, "");
}

test "generic prompts supply completion and submit values through named commands" {
    var editor = try junc.Editor.init(allocator, "", null);
    defer editor.deinit();
    try evaluate(&editor, "editor.prompt{label='Fruit: ',history='fruit',complete=function(p) return {'pear','peach','apple'} end,submit=function(v) editor.invoke('insert',v) end}");
    try std.testing.expect(editor.minibuffer.context == .prompt);
    try input(&editor, "text", "ap");
    try input(&editor, "tab", "");
    try textIs(&editor.minibuffer.document, "apple");
    try input(&editor, "enter", "");
    try textIs(&editor.document, "apple");
    try std.testing.expect(editor.minibuffer.context == null);
}

test "VM reload preserves both input sessions and native histories while replacing temporary definitions" {
    var editor = try junc.Editor.init(allocator, "main", null);
    defer editor.deinit();
    try evaluate(&editor, "temporary=99; editor.command('temporary-command',function() end)");
    try input(&editor, "text", "unfinished");
    const session = editor.minibuffer.session;
    const cursor = try editor.minibuffer.target().position();
    const revision = editor.minibuffer.document.revision;
    const interaction = try editor.minibuffer.document.interactionRevision(session);
    try std.testing.expectError(error.LuaError, editor.reload("bad lua !!!"));
    try std.testing.expect(editor.minibuffer.context == .lua);
    try textIs(&editor.minibuffer.document, "unfinished");
    try editor.reload(null);
    try std.testing.expect(editor.minibuffer.context == .lua);
    try std.testing.expectEqual(session, editor.minibuffer.session);
    try std.testing.expectEqual(cursor, try editor.minibuffer.target().position());
    try std.testing.expectEqual(revision, editor.minibuffer.document.revision);
    try std.testing.expectEqual(interaction, try editor.minibuffer.document.interactionRevision(session));
    try evaluate(&editor, "temporary == nil and editor.commands['temporary-command']==nil");
    try std.testing.expectEqualStrings("true", lastOutput(&editor));
    try evaluate(&editor, "editor.prompt{submit=function(v) end}");
    try std.testing.expect(editor.minibuffer.context == .prompt);
    try editor.reload(null);
    try std.testing.expect(editor.minibuffer.context == null);
    try std.testing.expect(editor.minibuffer.history.items.len > 0);
    try std.testing.expect(editor.minibuffer.output.items.len <= junc.Minibuffer.output_count_max);
    try std.testing.expectEqual(@as(u32, 0), editor.document.revision);
}

test "prompt callback errors retain input and failed reload retains prompt callbacks" {
    var editor = try junc.Editor.init(allocator, "main", null);
    defer editor.deinit();
    try evaluate(&editor, "editor.prompt{label='Check: ',submit=function(v) if v~='okay' then error('try okay') end; editor.output(v) end}");
    try input(&editor, "text", "bad");
    try input(&editor, "enter", "");
    try std.testing.expect(editor.minibuffer.context == .prompt);
    try textIs(&editor.minibuffer.document, "bad");
    try std.testing.expect(std.mem.indexOf(u8, lastOutput(&editor), "try okay") != null);
    try std.testing.expectError(error.LuaError, editor.reload("invalid Lua !!!"));
    try input(&editor, "ctrl-a", "");
    try input(&editor, "text", "okay");
    try input(&editor, "enter", "");
    try std.testing.expect(editor.minibuffer.context == null);
    try std.testing.expectEqualStrings("okay", lastOutput(&editor));
    try std.testing.expectEqual(@as(u32, 0), editor.document.revision);
}

test "minibuffer Unicode cells share clipping selection and cursor precedence at every terminal size" {
    const vaxis = @import("vaxis");
    const Surface = @import("surface");
    var editor = try junc.Editor.init(allocator, "main", null);
    defer editor.deinit();
    try editor.setPreset("minimal");
    try editor.openMinibuffer(.lua);
    try input(&editor, "text", "界é");
    try input(&editor, "shift-left", "");
    const revision = editor.document.revision;
    const interaction = try editor.document.interactionRevision(editor.session);
    var surface: Surface = .{};
    defer surface.deinit(allocator);
    for ([_]u16{ 24, 8, 1 }) |columns| {
        const height: u16 = if (columns == 1) 1 else 6;
        var screen = try vaxis.Screen.init(allocator, .{ .rows = height, .cols = columns, .x_pixel = 0, .y_pixel = 0 });
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
        try surface.draw(&editor, win);
        const row: u16 = if (height == 1) 0 else height - 3;
        if (columns == 24) {
            const wide = win.readCell(5, row).?;
            try std.testing.expectEqualStrings("界", wide.char.grapheme);
            try std.testing.expectEqual(@as(u8, 2), wide.char.width);
            const cursor = win.readCell(7, row).?;
            try std.testing.expectEqualStrings("é", cursor.char.grapheme);
            try std.testing.expect(vaxis.Color.eql(cursor.style.bg, .{ .rgb = editor.presentation.theme.cursor_bg.rgb }));
        } else {
            // A one-cell viewport clips the wide grapheme while keeping the active cursor visible.
            const x: u16 = if (columns == 1) 0 else 7;
            try std.testing.expectEqualStrings("é", win.readCell(x, row).?.char.grapheme);
        }
    }
    try std.testing.expectEqual(revision, editor.document.revision);
    try std.testing.expectEqual(interaction, try editor.document.interactionRevision(editor.session));
    try textIs(&editor.document, "main");
}

test "reload requested by a live result observer waits for its Lua stack to return" {
    var editor = try junc.Editor.init(allocator, "", null);
    defer editor.deinit();
    try evaluate(&editor, "editor.on_result=function(r) if r.surface=='document' then editor.invoke('reload') end end");
    try input(&editor, "ctrl-g", "");
    try input(&editor, "text", "safe");
    try std.testing.expectEqual(@as(usize, 0), editor.runtime_depth);
    try std.testing.expect(!editor.reload_requested);
    try textIs(&editor.document, "safe");
    try input(&editor, "ctrl-z", "");
    try textIs(&editor.document, "");
}

test "invalid minibuffer presentation colors reject the complete replacement without losing live input" {
    var editor = try junc.Editor.init(allocator, "main", null);
    defer editor.deinit();
    try input(&editor, "ctrl-l", "");
    try input(&editor, "text", "draft");
    const state = editor.state;
    const frame = editor.presentation;
    const revision = editor.minibuffer.document.revision;
    const source = try std.mem.concat(allocator, u8, &.{
        "local p=(function()\n",                                                  junc.presentation.default_source,
        "\nend)(); p.presets.minimal.minibuffer={prompt_fg='invalid'}; return p",
    });
    defer allocator.free(source);
    try std.testing.expectError(error.InvalidPresentation, editor.reloadSources(null, source));
    try std.testing.expectEqual(state, editor.state);
    try std.testing.expectEqualDeep(frame, editor.presentation);
    try std.testing.expectEqual(revision, editor.minibuffer.document.revision);
    try textIs(&editor.minibuffer.document, "draft");
    try std.testing.expect(editor.minibuffer.context == .lua);
}

test "output is bounded sanitized and visible when a command returns focus" {
    var editor = try junc.Editor.init(allocator, "", null);
    defer editor.deinit();
    try evaluate(&editor, "for i=1,20 do print(i..'\\n界') end");
    try std.testing.expectEqual(junc.Minibuffer.output_count_max, editor.minibuffer.output.items.len);
    try std.testing.expectEqualStrings("20 界", editor.minibuffer.output.items[junc.Minibuffer.output_count_max - 2]);
    try evaluate(&editor, "editor.command('speak', function() editor.output('spoken') end)");
    try input(&editor, "ctrl-g", "");
    _ = try editor.invoke("speak", "");
    try std.testing.expectEqualStrings("spoken", editor.status());
    try std.testing.expectEqual(@as(u32, 0), editor.document.revision);
}
