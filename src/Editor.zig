//! Client-local Lua, presentation and input state; borrows a remote host or owns an in-process test
//! engine.
const std = @import("std");
const litura = @import("litura");
const lua = @import("lua");
const Editor = @This();
const Minibuffer = @import("Minibuffer.zig");
const Target = @import("editing.zig").Target;
const runtime = @import("runtime.zig");
const Syntax = @import("SyntaxCache.zig");
const Presentation = @import("Presentation.zig");
const Remote = @import("Remote.zig");
const protocol = @import("protocol.zig");

allocator: std.mem.Allocator,
document: ?*litura.BufferEngine,
remote: ?*Remote = null,
viewports: std.ArrayListUnmanaged(BufferViewport) = .empty,
cursor: litura.anchors.AnchorId,
session: u32,
state: *lua.lua_State,
syntax: Syntax,
minibuffer: Minibuffer,
runtime_depth: usize = 0,
reload_requested: bool = false,
presentation: Presentation.Frame,
preset: Presentation.Name,
terminal: Presentation.Terminal = .{},
viewport: Presentation.Viewport = .{},
quit: bool = false,
message: [512]u8 = @splat(0),
message_len: usize = 0,

pub const Submission = @import("submission.zig").Result;
const BufferViewport = struct { buffer: u32, top: u32, left: u32 };

/// In-process host for non-terminal tests. Owns a stable engine, minibuffer and VM; do not copy.
pub fn init(allocator: std.mem.Allocator, text: []const u8, path: ?[]const u8) !Editor {
    const document = try allocator.create(litura.BufferEngine);
    errdefer allocator.destroy(document);
    document.* = try litura.BufferEngine.initFromText(allocator, text, path);
    errdefer document.deinit();
    const cursor = try document.createAnchor(0, .sticky);
    const session = try document.createSession(&.{cursor});
    return initState(allocator, document, null, cursor, session);
}

/// Borrows an attached connection at a stable address; the caller keeps it alive through deinit.
/// No main-document engine or local text replica is constructed. Keep this Editor stable after
/// dispatch
/// or REPL evaluation installs native closures in its VM; do not copy it.
pub fn initAttached(allocator: std.mem.Allocator, remote: *Remote) !Editor {
    const state = remote.current();
    return initState(allocator, null, remote, .{ .value = state.cursor_anchor }, state.session);
}

fn initState(
    allocator: std.mem.Allocator,
    document: ?*litura.BufferEngine,
    remote: ?*Remote,
    cursor: litura.anchors.AnchorId,
    session: u32,
) !Editor {
    std.debug.assert(document != null or remote != null);
    std.debug.assert(document == null or remote == null);
    var minibuffer = try Minibuffer.init(allocator);
    errdefer minibuffer.deinit();
    const state = try newState();
    errdefer lua.lua_close(state);
    const path = if (remote) |host| host.current().path else document.?.path;
    var editor: Editor = .{
        .allocator = allocator,
        .document = document,
        .remote = remote,
        .cursor = cursor,
        .session = session,
        .state = state,
        .syntax = Syntax.init(allocator, path),
        .minibuffer = minibuffer,
        .presentation = undefined,
        .preset = try Presentation.defaultName(state),
    };
    const context = try editor.presentationContext();
    try Presentation.validate(state, editor.terminal, context);
    editor.presentation = try Presentation.resolve(state, editor.preset, editor.terminal, context);
    if (document) |engine| editor.syntax.attach(engine) catch |err| editor.report(@errorName(err));
    return editor;
}

pub fn deinit(self: *Editor) void {
    self.minibuffer.deinit();
    self.syntax.deinit();
    lua.lua_close(self.state);
    if (self.document) |document| {
        document.deinit();
        self.allocator.destroy(document);
    }
    self.viewports.deinit(self.allocator);
    self.* = undefined;
}

fn evaluate(state: *lua.lua_State, source: []const u8) !void {
    if (lua.luaL_loadbuffer(state, source.ptr, source.len, "junc") != 0) return error.LuaError;
    if (lua.lua_pcall(state, 0, 1, 0) != 0) return error.LuaError;
}

