//! Live Lua facade. Native references stay in C closures; document writes invoke ordinary commands.
const std = @import("std");
const lua = @import("lua");
const Editor = @import("Editor.zig");
const Minibuffer = @import("Minibuffer.zig");
const minibuffer_input = @import("minibuffer_input.zig");

fn push(state: *lua.lua_State, value: []const u8) void {
    _ = lua.lua_pushlstring(state, value.ptr, value.len);
}

fn text(state: *lua.lua_State, index: c_int) ![]const u8 {
    if (lua.lua_type(state, index) != lua.LUA_TSTRING) return error.ExpectedString;
    var length: usize = 0;
    const bytes = lua.lua_tolstring(state, index, &length);
    return bytes[0..length];
}

fn host(state: *lua.lua_State) *Editor {
    // Lua 5.1's first C-closure upvalue, never a Lua-facing document handle.
    return @ptrCast(@alignCast(lua.lua_touserdata(state, lua.LUA_GLOBALSINDEX - 1).?));
}

fn fail(state: *lua.lua_State, message: []const u8) c_int {
    lua.lua_pushnil(state);
    push(state, message);
    return 2;
}

fn invokeCallback(maybe_state: ?*lua.lua_State) callconv(.c) c_int {
    const state = maybe_state.?;
    const editor = host(state);
    if (editor.runtime_depth == 0) return fail(state, "Commands require explicit user evaluation");
    const name = text(state, 1) catch |err| return fail(state, @errorName(err));
    const input = text(state, 2) catch |err| return fail(state, @errorName(err));
    const value = editor.invoke(name, input) catch |err| {
        const message = if (err == error.LuaError or err == error.ServerRejected)
            editor.status()
        else
            @errorName(err);
        return fail(state, message);
    };
    if (value) |owned| {
        var result = owned;
        defer result.deinit(editor.allocator);
        if (result == .validation_report) return fail(state, result.validation_report.message);
        lua.lua_createtable(state, 0, 3);
        push(state, @tagName(result));
        lua.lua_setfield(state, -2, "kind");
        const revision = switch (result) {
            .edit_event => |event| event.new_revision,
            .interaction_result => |event| event.document_revision,
            .validation_report => unreachable, // Rejections returned above.
        };
        const interaction = switch (result) {
            .edit_event => |event| event.interaction_revision,
            .interaction_result => |event| event.new_revision,
            .validation_report => unreachable,
        };
        const buffer = switch (result) {
            .edit_event => |event| event.buffer_id,
            .interaction_result => |event| event.buffer_id,
            .validation_report => unreachable,
        };
        lua.lua_pushinteger(state, buffer);
        lua.lua_setfield(state, -2, "buffer_id");
        lua.lua_pushinteger(state, revision);
        lua.lua_setfield(state, -2, "revision");
        lua.lua_pushinteger(state, interaction);
        lua.lua_setfield(state, -2, "interaction_revision");
    } else lua.lua_pushboolean(state, 1);
    return 1;
}

fn snapshotCallback(maybe_state: ?*lua.lua_State) callconv(.c) c_int {
    const state = maybe_state.?;
    const editor = host(state);
    editor.pushCommandContext(.document) catch |err| return fail(state, @errorName(err));
    return 1;
}

fn outputCallback(maybe_state: ?*lua.lua_State) callconv(.c) c_int {
    const state = maybe_state.?;
    const editor = host(state);
    if (editor.runtime_depth == 0) return fail(state, "Output requires explicit user evaluation");
    const value = text(state, 1) catch |err| return fail(state, @errorName(err));
    editor.minibuffer.appendOutput(value) catch |err| return fail(state, @errorName(err));
    if (editor.minibuffer.context == null) editor.report(value);
    lua.lua_pushboolean(state, 1);
    return 1;
}

fn promptCallback(maybe_state: ?*lua.lua_State) callconv(.c) c_int {
    const state = maybe_state.?;
    const editor = host(state);
    if (editor.runtime_depth == 0) return fail(state, "Prompts require an explicit command");
    const label = text(state, 1) catch |err| return fail(state, @errorName(err));
    const namespace = text(state, 2) catch |err| return fail(state, @errorName(err));
    const initial = text(state, 3) catch |err| return fail(state, @errorName(err));
    editor.minibuffer.open(.prompt, label, namespace, initial) catch |err|
        return fail(state, @errorName(err));
    editor.syncKeyContext() catch |err| return fail(state, @errorName(err));
    lua.lua_pushboolean(state, 1);
    return 1;
}

fn scrollCallback(maybe_state: ?*lua.lua_State) callconv(.c) c_int {
    const state = maybe_state.?;
    const editor = host(state);
    if (editor.runtime_depth == 0) return fail(state, "Viewport changes require explicit user evaluation");
    if (lua.lua_type(state, 1) != lua.LUA_TNUMBER) return fail(state, "ExpectedLine");
    const value = lua.lua_tonumber(state, 1);
    if (!std.math.isFinite(value) or value < 0 or value > std.math.maxInt(u32) or @floor(value) != value) {
        return fail(state, "ExpectedLine");
    }
    editor.scroll(@intFromFloat(value));
    lua.lua_pushboolean(state, 1);
    return 1;
}

