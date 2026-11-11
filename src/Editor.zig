//! Owns the document and minibuffer sessions and a replaceable Lua VM. No terminal is required.
const std = @import("std");
const litura = @import("litura");
const lua = @import("lua");
const Editor = @This();
const Minibuffer = @import("Minibuffer.zig");
const Target = @import("editing.zig").Target;
const runtime = @import("runtime.zig");
const Syntax = @import("SyntaxCache.zig");
const Presentation = @import("Presentation.zig");

allocator: std.mem.Allocator,
document: litura.BufferEngine,
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

/// Owns an edit event or rejection message. Unlike native validation reports, this
/// result never borrows the short-lived Lua intent. Release with deinit.
pub const Submission = union(enum) {
    edit_event: litura.types.EditEvent,
    interaction_result: litura.types.InteractionResult,
    validation_report: struct { message: []u8 },

    pub fn deinit(self: *Submission, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .edit_event => |*event| event.deinit(allocator),
            .interaction_result => {},
            .validation_report => |report_value| allocator.free(report_value.message),
        }
        self.* = undefined;
    }
};

/// Copies input and owns the document and VM. Release with deinit; do not copy live instances.
pub fn init(allocator: std.mem.Allocator, text: []const u8, path: ?[]const u8) !Editor {
    var document = try litura.BufferEngine.initFromText(allocator, text, path);
    errdefer document.deinit();
    const cursor = try document.createAnchor(0, .sticky);
    const session = try document.createSession(&.{cursor});
    var minibuffer = try Minibuffer.init(allocator);
    errdefer minibuffer.deinit();
    const state = try newState();
    errdefer lua.lua_close(state);
    var editor: Editor = .{
        .allocator = allocator,
        .document = document,
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
    editor.syntax.attach(&editor.document) catch |err| editor.report(@errorName(err));
    return editor;
}

pub fn deinit(self: *Editor) void {
    self.minibuffer.deinit();
    self.syntax.deinit();
    lua.lua_close(self.state);
    self.document.deinit();
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
    const lc = try self.document.positionToLineCol(cursor_position);
    return .{
        .path = self.document.path orelse "[scratch]",
        .message = self.status(),
        .dirty = self.document.dirty(),
        .cursor = cursor_position,
        .mark = try self.mark(),
        .line = lc.line + 1,
        .column = lc.col + 1,
        .count = self.document.graphemeCount(),
        .lines = self.document.lineCount(),
        .revision = self.document.revision,
        .interaction_revision = try self.document.interactionRevision(self.session),
        .width = self.viewport.width,
        .height = self.viewport.height,
        .top = self.viewport.top,
        .left = self.viewport.left,
    };
}

/// A failed callback keeps the last complete frame, including colors and layout policy.
pub fn present(self: *Editor, viewport: Presentation.Viewport) !void {
    self.viewport = viewport;
    const frame = try Presentation.resolve(self.state, self.preset, self.terminal, try self.presentationContext());
    self.presentation = frame;
}

/// Switches a Lua-defined preset without recreating any document or terminal resource.
pub fn setPreset(self: *Editor, name: []const u8) !void {
    const candidate = try Presentation.Name.init(name);
    const frame = try Presentation.resolve(self.state, candidate, self.terminal, try self.presentationContext());
    self.preset = candidate;
    self.presentation = frame;
}

fn readOptional(self: *Editor, path: []const u8) !?[]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
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
    return (try self.document.queryAnchor(self.cursor)).position orelse error.DeadCursor;
}

pub fn mark(self: *Editor) !?u32 {
    const anchor = try self.document.querySessionMark(self.session, self.cursor) orelse return null;
    return (try self.document.queryAnchor(anchor)).position;
}

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

fn fieldNumber(state: *lua.lua_State, name: [:0]const u8) !u32 {
    lua.lua_getfield(state, -1, name);
    defer lua.lua_settop(state, -2);
    if (lua.lua_type(state, -1) != lua.LUA_TNUMBER) return error.InvalidCommand;
    const value = lua.lua_tonumber(state, -1);
    if (!std.math.isFinite(value) or value < 0 or value > std.math.maxInt(u32) or @floor(value) != value) return error.InvalidCommand;
    return @intFromFloat(value);
}

