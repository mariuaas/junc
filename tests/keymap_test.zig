//! Layer precedence, trie ownership and VM replacement through the public editor host.
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

fn textIs(editor: *junc.Editor, expected: []const u8) !void {
    const text = try editor.document.getText();
    defer allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

fn lastOutput(editor: *junc.Editor) []const u8 {
    const output = editor.minibuffer.output.items;
    return output[output.len - 1];
}

fn evaluate(editor: *junc.Editor, source: []const u8) !void {
    try editor.openMinibuffer(.lua);
    try input(editor, "text", source);
    try input(editor, "enter", "");
}

test "transient priority and recency precede context and global maps while document edits share submissions" {
    var editor = try junc.Editor.init(allocator, "", null);
    defer editor.deinit();
    try editor.reload(
        \\return function(e)
        \\ for _, name in ipairs({'G','C','A','B'}) do
        \\   local text=name; e.command(name,function(c) return e.replace(c,text) end)
        \\ end
        \\ e.bind('j','G')
        \\ e.keymap('document',{j='C'})
        \\ e.keymap('a',{j='A'},{priority=10})
        \\ e.keymap('b',{j='B'},{priority=5})
        \\ e.push_keymap('a'); e.push_keymap('b')
        \\end
    );
    try input(&editor, "text", "j");
    try textIs(&editor, "A");
    try evaluate(&editor, "editor.pop_keymap()");
    try std.testing.expectEqualStrings("a", lastOutput(&editor));
    try input(&editor, "ctrl-g", "");
    try input(&editor, "text", "j");
    try textIs(&editor, "AB");
    try evaluate(&editor, "editor.keymap('a',{j='A'},{priority=5}); editor.push_keymap('a')");
    try input(&editor, "ctrl-g", "");
    try input(&editor, "text", "j");
    try textIs(&editor, "ABA");
    try evaluate(&editor, "editor.pop_keymap(); editor.pop_keymap()");
    try input(&editor, "ctrl-g", "");
    try input(&editor, "text", "j");
    try textIs(&editor, "ABAC");
    try evaluate(&editor, "editor.keymap('document',{})");
    try input(&editor, "ctrl-g", "");
    try input(&editor, "text", "j");
    try textIs(&editor, "ABACG");
    try std.testing.expectEqual(@as(u32, 5), editor.document.revision);
    try evaluate(&editor, "editor.last_result.surface");
    try std.testing.expectEqualStrings("minibuffer", lastOutput(&editor));
    try input(&editor, "ctrl-g", "");
    try input(&editor, "ctrl-z", "");
    try textIs(&editor, "ABAC");
}

test "a winning layer owns its whole prefix and invalid continuation never inserts or falls through" {
    var editor = try junc.Editor.init(allocator, "abc", null);
    defer editor.deinit();
    try editor.reload(
        \\return function(e)
        \\ e.bind('g g','buffer-end'); e.bind('g x','buffer-end')
        \\ e.keymap('navigation',{['g g']='buffer-start',escape='keymap.pop'})
        \\ e.push_keymap('navigation')
        \\end
    );
    try input(&editor, "end", "");
    const revision = editor.document.revision;
    const interaction = try editor.document.interactionRevision(editor.session);
    try input(&editor, "text", "g");
    try std.testing.expect(std.mem.indexOf(u8, editor.status(), "g -> buffer-start") != null);
    try std.testing.expectEqual(interaction, try editor.document.interactionRevision(editor.session));
    try input(&editor, "text", "x");
    try std.testing.expect(std.mem.startsWith(u8, editor.status(), "Unbound sequence:"));
    try std.testing.expectEqual(@as(u32, 3), try editor.position());
    try input(&editor, "text", "g");
    try input(&editor, "text", "g");
    try std.testing.expectEqual(@as(u32, 0), try editor.position());
    try input(&editor, "text", "g");
    try input(&editor, "escape", "");
    try std.testing.expectEqualStrings("Prefix cancelled", editor.status());
    try input(&editor, "text", "g");
    try input(&editor, "ctrl-g", "");
    try std.testing.expectEqualStrings("Prefix cancelled", editor.status());
    try std.testing.expectEqual(revision, editor.document.revision);
    try textIs(&editor, "abc");
    try input(&editor, "escape", "");
    try std.testing.expectEqualStrings("Popped navigation", editor.status());
    try input(&editor, "text", "g");
    try input(&editor, "text", "g");
    try std.testing.expectEqual(@as(u32, 3), try editor.position());
}

test "a direct binding shadows a lower prefix and a higher prefix shadows a lower direct command" {
    var editor = try junc.Editor.init(allocator, "abc", null);
    defer editor.deinit();
    try editor.reload(
        \\return function(e)
        \\ e.bind('ctrl-x ctrl-s',nil); e.bind('ctrl-x ctrl-r',nil)
        \\ e.bind('ctrl-x','buffer-start')
        \\ e.keymap('navigation',{['ctrl-x ctrl-s']='buffer-end',escape='keymap.pop'})
        \\ e.push_keymap('navigation')
        \\end
    );
    try input(&editor, "ctrl-x", "");
    try std.testing.expect(std.mem.indexOf(u8, editor.status(), "ctrl-s -> buffer-end") != null);
    try input(&editor, "ctrl-s", "");
    try std.testing.expectEqual(@as(u32, 3), try editor.position());
    try evaluate(&editor, "editor.keymap('navigation',{['ctrl-x']='buffer-start',escape='keymap.pop'}); editor.bind('ctrl-x',nil); editor.bind('ctrl-x ctrl-s','buffer-end')");
    try input(&editor, "ctrl-g", "");
    try input(&editor, "ctrl-x", "");
    try std.testing.expectEqual(@as(u32, 0), try editor.position());
    try std.testing.expect(std.mem.indexOf(u8, editor.status(), "...") == null);
    try evaluate(&editor, "local s=editor.keymap_state(); for _, b in ipairs(s.bindings) do if b.map=='global' and b.sequence=='ctrl-x ctrl-s' then return b.shadowed_by end end");
    try std.testing.expectEqualStrings("navigation", lastOutput(&editor));
}

test "overlapping or malformed map replacements are atomic including the pending prefix" {
    var editor = try junc.Editor.init(allocator, "abc", null);
    defer editor.deinit();
    try evaluate(&editor,
        \\editor.keymap('nav',{['g g']='buffer-end'}); editor.push_keymap('nav');
        \\editor.dispatch('text',{surface='document'},'g');
        \\local bad={ {g='home',['g g']='end'}, {g=42} };
        \\for _,bindings in ipairs(bad) do assert(not pcall(editor.keymap,'nav',bindings)) end;
        \\assert(not pcall(editor.keymap,'nav',{g='home'},{priority=false}));
        \\assert(not pcall(editor.bind,'ctrl-x','save'));
        \\assert(editor.keymap_state().pending.sequence=='g');
        \\assert(editor.keymap_info('nav').bindings[1].sequence=='g g'); return 'atomic'
    );
    try std.testing.expectEqualStrings("atomic", lastOutput(&editor));
    try std.testing.expectEqual(@as(u32, 0), editor.document.revision);
    try input(&editor, "ctrl-g", "");
    try input(&editor, "text", "g");
    try input(&editor, "text", "g");
    try std.testing.expectEqual(@as(u32, 3), try editor.position());
}

test "document transient maps cannot intercept minibuffer keys and explicit minibuffer maps can override them" {
    var editor = try junc.Editor.init(allocator, "main", null);
    defer editor.deinit();
    try editor.reload(
        \\return function(e)
        \\ e.keymap('navigation',{j='down',enter='buffer-end',tab='buffer-end',escape='keymap.pop'})
        \\ e.push_keymap('navigation')
        \\ e.keymap('input',{j='left'})
        \\end
    );
    try input(&editor, "shift-right", "");
    const position = try editor.position();
    const mark = try editor.mark();
    const interaction = try editor.document.interactionRevision(editor.session);
    try input(&editor, "ctrl-l", "");
    try input(&editor, "text", "'j'");
    try input(&editor, "enter", "");
    try std.testing.expectEqualStrings("j", lastOutput(&editor));
    try evaluate(&editor, "editor.push_keymap('input',{context='minibuffer'}); return editor.keymap_state('minibuffer').focused");
    try std.testing.expectEqualStrings("minibuffer", lastOutput(&editor));
    try input(&editor, "text", "a");
    try input(&editor, "text", "j");
    try std.testing.expectEqual(@as(u32, 0), try editor.minibuffer.target().position());
    try input(&editor, "escape", "");
    try std.testing.expect(editor.minibuffer.context == null);
    try std.testing.expectEqual(position, try editor.position());
    try std.testing.expectEqual(mark, try editor.mark());
    try std.testing.expectEqual(interaction, try editor.document.interactionRevision(editor.session));
    try std.testing.expectEqual(@as(u32, 0), editor.document.revision);
    try textIs(&editor, "main");
}

test "focus and successful reload cancel pending prefixes while failed configuration retains maps and state" {
    var editor = try junc.Editor.init(allocator, "", null);
    defer editor.deinit();
    try input(&editor, "text", "abc");
    try input(&editor, "shift-left", "");
    try editor.reload("return function(e) e.keymap('nav',{['g g']='buffer-start'}); e.push_keymap('nav') end");
    try input(&editor, "text", "g");
    const state = editor.state;
    const revision = editor.document.revision;
    const interaction = try editor.document.interactionRevision(editor.session);
    const position = try editor.position();
    const mark = try editor.mark();
    const undo = editor.document.undo_stack.items.len;
    try std.testing.expectError(error.LuaError, editor.reload("return function(e) e.keymap('bad',{g='left',['g g']='right'}) end"));
    try std.testing.expectEqual(state, editor.state);
    try std.testing.expectError(error.LuaError, editor.reloadSources(
        "return function(e) e.keymap('nav',{g='buffer-end'}); e.push_keymap('nav') end",
        "invalid presentation Lua !!!",
    ));
    try std.testing.expectEqual(state, editor.state);
    try input(&editor, "text", "g");
    try std.testing.expectEqual(@as(u32, 0), try editor.position());
    try input(&editor, "text", "g");
    try editor.openMinibuffer(.command);
    try input(&editor, "ctrl-g", "");
    try input(&editor, "text", "g");
    try std.testing.expect(std.mem.startsWith(u8, editor.status(), "g ..."));
    try editor.reload("return function(e) e.bind('x','buffer-end') end");
    try input(&editor, "text", "x");
    try std.testing.expectEqual(@as(u32, 3), try editor.position());
    try std.testing.expectEqual(revision, editor.document.revision);
    try std.testing.expectEqual(undo, editor.document.undo_stack.items.len);
    // A successful reload itself must preserve every interaction field exactly.
    try input(&editor, "shift-left", "");
    const next_position = try editor.position();
    const next_mark = try editor.mark();
    const next_interaction = try editor.document.interactionRevision(editor.session);
    try editor.reload(null);
    try std.testing.expectEqual(next_position, try editor.position());
    try std.testing.expectEqual(next_mark, try editor.mark());
    try std.testing.expectEqual(next_interaction, try editor.document.interactionRevision(editor.session));
    try std.testing.expectEqual(@as(u32, 2), position);
    try std.testing.expect(mark != null and interaction > 0);
    try input(&editor, "ctrl-z", "");
    try textIs(&editor, "");
}

test "unavailable keymap commands reject reload and never cause text fallback during live dispatch" {
    var editor = try junc.Editor.init(allocator, "", null);
    defer editor.deinit();
    const state = editor.state;
    try std.testing.expectError(error.LuaError, editor.reload("return function(e) e.keymap('bad',{j='missing'}) end"));
    try std.testing.expectEqual(state, editor.state);
    try evaluate(&editor, "editor.keymap('bad',{j='missing'}); editor.push_keymap('bad')");
    try input(&editor, "ctrl-g", "");
    try std.testing.expectError(error.LuaError, editor.dispatch("text", "j"));
    try std.testing.expect(std.mem.indexOf(u8, editor.status(), "missing") != null);
    try textIs(&editor, "");
}

test "introspection reports active layers bindings shadowing and sorted pending continuations as copies" {
    var editor = try junc.Editor.init(allocator, "abc", null);
    defer editor.deinit();
    try evaluate(&editor,
        \\editor.bind('g g','buffer-end'); editor.keymap('nav',{['g a']='home',['g z']='end'});
        \\editor.push_keymap('nav'); editor.dispatch('text',{surface='document'},'g');
        \\local state=editor.keymap_state(); assert(state.layers[1].kind=='transient');
        \\assert(state.pending.map=='nav' and state.pending.sequence=='g');
        \\assert(state.pending.continuations[1].key=='a' and state.pending.continuations[2].key=='z');
        \\local found=false; for _,b in ipairs(state.bindings) do
        \\  if b.map=='global' and b.sequence=='g g' then assert(b.shadowed_by=='nav'); found=true end
        \\end; assert(found); state.layers[1].name='changed'; state.pending.continuations[1].key='changed';
        \\assert(editor.keymap_state().layers[1].name=='nav');
        \\assert(editor.keymap_state().pending.continuations[1].key=='a'); return 'reflected'
    );
    try std.testing.expectEqualStrings("reflected", lastOutput(&editor));
    try std.testing.expectEqual(@as(u32, 0), editor.document.revision);
    try input(&editor, "ctrl-g", "");
    try input(&editor, "ctrl-o", "");
    try input(&editor, "text", "describe-keymap");
    try input(&editor, "enter", "");
    try input(&editor, "text", "nav");
    try input(&editor, "tab", "");
    try input(&editor, "enter", "");
    try std.testing.expect(std.mem.indexOf(u8, lastOutput(&editor), "nav [active]") != null);
    try std.testing.expect(std.mem.indexOf(u8, lastOutput(&editor), "g a -> home") != null);
}

test "space Unicode and deep sequences use normalized events without splitting text chunks" {
    var editor = try junc.Editor.init(allocator, "abc", null);
    defer editor.deinit();
    try editor.reload(
        \\return function(e)
        \\ e.keymap('nav',{['space']='buffer-end',['界']='buffer-start',['g g g']='buffer-end'})
        \\ e.push_keymap('nav')
        \\end
    );
    try input(&editor, "text", " ");
    try std.testing.expectEqual(@as(u32, 3), try editor.position());
    try input(&editor, "text", "界");
    try std.testing.expectEqual(@as(u32, 0), try editor.position());
    try input(&editor, "text", "g");
    try input(&editor, "text", "g");
    try std.testing.expect(std.mem.startsWith(u8, editor.status(), "g g ..."));
    try input(&editor, "text", "g");
    try std.testing.expectEqual(@as(u32, 3), try editor.position());
    try std.testing.expectEqual(@as(u32, 0), editor.document.revision);
    try input(&editor, "text", "gg");
    try textIs(&editor, "abcgg");
}
