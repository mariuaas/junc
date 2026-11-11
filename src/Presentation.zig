//! Validated, owned presentation values. Lua chooses policy; no terminal or document writes.
const std = @import("std");
const syntax = @import("syntax.zig");
const lua = @import("lua");

/// Embedded fallback, also used when no presentation file is present.
pub const default_source = @embedFile("presentation.lua");

pub const Color = union(enum) { default, index: u8, rgb: [3]u8 };
pub const Theme = struct {
    fg: Color,
    bg: Color,
    selection_fg: Color,
    selection_bg: Color,
    cursor_fg: Color,
    cursor_bg: Color,
    gutter_fg: Color,
    gutter_bg: Color,
    status_fg: Color,
    status_bg: Color,
};

/// Missing reports remain terminal-default or indexed colors; no query is required to succeed.
pub const Terminal = struct {
    foreground: Color = .default,
    background: Color = .default,
    palette: [16]Color = initialPalette(),

    fn initialPalette() [16]Color {
        var colors: [16]Color = undefined;
        for (&colors, 0..) |*color, index| color.* = .{ .index = @intCast(index) };
        return colors;
    }
};

pub const Viewport = struct { width: u32 = 80, height: u32 = 24, top: u32 = 0, left: u32 = 0 };
/// Borrowed observation strings remain valid through resolve/validate; Lua receives copied strings.
pub const Context = struct {
    buffer_id: u32,
    name: []const u8,
    path: []const u8,
    message: []const u8,
    dirty: bool,
    cursor: u32,
    mark: ?u32,
    line: u32,
    column: u32,
    count: u32,
    lines: u32,
    revision: u32,
    interaction_revision: u32,
    width: u32,
    height: u32,
    top: u32,
    left: u32,
};

/// Bounded preset names and status text are copied out of Lua, so VM replacement is safe.
pub const Name = struct {
    bytes: [64]u8 = @splat(0),
    len: usize = 0,

    pub fn init(text: []const u8) !Name {
        if (text.len == 0 or text.len >= 64 or !validText(text)) return error.InvalidPresentation;
        var name: Name = .{};
        @memcpy(name.bytes[0..text.len], text);
        name.len = text.len;
        return name;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// An omitted category or foreground inherits base text. Attributes default to false.
pub const SyntaxStyle = struct {
    fg: ?Color = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
};

/// Optional prompt colors inherit the current theme; no terminal structures cross into Lua.
pub const MinibufferStyle = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    prompt_fg: ?Color = null,
    output_fg: ?Color = null,
};

/// Self-contained presentation values, safe to retain after Lua VM replacement.
pub const Frame = struct {
    theme: Theme,
    minibuffer: MinibufferStyle = .{},
    syntax: [syntax.category_count]SyntaxStyle = @splat(.{}),
    gutter_visible: bool,
    line_numbers: bool,
    status_visible: bool,
    status_bytes: [4096]u8 = @splat(0),
    status_len: usize,

    pub fn status(self: *const Frame) []const u8 {
        return self.status_bytes[0..self.status_len];
    }
};

fn pop(state: *lua.lua_State) void {
    lua.lua_settop(state, -2);
}

fn pushString(state: *lua.lua_State, text: []const u8) void {
    _ = lua.lua_pushlstring(state, text.ptr, text.len);
}

fn textAt(state: *lua.lua_State, index: c_int) ![]const u8 {
    if (lua.lua_type(state, index) != lua.LUA_TSTRING) return error.InvalidPresentation;
    var len: usize = 0;
    const ptr = lua.lua_tolstring(state, index, &len);
    return ptr[0..len];
}

fn validText(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |byte| if (byte < 32 or byte == 127) return false;
    return true;
}

fn boolean(state: *lua.lua_State, name: [:0]const u8) !bool {
    lua.lua_getfield(state, -1, name);
    defer pop(state);
    if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) return error.InvalidPresentation;
    return lua.lua_toboolean(state, -1) != 0;
}

fn colorAt(state: *lua.lua_State) !Color {
    if (lua.lua_type(state, -1) == lua.LUA_TNUMBER) {
        const value = lua.lua_tonumber(state, -1);
        if (!std.math.isFinite(value) or value < 0 or value > 255 or @floor(value) != value) {
            return error.InvalidPresentation;
        }
        return .{ .index = @intFromFloat(value) };
    }
    const text = try textAt(state, -1);
    if (std.mem.eql(u8, text, "default")) return .default;
    if (text.len != 7 or text[0] != '#') return error.InvalidPresentation;
    for (text[1..]) |byte| if (!std.ascii.isHex(byte)) return error.InvalidPresentation;
    var rgb: [3]u8 = undefined;
    for (&rgb, 0..) |*channel, index| {
        const offset = 1 + index * 2;
        channel.* = std.fmt.parseInt(u8, text[offset .. offset + 2], 16) catch
            return error.InvalidPresentation;
    }
    return .{ .rgb = rgb };
}

