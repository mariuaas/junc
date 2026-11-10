//! Owns one Litura document and a replaceable Lua VM. No terminal is required.
const std = @import("std");
const litura = @import("litura");
const lua = @import("lua");
const Editor = @This();
const Presentation = @import("Presentation.zig");

allocator: std.mem.Allocator,
document: litura.BufferEngine,
cursor: litura.anchors.AnchorId,
session: u32,
state: *lua.lua_State,
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
    const state = try newState();
    errdefer lua.lua_close(state);
    var editor: Editor = .{ .allocator = allocator, .document = document, .cursor = cursor, .session = session, .state = state, .presentation = undefined, .preset = try Presentation.defaultName(state) };
    const context = try editor.presentationContext();
    try Presentation.validate(state, editor.terminal, context);
    editor.presentation = try Presentation.resolve(state, editor.preset, editor.terminal, context);
    return editor;
}

pub fn deinit(self: *Editor) void {
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
    try evaluate(state, @embedFile("commands.lua"));
    lua.lua_setfield(state, lua.LUA_GLOBALSINDEX, "editor");
    try evaluate(state, @embedFile("extension.lua"));
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    if (lua.lua_pcall(state, 1, 0, 0) != 0) return error.LuaError;
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
    lua.lua_close(self.state);
    self.state = replacement;
    self.presentation = frame;
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
    self.message_len = @min(message.len, self.message.len);
    @memcpy(self.message[0..self.message_len], message[0..self.message_len]);
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
pub fn dispatch(self: *Editor, key: []const u8, text: []const u8) !?Submission {
    const state = self.state;
    defer lua.lua_settop(self.state, 0);
    const pos = try self.position();
    const selection_mark = try self.mark();
    const first = @min(pos, selection_mark orelse pos);
    const last = @max(pos, selection_mark orelse pos);
    const selected = try self.document.getTextRange(first, last);
    defer self.allocator.free(selected);
    const lc = try self.document.positionToLineCol(pos);
    const revision = self.document.revision;
    const interaction_revision = try self.document.interactionRevision(self.session);
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    lua.lua_getfield(state, -1, "dispatch");
    string(state, key);
    lua.lua_createtable(state, 0, 16);
    string(state, self.preset.slice());
    lua.lua_setfield(state, -2, "presentation");
    number(state, "cursor", pos);
    number(state, "count", self.document.graphemeCount());
    number(state, "revision", revision);
    number(state, "interaction_revision", interaction_revision);
    number(state, "first", first);
    number(state, "last", last);
    if (selection_mark) |value| number(state, "mark", value);
    number(state, "left", pos -| 1);
    number(state, "right", @min(pos + 1, self.document.graphemeCount()));
    number(state, "home", try self.document.lineStart(lc.line));
    number(state, "end", try self.document.lineEnd(lc.line, false));
    const up_line = lc.line -| 1;
    const down_line = @min(lc.line + 1, self.document.lineCount() -| 1);
    number(state, "up", try self.linePosition(up_line, lc.col));
    number(state, "down", try self.linePosition(down_line, lc.col));
    string(state, selected);
    lua.lua_setfield(state, -2, "selection");
    string(state, text);
    if (lua.lua_pcall(state, 3, 1, 0) != 0) {
        self.reportLuaError(state);
        return error.LuaError;
    }
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) return null;
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) return error.InvalidCommand;
    const kind = try fieldString(state, "kind");
    if (std.mem.eql(u8, kind, "quit")) {
        if (self.document.dirty() and !std.mem.eql(u8, self.status(), "Unsaved changes; Ctrl-Q again to discard")) {
            self.report("Unsaved changes; Ctrl-Q again to discard");
        } else self.quit = true;
        return null;
    }
    self.report("");
    if (std.mem.eql(u8, kind, "save")) {
        try self.document.save(if (self.document.path == null) "scratch.txt" else null);
        self.report("Saved");
        return null;
    }
    if (std.mem.eql(u8, kind, "reload")) {
        lua.lua_settop(state, 0);
        try self.reloadFiles(.{});
        self.report("Lua commands and presentation reloaded");
        return null;
    }
    if (std.mem.eql(u8, kind, "presentation")) {
        try self.setPreset(try fieldString(state, "name"));
        return null;
    }
    var intent: litura.types.Intent = .{ .payload = undefined, .origin = revision, .source = try fieldString(state, "source"), .cause = "lua-command" };
    if (std.mem.eql(u8, kind, "undo") or std.mem.eql(u8, kind, "redo")) {
        intent.payload = if (std.mem.eql(u8, kind, "undo")) .{ .undo = .{} } else .{ .redo = .{} };
        return try self.submit(intent);
    }
    var interaction_ops: [2]litura.types.InteractionOp = undefined;
    var buffer_ops: [1]litura.types.BufferOp = undefined;
    var parts: [2]litura.types.IntentPayload = undefined;
    var part_count: usize = 0;
    var target: u32 = undefined;
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
        target = if (start <= finish and finish <= self.document.graphemeCount())
            try self.replacementCursor(start, finish, bytes)
        else
            0;
    } else if (std.mem.eql(u8, kind, "move")) {
        target = try fieldNumber(state, "position");
        lua.lua_getfield(state, -1, "mark");
        const has_mark = lua.lua_type(state, -1) != lua.LUA_TNIL;
        lua.lua_settop(state, -2);
        if (has_mark) new_mark = try fieldNumber(state, "mark");
    } else return error.InvalidCommand;
    interaction_ops = .{
        .{ .move_cursor_anchor = .{ .cursor = self.cursor, .position = target } },
        .{ .set_cursor_selection = .{ .cursor = self.cursor, .mark_position = new_mark } },
    };
    parts[part_count] = .{ .interaction_mutation = .{ .session_id = self.session, .origin = interaction_revision, .ops = &interaction_ops } };
    part_count += 1;
    intent.payload = .{ .composite = .{ .parts = parts[0..part_count] } };
    return try self.submit(intent);
}

// Project the insertion endpoint with sticky affinity, using Litura's planned
// context. The splice may extend past that endpoint (for example an RI run).
fn replacementCursor(self: *Editor, start: u32, finish: u32, text: []const u8) !u32 {
    const splice = try self.document.table.planReplace(start, finish, text);
    if (splice.isAligned()) return splice.new_end;
    const left = try self.document.getTextRange(splice.start, start);
    defer self.allocator.free(left);
    const right = try self.document.getTextRange(finish, splice.old_end);
    defer self.allocator.free(right);
    const region = try std.mem.concat(self.allocator, u8, &.{ left, text, right });
    defer self.allocator.free(region);
    const endpoint = left.len + text.len;
    var offset: usize = 0;
    var target = splice.start;
    var clusters = litura.segmentation.graphemeIterator(region);
    while (offset < endpoint) {
        const cluster = clusters.next() orelse return error.InvalidCommand;
        offset += cluster.len;
        target += 1;
    }
    return target;
}

fn linePosition(self: *Editor, line: u32, column: u32) !u32 {
    return @min((try self.document.lineStart(line)) + column, try self.document.lineEnd(line, false));
}

// Result visibility is shared by built-ins and extensions. Observer failures do not undo an edit.
fn submit(self: *Editor, intent: litura.types.Intent) !Submission {
    var result = try self.document.submit(intent);
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
        number(state, "revision", self.document.revision);
        number(state, "interaction_revision", try self.document.interactionRevision(self.session));
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
        if (lua.lua_pcall(state, 1, 0, 0) != 0) self.report("Lua result observer failed (submission already completed)");
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