fn newState() !*lua.lua_State {
    const state = lua.luaL_newstate() orelse return error.OutOfMemory;
    errdefer lua.lua_close(state);
    lua.luaL_openlibs(state);
    const commands = @embedFile("commands.lua");
    if (lua.luaL_loadbuffer(state, commands.ptr, commands.len, "commands") != 0) return error.LuaError;
    try evaluate(state, @embedFile("keymaps.lua"));
    if (lua.lua_pcall(state, 1, 1, 0) != 0) return error.LuaError;
    lua.lua_setfield(state, lua.LUA_GLOBALSINDEX, "editor");
    try evaluate(state, @embedFile("runtime.lua"));
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    if (lua.lua_pcall(state, 1, 0, 0) != 0) return error.LuaError;
    try evaluate(state, @embedFile("extension.lua"));
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    if (lua.lua_pcall(state, 1, 0, 0) != 0) return error.LuaError;
    try validateKeymaps(state);
    try evaluate(state, Presentation.default_source);
    lua.lua_setfield(state, lua.LUA_GLOBALSINDEX, "presentation");
    return state;
}

/// Replaces command implementations only after loading succeeds. Document/session/history survive.
pub fn reload(self: *Editor, extension: ?[]const u8) !void {
    return self.reloadSources(extension, null);
}

/// Stages commands and presentation together; invalid policy leaves the live VM and frame intact.
pub fn reloadSources(self: *Editor, extension: ?[]const u8, presentation: ?[]const u8) !void {
    const replacement = try newState();
    errdefer lua.lua_close(replacement);
    if (extension) |source| {
        evaluate(replacement, source) catch |err| {
            self.reportLuaError(replacement);
            return err;
        };
        lua.lua_getfield(replacement, lua.LUA_GLOBALSINDEX, "editor");
        if (lua.lua_pcall(replacement, 1, 0, 0) != 0) {
            self.reportLuaError(replacement);
            return error.LuaError;
        }
    }
    if (presentation) |source| {
        evaluate(replacement, source) catch |err| {
            self.reportLuaError(replacement);
            return err;
        };
        lua.lua_setfield(replacement, lua.LUA_GLOBALSINDEX, "presentation");
    }
    const context = try self.presentationContext();
    try Presentation.validate(replacement, self.terminal, context);
    const frame = try Presentation.resolve(replacement, self.preset, self.terminal, context);
    validateKeymaps(replacement) catch |err| {
        self.reportLuaError(replacement);
        return err;
    };
    try setKeyContext(replacement, if (self.minibuffer.context != null and
        self.minibuffer.context != .prompt) "minibuffer" else "document", true);
    lua.lua_close(self.state);
    self.state = replacement;
    self.presentation = frame;
    self.minibuffer.clearCandidates();
    self.report("");
    if (self.minibuffer.context == .prompt) {
        self.minibuffer.cancel();
        self.report("Prompt cancelled by Lua reload");
    }
}

/// Copies document observations only; presentation callbacks have no native mutation API.
pub fn presentationContext(self: *Editor) !Presentation.Context {
    const cursor_position = try self.position();
    const target = self.mainTarget();
    const lc = try target.positionToLineCol(cursor_position);
    return .{
        .path = target.path() orelse "[scratch]",
        .name = target.name(),
        .buffer_id = target.bufferId(),
        .message = self.status(),
        .dirty = target.dirty(),
        .cursor = cursor_position,
        .mark = try self.mark(),
        .line = lc.line + 1,
        .column = lc.col + 1,
        .count = target.graphemeCount(),
        .lines = target.lineCount(),
        .revision = target.revision(),
        .interaction_revision = try target.interactionRevision(),
        .width = self.viewport.width,
        .height = self.viewport.height,
        .top = self.viewport.top,
        .left = self.viewport.left,
    };
}

/// A failed callback keeps the last complete frame, including colors and layout policy.
pub fn present(self: *Editor, viewport: Presentation.Viewport) !void {
    self.viewport = viewport;
    const frame = try Presentation.resolve(
        self.state,
        self.preset,
        self.terminal,
        try self.presentationContext(),
    );
    self.presentation = frame;
}

/// Switches a Lua-defined preset without recreating any document or terminal resource.
pub fn setPreset(self: *Editor, name: []const u8) !void {
    const candidate = try Presentation.Name.init(name);
    const frame = try Presentation.resolve(
        self.state,
        candidate,
        self.terminal,
        try self.presentationContext(),
    );
    self.preset = candidate;
    self.presentation = frame;
}

