//! Lua's buffer controls. These operate on the current connection, never expose engines or sockets.
const std = @import("std");
const lua = @import("lua");
const Editor = @import("Editor.zig");

fn host(state: *lua.lua_State) *Editor {
    return @ptrCast(@alignCast(lua.lua_touserdata(state, lua.LUA_GLOBALSINDEX - 1).?));
}
fn push(state: *lua.lua_State, value: []const u8) void {
    _ = lua.lua_pushlstring(state, value.ptr, value.len);
}
fn fail(state: *lua.lua_State, message: []const u8) c_int {
    lua.lua_pushnil(state);
    push(state, message);
    return 2;
}
fn text(state: *lua.lua_State, index: c_int) ![]const u8 {
    if (lua.lua_type(state, index) != lua.LUA_TSTRING) return error.ExpectedString;
    var length: usize = 0;
    const value = lua.lua_tolstring(state, index, &length);
    return value[0..length];
}
fn id(state: *lua.lua_State, index: c_int) !u32 {
    if (lua.lua_type(state, index) != lua.LUA_TNUMBER) return error.ExpectedBufferId;
    const value = lua.lua_tonumber(state, index);
    if (!std.math.isFinite(value) or value < 1 or value > std.math.maxInt(u32) or @floor(value) != value) {
        return error.ExpectedBufferId;
    }
    return @intFromFloat(value);
}
fn failureMessage(editor: *Editor, fallback: []const u8) []const u8 {
    if (editor.remote) |remote| if (remote.errorMessage().len > 0) return remote.errorMessage();
    return fallback;
}
fn explicit(state: *lua.lua_State) bool {
    return host(state).runtime_depth != 0;
}

fn listCallback(maybe_state: ?*lua.lua_State) callconv(.c) c_int {
    const state = maybe_state.?;
    const editor = host(state);
    const remote = editor.remote orelse return fail(state, "ServerRequired");
    const response = remote.call(.{ .id = 0, .op = .list }) catch |err|
        return fail(state, failureMessage(editor, @errorName(err)));
    defer response.deinit();
    lua.lua_createtable(state, 0, 0);
    for (response.value.buffers, 0..) |buffer, index| {
        lua.lua_createtable(state, 0, 5);
        lua.lua_pushinteger(state, buffer.id);
        lua.lua_setfield(state, -2, "id");
        push(state, buffer.name);
        lua.lua_setfield(state, -2, "name");
        if (buffer.path) |path| push(state, path) else lua.lua_pushnil(state);
        lua.lua_setfield(state, -2, "path");
        lua.lua_pushinteger(state, buffer.revision);
        lua.lua_setfield(state, -2, "revision");
        lua.lua_pushboolean(state, @intFromBool(buffer.dirty));
        lua.lua_setfield(state, -2, "dirty");
        lua.lua_rawseti(state, -2, @intCast(index + 1));
    }
    return 1;
}
fn openCallback(maybe_state: ?*lua.lua_State) callconv(.c) c_int {
    const state = maybe_state.?;
    const editor = host(state);
    if (!explicit(state)) return fail(state, "Opening a buffer requires explicit command evaluation");
    const path = text(state, 1) catch |err| return fail(state, @errorName(err));
    editor.openFile(if (path.len == 0) null else path) catch |err|
        return fail(state, failureMessage(editor, @errorName(err)));
    lua.lua_pushinteger(state, editor.mainTarget().bufferId());
    return 1;
}
fn selectCallback(maybe_state: ?*lua.lua_State) callconv(.c) c_int {
    const state = maybe_state.?;
    const editor = host(state);
    if (!explicit(state)) return fail(state, "Selecting a buffer requires explicit command evaluation");
    const buffer = id(state, 1) catch |err| return fail(state, @errorName(err));
    editor.selectBuffer(buffer) catch |err| return fail(state, failureMessage(editor, @errorName(err)));
    lua.lua_pushboolean(state, 1);
    return 1;
}
fn killCallback(maybe_state: ?*lua.lua_State) callconv(.c) c_int {
    const state = maybe_state.?;
    const editor = host(state);
    if (!explicit(state)) return fail(state, "Killing a buffer requires explicit command evaluation");
    const buffer = id(state, 1) catch |err| return fail(state, @errorName(err));
    if (lua.lua_type(state, 2) != lua.LUA_TBOOLEAN) return fail(state, "ExpectedDiscardFlag");
    editor.killBuffer(buffer, lua.lua_toboolean(state, 2) != 0) catch |err|
        return fail(state, failureMessage(editor, @errorName(err)));
    lua.lua_pushboolean(state, 1);
    return 1;
}
fn saveCallback(maybe_state: ?*lua.lua_State) callconv(.c) c_int {
    const state = maybe_state.?;
    const editor = host(state);
    if (!explicit(state)) return fail(state, "Saving requires explicit command evaluation");
    const path = text(state, 1) catch |err| return fail(state, @errorName(err));
    editor.saveAs(path) catch |err| return fail(state, failureMessage(editor, @errorName(err)));
    lua.lua_pushboolean(state, 1);
    return 1;
}
fn shutdownCallback(maybe_state: ?*lua.lua_State) callconv(.c) c_int {
    const state = maybe_state.?;
    const editor = host(state);
    if (!explicit(state)) return fail(state, "Shutdown requires explicit command evaluation");
    editor.shutdownServer() catch |err| return fail(state, failureMessage(editor, @errorName(err)));
    lua.lua_pushboolean(state, 1);
    return 1;
}

pub fn bind(editor: *Editor) void {
    const state = editor.state;
    const top = lua.lua_gettop(state);
    defer lua.lua_settop(state, top);
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    const entries = .{
        .{ "_buffers", listCallback },         .{ "_open_file", openCallback },
        .{ "_select_buffer", selectCallback }, .{ "_kill_buffer", killCallback },
        .{ "_save_as", saveCallback },         .{ "_shutdown_server", shutdownCallback },
    };
    inline for (entries) |entry| {
        lua.lua_pushlightuserdata(state, editor);
        lua.lua_pushcclosure(state, entry[1], 1);
        lua.lua_setfield(state, -2, entry[0]);
    }
}
