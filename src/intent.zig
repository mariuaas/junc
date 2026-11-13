//! Decodes the table a Lua command returns. Decoding validates types, ranges and UTF-8; it never
//! performs the intent. Strings borrow Lua values the caller keeps on the stack until it is done.
const std = @import("std");
const lua = @import("lua");
const protocol = @import("protocol.zig");

/// Every kind a command may return. Client kinds act on this editor; the rest edit a document.
pub const Kind = enum {
    @"key-feedback",
    quit,
    save,
    reload,
    minibuffer,
    presentation,
    replace,
    move,
    undo,
    redo,
    batch,
    selections,
    add_next,

    /// The minibuffer edits its own input and can reload or switch prompts; other client actions
    /// need the document focused.
    pub fn availableInMinibuffer(self: Kind) bool {
        return switch (self) {
            .replace, .move, .undo, .redo, .batch, .reload, .minibuffer, .@"key-feedback" => true,
            .quit, .save, .presentation, .selections, .add_next => false,
        };
    }
};

/// Observation origins applied when the intent does not name its own.
pub const Origins = struct { buffer: u32, revision: u32, interaction_revision: u32 };

/// Reads the kind. Null means a string naming no known kind. On error.LuaError the Lua message is
/// left on top of the stack.
pub fn kind(state: *lua.lua_State, table: c_int) !?Kind {
    return std.meta.stringToEnum(Kind, try string(state, table, "kind"));
}

/// Reads a required string field and leaves it rooted on the stack, so the returned slice remains
/// valid until the caller restores the stack. Rejects other types with InvalidCommand.
pub fn string(state: *lua.lua_State, table: c_int, name: [:0]const u8) ![]const u8 {
    try pushField(state, table, name);
    if (lua.lua_type(state, -1) != lua.LUA_TSTRING) return error.InvalidCommand;
    var len: usize = 0;
    const ptr = lua.lua_tolstring(state, -1, &len);
    return ptr[0..len];
}

/// Decodes a document edit without restamping explicitly captured observation origins. A named
/// buffer other than origins.buffer is BufferChanged; malformed fields are InvalidCommand.
pub fn edit(
    allocator: std.mem.Allocator,
    state: *lua.lua_State,
    table: c_int,
    edit_kind: Kind,
    origins: Origins,
) !protocol.Edit {
    if (try optionalNumber(state, table, "buffer_id")) |id| {
        if (id != origins.buffer) return error.BufferChanged;
    }
    var result: protocol.Edit = .{
        .kind = switch (edit_kind) {
            .replace => .replace,
            .move => .move,
            .undo => .undo,
            .redo => .redo,
            .batch => .batch,
            .selections => .selections,
            .add_next => .add_next,
            else => return error.InvalidCommand,
        },
        .origin = (try optionalNumber(state, table, "origin")) orelse origins.revision,
        .interaction_origin = (try optionalNumber(state, table, "interaction_origin")) orelse
            origins.interaction_revision,
        .source = try string(state, table, "source"),
    };
    switch (result.kind) {
        .replace => {
            result.start = try number(state, table, "start");
            result.finish = try number(state, table, "finish");
            result.text = try string(state, table, "text");
            if (!std.unicode.utf8ValidateSlice(result.text)) return error.InvalidUtf8;
        },
        .move => {
            result.position = try number(state, table, "position");
            result.mark = try optionalNumber(state, table, "mark");
        },
        .batch, .selections => {
            try pushField(state, table, "edits");
            if (lua.lua_type(state, -1) != lua.LUA_TTABLE) return error.InvalidCommand;
            const list = lua.lua_gettop(state);
            const length = lua.lua_objlen(state, list);
            if (length == 0 or length > std.math.maxInt(c_int)) return error.InvalidCommand;
            const edits = try allocator.alloc(protocol.CursorEdit, length);
            for (edits, 0..) |*value, index| {
                lua.lua_rawgeti(state, list, @intCast(index + 1));
                if (lua.lua_type(state, -1) != lua.LUA_TTABLE) return error.InvalidCommand;
                const item = lua.lua_gettop(state);
                value.* = .{
                    .kind = std.meta.stringToEnum(
                        @FieldType(protocol.CursorEdit, "kind"),
                        try string(state, item, "kind"),
                    ) orelse return error.InvalidCommand,
                    .cursor_anchor = (try optionalNumber(state, item, "cursor_anchor")) orelse 0,
                };
                switch (value.kind) {
                    .replace => {
                        value.start = try number(state, item, "start");
                        value.finish = try number(state, item, "finish");
                        value.text = try string(state, item, "text");
                        if (!std.unicode.utf8ValidateSlice(value.text)) return error.InvalidUtf8;
                    },
                    .move => {
                        value.position = try number(state, item, "position");
                        value.mark = try optionalNumber(state, item, "mark");
                    },
                    .keep => {},
                }
                // Release each Lua item after copying its only borrowed payload into the arena.
                value.text = try allocator.dupe(u8, value.text);
                lua.lua_settop(state, list);
            }
            result.edits = edits;
        },
        .undo, .redo, .add_next => {},
    }
    return result;
}

// A computed intent field is Lua code too. Keep ordinary tables on the direct lookup path.
fn pushField(state: *lua.lua_State, table: c_int, name: [:0]const u8) !void {
    if (lua.lua_getmetatable(state, table) == 0) {
        lua.lua_getfield(state, table, name);
        return;
    }
    lua.lua_settop(state, -2);
    lua.lua_pushcclosure(state, fieldCallback, 0);
    lua.lua_pushvalue(state, table);
    _ = lua.lua_pushlstring(state, name.ptr, name.len);
    // This is decoding, not a new explicit command scope; the editor's runtime depth is unchanged.
    if (lua.lua_pcall(state, 2, 1, 0) != 0) return error.LuaError;
}

fn fieldCallback(maybe_state: ?*lua.lua_State) callconv(.c) c_int {
    const state = maybe_state.?;
    lua.lua_pushvalue(state, 2);
    // Any metamethod error unwinds only this resource-free C callback into lua_pcall.
    lua.lua_gettable(state, 1);
    return 1;
}

fn number(state: *lua.lua_State, table: c_int, name: [:0]const u8) !u32 {
    try pushField(state, table, name);
    defer lua.lua_settop(state, -2);
    if (lua.lua_type(state, -1) != lua.LUA_TNUMBER) return error.InvalidCommand;
    const value = lua.lua_tonumber(state, -1);
    if (!std.math.isFinite(value) or value < 0 or value > std.math.maxInt(u32) or
        @floor(value) != value)
    {
        return error.InvalidCommand;
    }
    return @intFromFloat(value);
}

// A present computed field is evaluated twice: once to test for nil, then to decode it.
fn optionalNumber(state: *lua.lua_State, table: c_int, name: [:0]const u8) !?u32 {
    try pushField(state, table, name);
    const missing = lua.lua_type(state, -1) == lua.LUA_TNIL;
    lua.lua_settop(state, -2);
    return if (missing) null else try number(state, table, name);
}