fn readOptional(self: *Editor, path: []const u8) !?[]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        self.allocator,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

/// The same disk reload used at startup and by the Lua reload command.
pub fn reloadFiles(self: *Editor, options: struct { commands: bool = true }) !void {
    const extension = if (options.commands) try self.readOptional("lua/extension.lua") else null;
    defer if (extension) |source| self.allocator.free(source);
    const presentation = try self.readOptional("lua/presentation.lua");
    defer if (presentation) |source| self.allocator.free(source);
    try self.reloadSources(extension, presentation);
}

pub fn position(self: *const Editor) !u32 {
    return self.mainTarget().position();
}

pub fn mark(self: *Editor) !?u32 {
    return self.mainTarget().mark();
}

/// Borrows the sanitized message until report or deinit.
pub fn status(self: *const Editor) []const u8 {
    return self.message[0..self.message_len];
}

pub fn report(self: *Editor, message: []const u8) void {
    const valid = if (std.unicode.utf8ValidateSlice(message)) message else "Invalid UTF-8 message";
    var clusters = litura.segmentation.graphemeIterator(valid);
    self.message_len = 0;
    while (clusters.next()) |cluster| {
        if (self.message_len + cluster.len > self.message.len) break;
        for (cluster) |byte| {
            self.message[self.message_len] = if (byte < 32 or byte == 127) ' ' else byte;
            self.message_len += 1;
        }
    }
}

fn reportLuaError(self: *Editor, state: *lua.lua_State) void {
    var len: usize = 0;
    const ptr = lua.lua_tolstring(state, -1, &len);
    self.report(if (ptr != null) ptr[0..len] else "Lua error");
}

fn number(state: *lua.lua_State, name: [:0]const u8, value: u32) void {
    lua.lua_pushinteger(state, value);
    lua.lua_setfield(state, -2, name);
}

fn string(state: *lua.lua_State, value: []const u8) void {
    _ = lua.lua_pushlstring(state, value.ptr, value.len);
}

// A computed intent field is Lua code too. Keep ordinary tables on the direct lookup path.
fn pushIntentField(self: *Editor, table: c_int, name: [:0]const u8) !void {
    const state = self.state;
    if (lua.lua_getmetatable(state, table) == 0) {
        lua.lua_getfield(state, table, name);
        return;
    }
    lua.lua_settop(state, -2);
    lua.lua_pushcclosure(state, intentFieldCallback, 0);
    lua.lua_pushvalue(state, table);
    string(state, name);
    // This is decoding, not a new explicit command scope; preserve runtime_depth.
    if (lua.lua_pcall(state, 2, 1, 0) != 0) {
        self.reportLuaError(state);
        return error.LuaError;
    }
}

fn intentFieldCallback(maybe_state: ?*lua.lua_State) callconv(.c) c_int {
    const state = maybe_state.?;
    lua.lua_pushvalue(state, 2);
    // Any metamethod error unwinds only this resource-free C callback into lua_pcall.
    lua.lua_gettable(state, 1);
    return 1;
}

