//! Construction of the client's Lua policy VM: bundled registry, keymaps, runtime and presentation,
//! plus optional user sources. A candidate VM is built completely before an editor activates it.
const lua = @import("lua");
const Presentation = @import("Presentation.zig");

/// Creates an owning VM with the bundled policy. Release with lua_close. Native closures are bound
/// later, by the editor that activates it.
pub fn create() !*lua.lua_State {
    const state = lua.luaL_newstate() orelse return error.OutOfMemory;
    errdefer lua.lua_close(state);
    lua.luaL_openlibs(state);
    const commands = @embedFile("commands.lua");
    if (lua.luaL_loadbuffer(state, commands.ptr, commands.len, "commands") != 0) return error.LuaError;
    try evaluate(state, @embedFile("keymaps.lua"));
    if (lua.lua_pcall(state, 1, 1, 0) != 0) return error.LuaError;
    lua.lua_setfield(state, lua.LUA_GLOBALSINDEX, "editor");
    try evaluate(state, @embedFile("runtime.lua"));
    try applyToEditor(state);
    try evaluate(state, @embedFile("extension.lua"));
    try applyToEditor(state);
    try validateKeymaps(state);
    try loadPresentation(state, Presentation.default_source);
    return state;
}

/// Runs an extension module, a chunk returning function(editor). On error.LuaError the message is
/// on top of the stack.
pub fn loadExtension(state: *lua.lua_State, source: []const u8) !void {
    try evaluate(state, source);
    try applyToEditor(state);
}

/// Installs a presentation module, a chunk returning the presentation table. On error.LuaError the
/// message is on top of the stack. Validation is separate; see Presentation.validate.
pub fn loadPresentation(state: *lua.lua_State, source: []const u8) !void {
    try evaluate(state, source);
    lua.lua_setfield(state, lua.LUA_GLOBALSINDEX, "presentation");
}

// Leaves the chunk's single result on the stack.
fn evaluate(state: *lua.lua_State, source: []const u8) !void {
    if (lua.luaL_loadbuffer(state, source.ptr, source.len, "junc") != 0) return error.LuaError;
    if (lua.lua_pcall(state, 0, 1, 0) != 0) return error.LuaError;
}

// Calls the function on top of the stack with the editor table.
fn applyToEditor(state: *lua.lua_State) !void {
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    if (lua.lua_pcall(state, 1, 0, 0) != 0) return error.LuaError;
}

/// On failure leaves the Lua error available to the reload diagnostic.
pub fn validateKeymaps(state: *lua.lua_State) !void {
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    lua.lua_getfield(state, -1, "validate_keymaps");
    if (lua.lua_pcall(state, 0, 0, 0) != 0) return error.LuaError;
    lua.lua_settop(state, -2);
}

/// Selects the keymap context; reset also discards pending key sequences. Balances the stack.
pub fn setKeyContext(state: *lua.lua_State, context: []const u8, reset: bool) !void {
    const top = lua.lua_gettop(state);
    defer lua.lua_settop(state, top);
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    lua.lua_getfield(state, -1, "_keymap_focus");
    _ = lua.lua_pushlstring(state, context.ptr, context.len);
    lua.lua_pushboolean(state, @intFromBool(reset));
    if (lua.lua_pcall(state, 2, 0, 0) != 0) return error.LuaError;
}