fn fieldString(state: *lua.lua_State, name: [:0]const u8) ![]const u8 {
    lua.lua_getfield(state, -1, name);
    defer lua.lua_settop(state, -2);
    if (lua.lua_type(state, -1) != lua.LUA_TSTRING) return error.InvalidCommand;
    var len: usize = 0;
    const ptr = lua.lua_tolstring(state, -1, &len);
    return ptr[0..len];
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

pub fn mainTarget(self: *Editor) Target {
    return .{ .document = &self.document, .cursor = self.cursor, .session = self.session };
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

/// Pushes a copied Lua snapshot; all native document references remain in Zig.
pub fn pushCommandContext(self: *Editor, target: Target) !void {
    const state = self.state;
    const pos = try target.position();
    const selection_mark = try target.mark();
    const first = @min(pos, selection_mark orelse pos);
    const last = @max(pos, selection_mark orelse pos);
    const selected = try target.document.getTextRange(first, last);
    defer self.allocator.free(selected);
    const lc = try target.document.positionToLineCol(pos);
    const revision = target.document.revision;
    const interaction_revision = try target.document.interactionRevision(target.session);
    lua.lua_createtable(state, 0, 16);
    string(state, if (target.document == &self.document) "document" else "minibuffer");
    lua.lua_setfield(state, -2, "surface");
    string(state, self.preset.slice());
    lua.lua_setfield(state, -2, "presentation");
    number(state, "cursor", pos);
    number(state, "count", target.document.graphemeCount());
    number(state, "revision", revision);
    number(state, "interaction_revision", interaction_revision);
    number(state, "first", first);
    number(state, "last", last);
    if (selection_mark) |value| number(state, "mark", value);
    number(state, "left", pos -| 1);
    number(state, "right", @min(pos + 1, target.document.graphemeCount()));
    number(state, "home", try target.document.lineStart(lc.line));
    number(state, "end", try target.document.lineEnd(lc.line, false));
    const up_line = lc.line -| 1;
    const down_line = @min(lc.line + 1, target.document.lineCount() -| 1);
    number(state, "up", try target.linePosition(up_line, lc.col));
    number(state, "down", try target.linePosition(down_line, lc.col));
    string(state, selected);
    lua.lua_setfield(state, -2, "selection");
}

pub fn dispatchInto(self: *Editor, target: Target, key: []const u8, text: []const u8, named: bool) !?Submission {
    const state = self.state;
    const top = lua.lua_gettop(state);
    defer lua.lua_settop(self.state, if (self.state == state) top else 0);
    const revision = target.document.revision;
    const interaction_revision = try target.document.interactionRevision(target.session);
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
    const kind = try fieldString(state, "kind");
    if (std.mem.eql(u8, kind, "key-feedback")) {
        self.report(try fieldString(state, "message"));
        return null;
    }
    if (target.document != &self.document and !std.mem.eql(u8, kind, "replace") and
        !std.mem.eql(u8, kind, "move") and !std.mem.eql(u8, kind, "undo") and
        !std.mem.eql(u8, kind, "redo") and !std.mem.eql(u8, kind, "reload") and
        !std.mem.eql(u8, kind, "minibuffer")) return error.UnavailableInMinibuffer;
    if (std.mem.eql(u8, kind, "quit")) {
        if (target.document.dirty() and !std.mem.eql(u8, self.status(), "Unsaved changes; Ctrl-Q again to discard")) {
            self.report("Unsaved changes; Ctrl-Q again to discard");
        } else self.quit = true;
        return null;
    }
    self.report("");
    if (std.mem.eql(u8, kind, "save")) {
        try target.document.save(if (target.document.path == null) "scratch.txt" else null);
        self.report("Saved");
        return null;
    }
    if (std.mem.eql(u8, kind, "reload")) {
        self.reload_requested = true;
        return null;
    }
    if (std.mem.eql(u8, kind, "minibuffer")) {
        const context = try fieldString(state, "context");
        try self.openMinibuffer(std.meta.stringToEnum(Minibuffer.Context, context) orelse return error.InvalidCommand);
        return null;
    }
    if (std.mem.eql(u8, kind, "presentation")) {
        try self.setPreset(try fieldString(state, "name"));
        return null;
    }
    var intent: litura.types.Intent = .{ .payload = undefined, .origin = revision, .source = try fieldString(state, "source"), .cause = "lua-command" };
    if (std.mem.eql(u8, kind, "undo") or std.mem.eql(u8, kind, "redo")) {
        intent.payload = if (std.mem.eql(u8, kind, "undo")) .{ .undo = .{} } else .{ .redo = .{} };
        return try self.submit(target, intent);
    }
    var interaction_ops: [2]litura.types.InteractionOp = undefined;
    var buffer_ops: [1]litura.types.BufferOp = undefined;
    var parts: [2]litura.types.IntentPayload = undefined;
    var part_count: usize = 0;
    var next_position: u32 = undefined;
    var new_mark: ?u32 = null;
    if (std.mem.eql(u8, kind, "replace")) {
        const start = try fieldNumber(state, "start");
        const finish = try fieldNumber(state, "finish");
        const bytes = try fieldString(state, "text");
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        buffer_ops[0] = .{ .replace = .{ .start = start, .end = finish, .text = bytes } };
        parts[0] = .{ .buffer_mutation = .{ .ops = &buffer_ops } };
        part_count = 1;
        // Leave invalid ranges to the shared submission validator.
        next_position = if (start <= finish and finish <= target.document.graphemeCount())
            try target.replacementCursor(start, finish, bytes)
        else
            0;
    } else if (std.mem.eql(u8, kind, "move")) {
        next_position = try fieldNumber(state, "position");
        lua.lua_getfield(state, -1, "mark");
        const has_mark = lua.lua_type(state, -1) != lua.LUA_TNIL;
        lua.lua_settop(state, -2);
        if (has_mark) new_mark = try fieldNumber(state, "mark");
    } else return error.InvalidCommand;
    interaction_ops = .{
        .{ .move_cursor_anchor = .{ .cursor = target.cursor, .position = next_position } },
        .{ .set_cursor_selection = .{ .cursor = target.cursor, .mark_position = new_mark } },
    };
    parts[part_count] = .{ .interaction_mutation = .{ .session_id = target.session, .origin = interaction_revision, .ops = &interaction_ops } };
    part_count += 1;
    intent.payload = .{ .composite = .{ .parts = parts[0..part_count] } };
    return try self.submit(target, intent);
}

// Result visibility is shared by built-ins and extensions. Observer failures do not undo an edit.
fn submit(self: *Editor, target: Target, intent: litura.types.Intent) !Submission {
    var result = try target.document.submit(intent);
    errdefer result.deinit(self.allocator);
    const state = self.state;
    const top = lua.lua_gettop(state);
    defer lua.lua_settop(state, top);
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    lua.lua_getfield(state, -1, "on_result");
    if (lua.lua_type(state, -1) == lua.LUA_TFUNCTION) {
        lua.lua_createtable(state, 0, 8);
        string(state, @tagName(result));
        lua.lua_setfield(state, -2, "kind");
        string(state, if (target.document == &self.document) "document" else "minibuffer");
        lua.lua_setfield(state, -2, "surface");
        number(state, "revision", target.document.revision);
        number(state, "interaction_revision", try target.document.interactionRevision(target.session));
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
    return switch (result) {
        .edit_event => |event| .{ .edit_event = event },
        .interaction_result => |event| .{ .interaction_result = event },
        .validation_report => |report_value| rejection: {
            const message = try self.allocator.dupe(u8, report_value.message);
            result.deinit(self.allocator);
            break :rejection .{ .validation_report = .{ .message = message } };
        },
    };
}