fn inputActionCallback(maybe_state: ?*lua.lua_State) callconv(.c) c_int {
    const state = maybe_state.?;
    const editor = host(state);
    if (editor.runtime_depth == 0 or editor.minibuffer.context == null) {
        return fail(state, "Input actions require a focused minibuffer command");
    }
    const name = text(state, 1) catch |err| return fail(state, @errorName(err));
    const action = std.meta.stringToEnum(minibuffer_input.Action, name) orelse
        return fail(state, "Unknown input action");
    minibuffer_input.perform(editor, action) catch |err| return fail(state, @errorName(err));
    lua.lua_pushboolean(state, 1);
    return 1;
}

/// Installs closures only on the active VM and at a stable host address, never on reload
/// candidates.
pub fn bind(editor: *Editor) void {
    @import("buffer_api.zig").bind(editor);
    const state = editor.state;
    const top = lua.lua_gettop(state);
    defer lua.lua_settop(state, top);
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    const entries = .{
        .{ "_invoke", invokeCallback },            .{ "_state", snapshotCallback },
        .{ "_output", outputCallback },            .{ "_prompt", promptCallback },
        .{ "_input_action", inputActionCallback }, .{ "_scroll", scrollCallback },
    };
    inline for (entries) |entry| {
        lua.lua_pushlightuserdata(state, editor);
        lua.lua_pushcclosure(state, entry[1], 1);
        lua.lua_setfield(state, -2, entry[0]);
    }
}

/// Lua's parser accepts expressions first, then statements. Globals remain in the active VM.
pub fn evaluate(editor: *Editor, source: []const u8) !void {
    bind(editor);
    const state = editor.state;
    const top = lua.lua_gettop(state);
    defer lua.lua_settop(editor.state, if (editor.state == state) top else 0);
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    lua.lua_getfield(state, -1, "eval");
    push(state, source);
    if (editor.callLua(1, 1) != 0) {
        const message = text(state, -1) catch "Lua evaluation failed";
        try editor.minibuffer.appendOutput(message);
    } else try editor.minibuffer.appendOutput(try text(state, -1));
    try editor.finishDeferred();
}

/// One completion protocol for command names, Lua history and prompt-supplied providers.
pub fn complete(editor: *Editor) !void {
    const mini = &editor.minibuffer;
    if (mini.candidates.items.len > 0) return mini.cycleCandidate(false);
    const context = mini.context orelse return;
    const prefix = try mini.document.getText();
    defer editor.allocator.free(prefix);
    const state = editor.state;
    const top = lua.lua_gettop(state);
    defer lua.lua_settop(state, top);
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    lua.lua_getfield(state, -1, "completions");
    push(state, @tagName(context));
    push(state, prefix);
    lua.lua_createtable(state, 0, 0);
    var count: c_int = 0;
    for (mini.history.items) |item| {
        if (!std.mem.eql(u8, item.namespace, mini.historyNamespace())) continue;
        if (!Minibuffer.printable(item.text)) continue;
        count += 1;
        push(state, item.text);
        lua.lua_rawseti(state, -2, count);
    }
    if (editor.callLua(3, 1) != 0) {
        try mini.appendOutput(text(state, -1) catch "Completion failed");
        return;
    }
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) return error.InvalidCompletion;
    errdefer mini.clearCandidates();
    const length = @min(lua.lua_objlen(state, -1), Minibuffer.candidate_count_max);
    for (0..length) |index| {
        lua.lua_rawgeti(state, -1, @intCast(index + 1));
        const value = try text(state, -1);
        if (!Minibuffer.printable(value) or !std.mem.startsWith(u8, value, prefix)) {
            return error.InvalidCompletion;
        }
        const owned = try editor.allocator.dupe(u8, value);
        mini.candidates.append(editor.allocator, owned) catch |err| {
            editor.allocator.free(owned);
            return err;
        };
        lua.lua_settop(state, -2);
    }
    if (length == 0) return mini.appendOutput("No completions");
    if (length == 1) {
        try mini.setText(mini.candidates.items[0]);
        mini.clearCandidates();
        return;
    }
    const first = mini.candidates.items[0];
    var shared = first.len;
    for (mini.candidates.items[1..]) |candidate| {
        var index: usize = 0;
        while (index < @min(shared, candidate.len) and first[index] == candidate[index]) : (index += 1) {}
        shared = index;
    }
    var clusters = @import("litura").segmentation.graphemeIterator(first);
    var safe: usize = 0;
    while (clusters.next()) |cluster| {
        if (safe + cluster.len > shared) break;
        safe += cluster.len;
    }
    if (safe > prefix.len) try mini.setText(first[0..safe]);
}

pub fn submitPrompt(editor: *Editor, source: []const u8) !bool {
    const state = editor.state;
    const top = lua.lua_gettop(state);
    defer lua.lua_settop(state, top);
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    lua.lua_getfield(state, -1, "active_prompt");
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) return error.PromptUnavailable;
    lua.lua_getfield(state, -1, "submit");
    push(state, source);
    if (editor.callLua(1, 0) != 0) {
        try editor.minibuffer.appendOutput(text(state, -1) catch "Prompt callback failed");
        return false;
    }
    return true;
}