fn fieldNumber(self: *Editor, table: c_int, name: [:0]const u8) !u32 {
    const state = self.state;
    try self.pushIntentField(table, name);
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

fn fieldString(self: *Editor, table: c_int, name: [:0]const u8) ![]const u8 {
    // Keep the value rooted until dispatch restores the stack, even for computed __index fields.
    const state = self.state;
    try self.pushIntentField(table, name);
    if (lua.lua_type(state, -1) != lua.LUA_TSTRING) return error.InvalidCommand;
    var len: usize = 0;
    const ptr = lua.lua_tolstring(state, -1, &len);
    return ptr[0..len];
}

fn optionalNumber(self: *Editor, table: c_int, name: [:0]const u8) !?u32 {
    const state = self.state;
    try self.pushIntentField(table, name);
    const missing = lua.lua_type(state, -1) == lua.LUA_TNIL;
    lua.lua_settop(state, -2);
    return if (missing) null else try self.fieldNumber(table, name);
}

/// Runs a Lua key binding and submits its returned intent. Returns an owning observable result.
/// Lua sees a revision-stamped snapshot; every text/interaction change calls BufferEngine.submit.
/// Routes normalized input to exactly one focused Litura surface.
pub fn dispatch(self: *Editor, key: []const u8, text: []const u8) !?Submission {
    runtime.bind(self);
    defer self.finishDeferred() catch |err| {
        if (err != error.LuaError) self.report(@errorName(err));
    };
    const in_minibuffer = self.minibuffer.context != null;
    const target = if (in_minibuffer) self.minibuffer.target() else self.mainTarget();
    const result = try self.dispatchInto(target, key, text, false);
    if (in_minibuffer) {
        if (result) |value| {
            self.minibuffer.clearCandidates();
            if (value == .edit_event) self.minibuffer.resetNavigation();
        }
    }
    return result;
}

/// Named invocation uses the same Lua execution and Litura submission bridge as keys.
pub fn invoke(self: *Editor, name: []const u8, text: []const u8) !?Submission {
    runtime.bind(self);
    defer self.finishDeferred() catch |err| {
        if (err != error.LuaError) self.report(@errorName(err));
    };
    return self.dispatchInto(self.mainTarget(), name, text, true);
}

pub fn mainTarget(self: *const Editor) Target {
    if (self.remote) |remote| return .{
        .remote = .{
            .client = remote,
            .buffer = remote.current().buffer,
        },
    };
    return .{
        .local = .{
            .document = self.document.?,
            .cursor = self.cursor,
            .session = self.session,
        },
    };
}

pub fn callLua(self: *Editor, arguments: c_int, results: c_int) c_int {
    self.runtime_depth += 1;
    defer self.runtime_depth -= 1;
    return lua.lua_pcall(self.state, arguments, results, 0);
}

/// Reload cannot close a VM while a REPL or command callback is still executing on it.
pub fn finishDeferred(self: *Editor) !void {
    if (self.runtime_depth != 0 or !self.reload_requested) return;
    self.reload_requested = false;
    try self.reloadFiles(.{});
    self.report("Lua commands and presentation reloaded");
}

pub fn openMinibuffer(self: *Editor, context: Minibuffer.Context) !void {
    const label: []const u8 = switch (context) {
        .command => "M-x ",
        .lua => "Lua> ",
        .prompt => return error.InvalidPrompt,
    };
    try self.minibuffer.open(context, label, @tagName(context), "");
    try self.syncKeyContext();
}

/// Focus changes discard pending key sequences without changing either document.
pub fn syncKeyContext(self: *Editor) !void {
    try setKeyContext(self.state, if (self.minibuffer.context != null) "minibuffer" else "document", false);
}

pub fn cancelMinibuffer(self: *Editor) !void {
    self.minibuffer.cancel();
    try self.syncKeyContext();
}

fn setKeyContext(state: *lua.lua_State, context: []const u8, reset: bool) !void {
    const top = lua.lua_gettop(state);
    defer lua.lua_settop(state, top);
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    lua.lua_getfield(state, -1, "_keymap_focus");
    string(state, context);
    lua.lua_pushboolean(state, @intFromBool(reset));
    if (lua.lua_pcall(state, 2, 0, 0) != 0) return error.LuaError;
}

fn validateKeymaps(state: *lua.lua_State) !void {
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    lua.lua_getfield(state, -1, "validate_keymaps");
    // On failure leave the Lua error available to the reload diagnostic.
    if (lua.lua_pcall(state, 0, 0, 0) != 0) return error.LuaError;
    lua.lua_settop(state, -2);
}

/// Pushes copied observations; cursor/selection semantics come from Litura in the authoritative
/// host.
pub fn pushCommandContext(self: *Editor, target: Target) !void {
    const state = self.state;
    const context = try target.snapshot(self.allocator);
    defer self.allocator.free(context.selection);
    lua.lua_createtable(state, 0, 30);
    string(state, if (target.isMain(self.document)) "document" else "minibuffer");
    lua.lua_setfield(state, -2, "surface");
    string(state, self.preset.slice());
    lua.lua_setfield(state, -2, "presentation");
    inline for (std.meta.fields(protocol.Snapshot)) |field| {
        const value = @field(context, field.name);
        switch (field.type) {
            u32 => lua.lua_pushinteger(state, value),
            ?u32 => if (value) |n| lua.lua_pushinteger(state, n) else lua.lua_pushnil(state),
            bool => lua.lua_pushboolean(state, @intFromBool(value)),
            []const u8 => string(state, value),
            ?[]const u8 => if (value) |text| string(state, text) else lua.lua_pushnil(state),
            else => @compileError("Unsupported command snapshot field"),
        }
        const name = if (comptime std.mem.eql(u8, field.name, "buffer")) "buffer_id" else field.name;
        lua.lua_setfield(state, -2, name);
    }
}

fn dispatchInto(
    self: *Editor,
    target: Target,
    key: []const u8,
    text: []const u8,
    named: bool,
) !?Submission {
    errdefer if (self.remote) |host| {
        if (host.errorMessage().len > 0) self.report(host.errorMessage());
    };
    const state = self.state;
    const top = lua.lua_gettop(state);
    defer lua.lua_settop(self.state, if (self.state == state) top else 0);
    const revision = target.revision();
    const interaction_revision = try target.interactionRevision();
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    lua.lua_getfield(state, -1, if (named) "execute" else "dispatch");
    string(state, key);
    try self.pushCommandContext(target);
    string(state, text);
    if (self.callLua(3, 1) != 0) {
        self.reportLuaError(state);
        return error.LuaError;
    }
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) return null;
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) return error.InvalidCommand;
    const intent_index = lua.lua_gettop(state);
    const kind = try self.fieldString(intent_index, "kind");
    if (std.mem.eql(u8, kind, "key-feedback")) {
        self.report(try self.fieldString(intent_index, "message"));
        return null;
    }
    if (!target.isMain(self.document) and !std.mem.eql(u8, kind, "replace") and
        !std.mem.eql(u8, kind, "move") and !std.mem.eql(u8, kind, "undo") and
        !std.mem.eql(u8, kind, "redo") and !std.mem.eql(u8, kind, "reload") and
        !std.mem.eql(u8, kind, "minibuffer"))
    {
        return error.UnavailableInMinibuffer;
    }
    if (std.mem.eql(u8, kind, "quit")) {
        // Detachment is safe even when dirty: authoritative documents outlive this terminal.
        self.quit = true;
        return null;
    }
    self.report("");
    if (std.mem.eql(u8, kind, "save")) {
        if (target.path() == null) return error.PathRequired;
        switch (target) {
            .local => |value| {
                try value.document.save(null);
            },
            .remote => |value| {
                try self.rememberViewport();
                try value.client.save(.{});
                self.afterBufferChange();
            },
        }
        self.report("Saved");
        return null;
    }
    if (std.mem.eql(u8, kind, "reload")) {
        self.reload_requested = true;
        return null;
    }
    if (std.mem.eql(u8, kind, "minibuffer")) {
        const context = try self.fieldString(intent_index, "context");
        const input_context = std.meta.stringToEnum(Minibuffer.Context, context) orelse
            return error.InvalidCommand;
        try self.openMinibuffer(input_context);
        return null;
    }
    if (std.mem.eql(u8, kind, "presentation")) {
        try self.setPreset(try self.fieldString(intent_index, "name"));
        return null;
    }
    const edit = try self.commandEdit(intent_index, kind, .{
        .buffer = target.bufferId(),
        .revision = revision,
        .interaction_revision = interaction_revision,
    });
    var result = try target.submit(self.allocator, edit);
    errdefer result.deinit(self.allocator);
    // Pin the observation before an observer can switch buffers or issue another command.
    switch (result) {
        .edit_event => |*event| {
            event.buffer_id = target.bufferId();
            event.interaction_revision = try target.interactionRevision();
        },
        .interaction_result => |*event| {
            event.buffer_id = target.bufferId();
            event.document_revision = target.revision();
        },
        .validation_report => {},
    }
    try self.observe(target, result);
    return result;
}