fn pushColor(state: *lua.lua_State, color: Color) void {
    switch (color) {
        .default => pushString(state, "default"),
        .index => |index| lua.lua_pushinteger(state, index),
        .rgb => |rgb| {
            // Three u8 channels produce exactly six hex digits plus '#'.
            var bytes: [7]u8 = undefined;
            const text = std.fmt.bufPrint(&bytes, "#{x:0>2}{x:0>2}{x:0>2}", .{
                rgb[0],
                rgb[1],
                rgb[2],
            }) catch unreachable;
            pushString(state, text);
        },
    }
}

fn pushTerminal(state: *lua.lua_State, terminal: Terminal) void {
    lua.lua_createtable(state, 0, 3);
    pushColor(state, terminal.foreground);
    lua.lua_setfield(state, -2, "foreground");
    pushColor(state, terminal.background);
    lua.lua_setfield(state, -2, "background");
    lua.lua_createtable(state, 16, 0);
    for (terminal.palette, 0..) |color, index| {
        pushColor(state, color);
        lua.lua_rawseti(state, -2, @intCast(index));
    }
    lua.lua_setfield(state, -2, "palette");
}

fn pushContext(state: *lua.lua_State, context: Context, name: Name) void {
    lua.lua_createtable(state, 0, 20);
    inline for (std.meta.fields(Context)) |field| {
        const value = @field(context, field.name);
        switch (field.type) {
            []const u8 => pushString(state, value),
            bool => lua.lua_pushboolean(state, @intFromBool(value)),
            u32 => lua.lua_pushinteger(state, value),
            ?u32 => if (value) |number| lua.lua_pushinteger(state, number) else lua.lua_pushnil(state),
            else => @compileError("unsupported presentation context field"),
        }
        lua.lua_setfield(state, -2, field.name);
    }
    pushString(state, name.slice());
    lua.lua_setfield(state, -2, "preset");
}

fn plainTable(state: *lua.lua_State) !void {
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) return error.InvalidPresentation;
    if (lua.lua_getmetatable(state, -1) != 0) {
        pop(state);
        return error.InvalidPresentation;
    }
}

fn presets(state: *lua.lua_State) !void {
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "presentation");
    try plainTable(state);
    lua.lua_getfield(state, -1, "presets");
    try plainTable(state);
}

pub fn defaultName(state: *lua.lua_State) !Name {
    const top = lua.lua_gettop(state);
    defer lua.lua_settop(state, top);
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "presentation");
    try plainTable(state);
    lua.lua_getfield(state, -1, "default");
    return Name.init(try textAt(state, -1));
}

fn optionalBoolean(state: *lua.lua_State, name: [:0]const u8) !bool {
    lua.lua_getfield(state, -1, name);
    const missing = lua.lua_type(state, -1) == lua.LUA_TNIL;
    pop(state);
    return if (missing) false else boolean(state, name);
}

// Reject misspelled categories and attributes rather than accepting a broken live palette.
fn syntaxPalette(state: *lua.lua_State) ![syntax.category_count]SyntaxStyle {
    var palette: [syntax.category_count]SyntaxStyle = @splat(.{});
    lua.lua_getfield(state, -1, "syntax");
    defer pop(state);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) return palette;
    try plainTable(state);
    const table = lua.lua_gettop(state);
    lua.lua_pushnil(state);
    while (lua.lua_next(state, table) != 0) {
        const name = try textAt(state, -2);
        const category = std.meta.stringToEnum(syntax.Category, name) orelse
            return error.InvalidPresentation;
        try plainTable(state);
        var token_style: SyntaxStyle = .{
            .bold = try optionalBoolean(state, "bold"),
            .italic = try optionalBoolean(state, "italic"),
            .underline = try optionalBoolean(state, "underline"),
        };
        lua.lua_getfield(state, -1, "fg");
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) token_style.fg = try colorAt(state);
        pop(state);
        const entry = lua.lua_gettop(state);
        lua.lua_pushnil(state);
        while (lua.lua_next(state, entry) != 0) {
            const key = try textAt(state, -2);
            if (!std.mem.eql(u8, key, "fg") and !std.mem.eql(u8, key, "bold") and
                !std.mem.eql(u8, key, "italic") and !std.mem.eql(u8, key, "underline"))
            {
                return error.InvalidPresentation;
            }
            pop(state);
        }
        palette[@intFromEnum(category)] = token_style;
        pop(state);
    }
    return palette;
}