// Parses the returned Lua table without restamping explicitly captured observation origins.
fn commandEdit(self: *Editor, intent_index: c_int, kind: []const u8, defaults: struct {
    buffer: u32,
    revision: u32,
    interaction_revision: u32,
}) !protocol.Edit {
    const state = self.state;
    if (try self.optionalNumber(intent_index, "buffer_id")) |id| {
        if (id != defaults.buffer) return error.BufferChanged;
    }
    const edit_kind = std.meta.stringToEnum(@FieldType(protocol.Edit, "kind"), kind) orelse
        return error.InvalidCommand;
    var edit: protocol.Edit = .{
        .kind = edit_kind,
        .origin = (try self.optionalNumber(intent_index, "origin")) orelse defaults.revision,
        .interaction_origin = (try self.optionalNumber(intent_index, "interaction_origin")) orelse
            defaults.interaction_revision,
        .source = try self.fieldString(intent_index, "source"),
    };
    switch (edit.kind) {
        .replace => {
            edit.start = try self.fieldNumber(intent_index, "start");
            edit.finish = try self.fieldNumber(intent_index, "finish");
            edit.text = try self.fieldString(intent_index, "text");
            if (!std.unicode.utf8ValidateSlice(edit.text)) return error.InvalidUtf8;
        },
        .move => {
            edit.position = try self.fieldNumber(intent_index, "position");
            try self.pushIntentField(intent_index, "mark");
            const has_mark = lua.lua_type(state, -1) != lua.LUA_TNIL;
            lua.lua_settop(state, -2);
            if (has_mark) edit.mark = try self.fieldNumber(intent_index, "mark");
        },
        .undo, .redo => {},
    }
    return edit;
}

// Result visibility is shared by built-ins and extensions. Observer failures do not undo an edit.
fn observe(self: *Editor, target: Target, result: Submission) !void {
    const state = self.state;
    const top = lua.lua_gettop(state);
    defer lua.lua_settop(state, top);
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    lua.lua_getfield(state, -1, "on_result");
    if (lua.lua_type(state, -1) == lua.LUA_TFUNCTION) {
        lua.lua_createtable(state, 0, 8);
        string(state, @tagName(result));
        lua.lua_setfield(state, -2, "kind");
        string(state, if (target.isMain(self.document)) "document" else "minibuffer");
        lua.lua_setfield(state, -2, "surface");
        number(state, "buffer_id", target.bufferId());
        number(state, "revision", target.revision());
        number(state, "interaction_revision", try target.interactionRevision());
        switch (result) {
            .edit_event => |event| {
                number(state, "old_revision", event.old_revision);
                number(state, "new_revision", event.new_revision);
                string(state, event.source);
                lua.lua_setfield(state, -2, "source");
            },
            .interaction_result => |event| {
                number(state, "old_revision", event.old_revision);
                number(state, "new_revision", event.new_revision);
            },
            .validation_report => |report_value| {
                string(state, report_value.message);
                lua.lua_setfield(state, -2, "message");
            },
        }
        if (self.callLua(1, 0) != 0) self.report("Lua result observer failed (submission already completed)");
    }
}

fn rememberViewport(self: *Editor) !void {
    const id = self.mainTarget().bufferId();
    for (self.viewports.items) |*view| {
        if (view.buffer == id) {
            view.top = self.viewport.top;
            view.left = self.viewport.left;
            return;
        }
    }
    try self.viewports.append(self.allocator, .{
        .buffer = id,
        .top = self.viewport.top,
        .left = self.viewport.left,
    });
}

fn afterBufferChange(self: *Editor) void {
    const host = self.remote orelse return;
    const state = host.current();
    self.cursor = .{ .value = state.cursor_anchor };
    self.session = state.session;
    self.viewport.top = 0;
    self.viewport.left = 0;
    for (self.viewports.items) |view| {
        if (view.buffer == state.buffer) {
            self.viewport.top = view.top;
            self.viewport.left = view.left;
            break;
        }
    }
    self.syntax.deinit();
    self.syntax = Syntax.init(self.allocator, state.path);
}

pub fn openFile(self: *Editor, path: ?[]const u8) !void {
    const host = self.remote orelse return error.ServerRequired;
    try self.rememberViewport();
    try host.open(.{ .path = path });
    self.afterBufferChange();
}

pub fn selectBuffer(self: *Editor, id: u32) !void {
    const host = self.remote orelse return error.ServerRequired;
    try self.rememberViewport();
    try host.select(id);
    self.afterBufferChange();
}

pub fn killBuffer(self: *Editor, id: u32, discard: bool) !void {
    const host = self.remote orelse return error.ServerRequired;
    try self.rememberViewport();
    try host.kill(id, discard);
    self.afterBufferChange();
}

pub fn saveAs(self: *Editor, path: []const u8) !void {
    const host = self.remote orelse return error.ServerRequired;
    try self.rememberViewport();
    try host.save(.{ .path = path });
    self.afterBufferChange();
}

pub fn shutdownServer(self: *Editor) !void {
    const host = self.remote orelse return error.ServerRequired;
    try host.shutdown();
    self.quit = true;
}