fn minibufferStyle(state: *lua.lua_State) !MinibufferStyle {
    var result: MinibufferStyle = .{};
    lua.lua_getfield(state, -1, "minibuffer");
    defer pop(state);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) return result;
    try plainTable(state);
    inline for (std.meta.fields(MinibufferStyle)) |field| {
        lua.lua_getfield(state, -1, field.name);
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) @field(result, field.name) = try colorAt(state);
        pop(state);
    }
    const table = lua.lua_gettop(state);
    lua.lua_pushnil(state);
    while (lua.lua_next(state, table) != 0) {
        const key = try textAt(state, -2);
        var known = false;
        inline for (std.meta.fields(MinibufferStyle)) |field| {
            if (std.mem.eql(u8, key, field.name)) known = true;
        }
        if (!known) return error.InvalidPresentation;
        pop(state);
    }
    return result;
}

/// Resolves policy and validates a full frame before exposing any new values to rendering.
/// Protected callbacks receive snapshots only. Failure leaves caller-owned frames unchanged.
pub fn resolve(state: *lua.lua_State, name: Name, terminal: Terminal, context: Context) !Frame {
    const top = lua.lua_gettop(state);
    defer lua.lua_settop(state, top);
    try presets(state);
    pushString(state, name.slice());
    lua.lua_rawget(state, -2);
    try plainTable(state);
    const preset_index = lua.lua_gettop(state);
    const palette = try syntaxPalette(state);
    const minibuffer = try minibufferStyle(state);
    const status_visible = try boolean(state, "status_visible");
    lua.lua_getfield(state, -1, "gutter");
    try plainTable(state);
    const gutter_visible = try boolean(state, "visible");
    const line_numbers = try boolean(state, "line_numbers");
    pop(state);
    lua.lua_getfield(state, preset_index, "theme");
    if (lua.lua_type(state, -1) != lua.LUA_TFUNCTION) return error.InvalidPresentation;
    pushTerminal(state, terminal);
    if (lua.lua_pcall(state, 1, 1, 0) != 0) return error.InvalidPresentation;
    try plainTable(state);
    var theme: Theme = undefined;
    inline for (std.meta.fields(Theme)) |field| {
        lua.lua_getfield(state, -1, field.name);
        @field(theme, field.name) = try colorAt(state);
        pop(state);
    }
    pop(state);
    lua.lua_getfield(state, preset_index, "status");
    if (lua.lua_type(state, -1) != lua.LUA_TFUNCTION) return error.InvalidPresentation;
    pushContext(state, context, name);
    if (lua.lua_pcall(state, 1, 1, 0) != 0) return error.InvalidPresentation;
    const status = try textAt(state, -1);
    if (status.len > 4096 or !validText(status)) return error.InvalidPresentation;
    var frame: Frame = .{
        .syntax = palette,
        .minibuffer = minibuffer,
        .theme = theme,
        .gutter_visible = gutter_visible,
        .line_numbers = line_numbers,
        .status_visible = status_visible,
        .status_len = status.len,
    };
    @memcpy(frame.status_bytes[0..status.len], status);
    return frame;
}

/// Validates every preset, including callbacks against the current editor snapshot.
pub fn validate(state: *lua.lua_State, terminal: Terminal, context: Context) !void {
    const top = lua.lua_gettop(state);
    defer lua.lua_settop(state, top);
    try presets(state);
    const index = lua.lua_gettop(state);
    var count: usize = 0;
    lua.lua_pushnil(state);
    while (lua.lua_next(state, index) != 0) {
        const name = try Name.init(try textAt(state, -2));
        _ = try resolve(state, name, terminal, context);
        lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "presentation");
        lua.lua_getfield(state, -1, "next");
        if (lua.lua_type(state, -1) != lua.LUA_TFUNCTION) return error.InvalidPresentation;
        pushString(state, name.slice());
        if (lua.lua_pcall(state, 1, 1, 0) != 0) return error.InvalidPresentation;
        const next_name = try Name.init(try textAt(state, -1));
        _ = try resolve(state, next_name, terminal, context);
        pop(state);
        pop(state);
        count += 1;
        pop(state);
    }
    if (count == 0) return error.InvalidPresentation;
    _ = try resolve(state, try defaultName(state), terminal, context);
}
