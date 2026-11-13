//! One client's interaction state: Lua policy, presentation, the minibuffer and per-buffer
//! viewports. The selected buffer's document, this client's cursor and session in it, and its
//! syntax belong to the host behind `connection`; only the minibuffer's input document is local.
const std = @import("std");
const litura = @import("litura");
const lua = @import("lua");
const Editor = @This();
const Connection = @import("Connection.zig");
const Minibuffer = @import("Minibuffer.zig");
const Presentation = @import("Presentation.zig");
const intent = @import("intent.zig");
const local = @import("local_document.zig");
const protocol = @import("protocol.zig");
const runtime = @import("runtime.zig");
const vm = @import("vm.zig");

allocator: std.mem.Allocator,
connection: *Connection,
state: *lua.lua_State,
minibuffer: Minibuffer,
runtime_depth: usize = 0,
reload_requested: bool = false,
presentation: Presentation.Frame,
preset: Presentation.Name,
terminal: Presentation.Terminal = .{},
/// The selected buffer's view: terminal size in cells, `top` in lines and `left` in cells.
viewport: Presentation.Viewport = .{},
/// Scroll offsets of other buffers this client has shown, restored when it selects them again.
viewports: std.ArrayListUnmanaged(BufferViewport) = .empty,
quit: bool = false,
message: [512]u8 = @splat(0),
message_len: usize = 0,

pub const Submission = @import("submission.zig").Result;
/// The input surface a command observes and edits. Each has its own revision domain.
pub const Focus = enum { document, minibuffer };
const BufferViewport = struct { buffer: u32, top: u32, left: u32 };

const Entry = enum { dispatch, execute };

// A decoded intent. Strings borrow Lua values that stay on the stack until dispatch returns.
const Action = union(enum) {
    feedback: []const u8,
    quit,
    save,
    reload,
    minibuffer: Minibuffer.Context,
    presentation: []const u8,
    edit: protocol.Edit,
};

/// Borrows connection, which must already observe a selected buffer and outlive this Editor. Keep
/// this Editor at a stable address once dispatch or REPL evaluation installs native closures in its
/// VM; do not copy it.
pub fn init(allocator: std.mem.Allocator, connection: *Connection) !Editor {
    var minibuffer = try Minibuffer.init(allocator);
    errdefer minibuffer.deinit();
    const state = try vm.create();
    errdefer lua.lua_close(state);
    var editor: Editor = .{
        .allocator = allocator,
        .connection = connection,
        .state = state,
        .minibuffer = minibuffer,
        .presentation = undefined,
        .preset = try Presentation.defaultName(state),
    };
    const context = editor.presentationContext();
    try Presentation.validate(state, editor.terminal, context);
    editor.presentation = try Presentation.resolve(state, editor.preset, editor.terminal, context);
    return editor;
}

pub fn deinit(self: *Editor) void {
    self.minibuffer.deinit();
    lua.lua_close(self.state);
    self.viewports.deinit(self.allocator);
    self.* = undefined;
}

/// Replaces command implementations only after loading succeeds. Document/session/history survive.
pub fn reload(self: *Editor, extension: ?[]const u8) !void {
    return self.reloadSources(extension, null);
}

/// Stages commands and presentation together; invalid policy leaves the live VM and frame intact.
pub fn reloadSources(self: *Editor, extension: ?[]const u8, presentation: ?[]const u8) !void {
    const replacement = try vm.create();
    errdefer lua.lua_close(replacement);
    if (extension) |source| vm.loadExtension(replacement, source) catch |err| {
        self.reportLuaError(replacement);
        return err;
    };
    if (presentation) |source| vm.loadPresentation(replacement, source) catch |err| {
        self.reportLuaError(replacement);
        return err;
    };
    const context = self.presentationContext();
    try Presentation.validate(replacement, self.terminal, context);
    const frame = try Presentation.resolve(replacement, self.preset, self.terminal, context);
    vm.validateKeymaps(replacement) catch |err| {
        self.reportLuaError(replacement);
        return err;
    };
    try vm.setKeyContext(replacement, if (self.minibuffer.context != null and
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
/// Strings borrow the connection's latest observation and this editor's status.
pub fn presentationContext(self: *const Editor) Presentation.Context {
    const state = self.connection.current();
    return .{
        .cursor_count = @intCast(state.selections.len),
        .path = state.path orelse "[scratch]",
        .name = state.name,
        .buffer_id = state.buffer,
        .message = self.status(),
        .dirty = state.dirty,
        .cursor = state.cursor,
        .mark = state.mark,
        .line = state.line + 1,
        .column = state.col + 1,
        .count = state.count,
        .lines = state.lines,
        .revision = state.revision,
        .interaction_revision = state.interaction_revision,
        .width = self.viewport.width,
        .height = self.viewport.height,
        .top = self.viewport.top,
        .left = self.viewport.left,
    };
}

/// A failed callback keeps the last complete frame, including colors and layout policy.
pub fn present(self: *Editor, viewport: Presentation.Viewport) !void {
    self.viewport = viewport;
    self.presentation = try Presentation.resolve(
        self.state,
        self.preset,
        self.terminal,
        self.presentationContext(),
    );
}

/// Switches a Lua-defined preset without recreating any document or terminal resource.
pub fn setPreset(self: *Editor, name: []const u8) !void {
    const candidate = try Presentation.Name.init(name);
    const frame = try Presentation.resolve(
        self.state,
        candidate,
        self.terminal,
        self.presentationContext(),
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

/// Cursor in the selected buffer, from this client's latest observation of its own session.
pub fn position(self: *const Editor) u32 {
    return self.connection.current().cursor;
}

pub fn mark(self: *const Editor) ?u32 {
    return self.connection.current().mark;
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

/// Runs a Lua key binding for the focused surface and performs its returned intent. Returns an
/// owning submission summary for edits. Lua sees a revision-stamped snapshot; every text or
/// interaction change is one Litura submission.
pub fn dispatch(self: *Editor, key: []const u8, text: []const u8) !?Submission {
    return self.focused(.dispatch, key, text);
}

/// Runs Lua's paste command once on the focused surface, without interpreting text as keybindings.
pub fn paste(self: *Editor, text: []const u8) !?Submission {
    return self.focused(.execute, "paste", text);
}

fn focused(self: *Editor, entry: Entry, key: []const u8, text: []const u8) !?Submission {
    runtime.bind(self);
    defer self.finishDeferred() catch |err| {
        if (err != error.LuaError) self.report(@errorName(err));
    };
    const focus: Focus = if (self.minibuffer.context != null) .minibuffer else .document;
    const result = try self.run(focus, entry, key, text);
    if (focus == .minibuffer) {
        if (result) |value| {
            self.minibuffer.clearCandidates();
            if (value == .edit_event) self.minibuffer.resetNavigation();
        }
    }
    return result;
}

/// Named invocation uses the same Lua execution and submission path as keys, on the document.
pub fn invoke(self: *Editor, name: []const u8, text: []const u8) !?Submission {
    runtime.bind(self);
    defer self.finishDeferred() catch |err| {
        if (err != error.LuaError) self.report(@errorName(err));
    };
    return self.run(.document, .execute, name, text);
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
    const context = if (self.minibuffer.context != null) "minibuffer" else "document";
    try vm.setKeyContext(self.state, context, false);
}

pub fn cancelMinibuffer(self: *Editor) !void {
    self.minibuffer.cancel();
    try self.syncKeyContext();
}

/// Pushes a table of copied observations of focus for Lua. Cursor and selection semantics come
/// from Litura in the authoritative host. Page targets use this client's viewport.
pub fn pushCommandContext(self: *Editor, focus: Focus) !void {
    const paging = try self.pages(focus);
    const context = try self.snapshot(focus);
    defer context.deinitText(self.allocator);
    self.pushContext(focus, context, paging);
}

/// Clamps the document viewport's first line. Page commands set this before moving the cursor so
/// follow-scroll does not pull the window back by a single row.
pub fn scroll(self: *Editor, top: u32) void {
    const lines = self.connection.current().lines;
    const rows = self.pageRows(.document);
    const max_top = if (lines > rows) lines - rows else 0;
    self.viewport.top = @min(top, max_top);
}

// Selection observations are owned through the editor allocator; names/path borrow the view.
fn snapshot(self: *Editor, focus: Focus) !protocol.Snapshot {
    switch (focus) {
        .document => {
            var state = self.connection.current();
            state.selection = try self.allocator.dupe(u8, state.selection);
            errdefer self.allocator.free(state.selection);
            const selections = try self.allocator.alloc(protocol.Selection, state.selections.len);
            var initialized: usize = 0;
            errdefer {
                for (selections[0..initialized]) |value| self.allocator.free(value.selection);
                self.allocator.free(selections);
            }
            for (state.selections, selections) |source, *copy| {
                copy.* = source;
                copy.selection = try self.allocator.dupe(u8, source.selection);
                initialized += 1;
            }
            state.selections = selections;
            return state;
        },
        .minibuffer => return self.minibuffer.snapshot(self.allocator),
    }
}

const Page = struct { up: u32, down: u32, up_top: u32, down_top: u32 };

fn pageRows(self: *const Editor, focus: Focus) u32 {
    if (focus == .minibuffer) return 1;
    const height = @max(1, self.viewport.height);
    const mini: u32 = if (self.minibuffer.context != null) @min(3, height) else 0;
    const status_rows: u32 = if (self.presentation.status_visible and height > mini) 1 else 0;
    return @max(1, height - mini - status_rows);
}

fn pageWindow(top: u32, line: u32, lines: u32, rows: u32, toward: enum { up, down }) struct { top: u32, line: u32 } {
    const last = lines -| 1;
    const step = @max(1, rows -| 1);
    const max_top = if (lines > rows) lines - rows else 0;
    const new_top = switch (toward) {
        .down => @min(top + step, max_top),
        .up => top -| step,
    };
    var rel = if (line >= top) line - top else 0;
    if (rel >= rows) rel = rows -| 1;
    return .{ .top = new_top, .line = @min(new_top + rel, last) };
}

fn lineAt(self: *Editor, focus: Focus, line: u32, column: u32) !u32 {
    switch (focus) {
        .document => return self.connection.linePosition(line, column),
        .minibuffer => {
            const target: local.Target = .{
                .document = &self.minibuffer.document,
                .cursor = self.minibuffer.cursor,
                .session = self.minibuffer.session,
            };
            return target.linePosition(line, column);
        },
    }
}

fn pages(self: *Editor, focus: Focus) !Page {
    const rows = self.pageRows(focus);
    const top = if (focus == .document) self.viewport.top else 0;
    const loc: struct { line: u32, col: u32, lines: u32 } = switch (focus) {
        .document => .{
            .line = self.connection.current().line,
            .col = self.connection.current().col,
            .lines = self.connection.current().lines,
        },
        .minibuffer => blk: {
            const cursor = try self.minibuffer.position();
            const lc = try self.minibuffer.document.positionToLineCol(cursor);
            break :blk .{
                .line = lc.line,
                .col = lc.col,
                .lines = self.minibuffer.document.lineCount(),
            };
        },
    };
    const down = pageWindow(top, loc.line, loc.lines, rows, .down);
    const up = pageWindow(top, loc.line, loc.lines, rows, .up);
    return .{
        .down = try self.lineAt(focus, down.line, loc.col),
        .up = try self.lineAt(focus, up.line, loc.col),
        .down_top = down.top,
        .up_top = up.top,
    };
}

fn pushContext(self: *Editor, focus: Focus, context: protocol.Snapshot, paging: Page) void {
    const state = self.state;
    lua.lua_createtable(state, 0, 36);
    string(state, @tagName(focus));
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
            []const protocol.Selection => {
                lua.lua_createtable(state, @intCast(value.len), 0);
                for (value, 0..) |selection, index| {
                    lua.lua_createtable(state, 0, 16);
                    inline for (std.meta.fields(protocol.Selection)) |item| {
                        const entry = @field(selection, item.name);
                        switch (item.type) {
                            u32 => lua.lua_pushinteger(state, entry),
                            ?u32 => if (entry) |n| lua.lua_pushinteger(state, n) else lua.lua_pushnil(state),
                            []const u8 => string(state, entry),
                            else => @compileError("Unsupported selection field"),
                        }
                        lua.lua_setfield(state, -2, item.name);
                    }
                    lua.lua_rawseti(state, -2, @intCast(index + 1));
                }
            },
            else => @compileError("Unsupported command snapshot field"),
        }
        const name = if (comptime std.mem.eql(u8, field.name, "buffer")) "buffer_id" else field.name;
        lua.lua_setfield(state, -2, name);
    }
    number(state, "page_up", paging.up);
    number(state, "page_down", paging.down);
    number(state, "page_up_top", paging.up_top);
    number(state, "page_down_top", paging.down_top);
}

// Current origins of focus: the selected buffer's latest observation, or the local minibuffer.
fn origins(self: *Editor, focus: Focus) !intent.Origins {
    switch (focus) {
        .document => {
            const state = self.connection.current();
            return .{
                .buffer = state.buffer,
                .revision = state.revision,
                .interaction_revision = state.interaction_revision,
            };
        },
        .minibuffer => {
            const document = &self.minibuffer.document;
            return .{
                .buffer = 0,
                .revision = document.revision,
                .interaction_revision = try document.interactionRevision(self.minibuffer.session),
            };
        },
    }
}

// One command: snapshot focus, call Lua, decode its intent, perform it. The Lua stack is restored
// on every path, unless a deferred reload replaced the VM.
fn run(
    self: *Editor,
    focus: Focus,
    entry: Entry,
    key: []const u8,
    text: []const u8,
) !?Submission {
    const state = self.state;
    const top = lua.lua_gettop(state);
    defer lua.lua_settop(self.state, if (self.state == state) top else 0);
    const paging = try self.pages(focus);
    const context = try self.snapshot(focus);
    defer context.deinitText(self.allocator);
    // Origins are captured before Lua runs; a command that switches buffers cannot restamp them.
    const before: intent.Origins = .{
        .buffer = context.buffer,
        .revision = context.revision,
        .interaction_revision = context.interaction_revision,
    };
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    lua.lua_getfield(state, -1, @tagName(entry));
    string(state, key);
    self.pushContext(focus, context, paging);
    string(state, text);
    if (self.callLua(3, 1) != 0) {
        self.reportLuaError(state);
        return error.LuaError;
    }
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) return null;
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) return error.InvalidCommand;
    var decode_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer decode_arena.deinit();
    const action = decode(decode_arena.allocator(), state, lua.lua_gettop(state), focus, before) catch |err| {
        if (err == error.LuaError) self.reportLuaError(state);
        return err;
    };
    return self.perform(focus, action, before);
}

// Field reads can run Lua metamethods, so a kind unavailable in the minibuffer reads none.
fn decode(allocator: std.mem.Allocator, state: *lua.lua_State, table: c_int, focus: Focus, before: intent.Origins) !Action {
    const kind = try intent.kind(state, table);
    if (focus == .minibuffer and !(if (kind) |value| value.availableInMinibuffer() else false)) {
        return error.UnavailableInMinibuffer;
    }
    return switch (kind orelse return error.InvalidCommand) {
        .@"key-feedback" => .{ .feedback = try intent.string(state, table, "message") },
        .quit => .quit,
        .save => .save,
        .reload => .reload,
        .minibuffer => .{
            .minibuffer = std.meta.stringToEnum(
                Minibuffer.Context,
                try intent.string(state, table, "context"),
            ) orelse return error.InvalidCommand,
        },
        .presentation => .{ .presentation = try intent.string(state, table, "name") },
        .replace, .move, .undo, .redo, .batch, .selections, .add_next => |edit_kind| .{
            .edit = try intent.edit(allocator, state, table, edit_kind, before),
        },
    };
}

fn perform(self: *Editor, focus: Focus, action: Action, before: intent.Origins) !?Submission {
    if (action != .feedback and action != .quit) self.report("");
    switch (action) {
        .feedback => |message| self.report(message),
        // Detachment is safe even when dirty: authoritative documents outlive this terminal.
        .quit => self.quit = true,
        .save => {
            if (self.connection.current().path == null) return error.PathRequired;
            self.connection.save(.{}) catch |err| return self.hostFailure(err);
            self.report("Saved");
        },
        .reload => self.reload_requested = true,
        .minibuffer => |context| try self.openMinibuffer(context),
        .presentation => |name| try self.setPreset(name),
        .edit => |edit| return try self.submit(focus, edit, before.buffer),
    }
    return null;
}

fn submit(self: *Editor, focus: Focus, edit: protocol.Edit, buffer: u32) !Submission {
    var result = switch (focus) {
        .document => self.connection.submit(self.allocator, buffer, edit) catch |err|
            return self.hostFailure(err),
        .minibuffer => try self.minibuffer.submit(self.allocator, edit),
    };
    errdefer result.deinit(self.allocator);
    // Pin the observation before an observer can switch buffers or issue another command.
    const after = try self.origins(focus);
    switch (result) {
        .edit_event => |*event| {
            event.buffer_id = after.buffer;
            event.interaction_revision = after.interaction_revision;
        },
        .interaction_result => |*event| {
            event.buffer_id = after.buffer;
            event.document_revision = after.revision;
        },
        .validation_report => {},
    }
    try self.notifyResult(focus, result, after);
    return result;
}

// Shows the host's reason for a rejection; other errors are reported by the caller.
fn hostFailure(self: *Editor, err: anytype) @TypeOf(err) {
    if (err == error.ServerRejected) self.report(self.connection.errorMessage());
    return err;
}

// Result visibility is shared by built-ins and extensions. Observer failures do not undo an edit.
fn notifyResult(self: *Editor, focus: Focus, result: Submission, after: intent.Origins) !void {
    const state = self.state;
    const top = lua.lua_gettop(state);
    defer lua.lua_settop(state, top);
    lua.lua_getfield(state, lua.LUA_GLOBALSINDEX, "editor");
    lua.lua_getfield(state, -1, "on_result");
    if (lua.lua_type(state, -1) != lua.LUA_TFUNCTION) return;
    lua.lua_createtable(state, 0, 8);
    string(state, @tagName(result));
    lua.lua_setfield(state, -2, "kind");
    string(state, @tagName(focus));
    lua.lua_setfield(state, -2, "surface");
    number(state, "buffer_id", after.buffer);
    number(state, "revision", after.revision);
    number(state, "interaction_revision", after.interaction_revision);
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

/// Opens or selects a file, or creates a scratch buffer for null. Restores a remembered viewport.
pub fn openFile(self: *Editor, path: ?[]const u8) !void {
    try self.changeBuffer(.{ .open = path });
}

pub fn selectBuffer(self: *Editor, id: u32) !void {
    try self.changeBuffer(.{ .select = id });
}

/// Killing the selected buffer selects another; its remembered viewport is discarded.
pub fn killBuffer(self: *Editor, id: u32, discard: bool) !void {
    try self.changeBuffer(.{ .kill = .{ .id = id, .discard = discard } });
    for (self.viewports.items, 0..) |view, index| {
        if (view.buffer == id) {
            _ = self.viewports.swapRemove(index);
            break;
        }
    }
}

/// Names the selected buffer; the buffer, and so its viewport, stay selected.
pub fn saveAs(self: *Editor, path: []const u8) !void {
    try self.connection.save(.{ .path = path });
}

pub fn shutdownServer(self: *Editor) !void {
    try self.connection.shutdown();
    self.quit = true;
}

// A rejected change keeps the current selection, and with it the current viewport.
fn changeBuffer(self: *Editor, change: union(enum) {
    open: ?[]const u8,
    select: u32,
    kill: struct { id: u32, discard: bool },
}) !void {
    try self.rememberViewport();
    switch (change) {
        .open => |path| try self.connection.open(.{ .path = path }),
        .select => |id| try self.connection.select(id),
        .kill => |kill| try self.connection.kill(kill.id, kill.discard),
    }
    const id = self.connection.current().buffer;
    self.viewport.top = 0;
    self.viewport.left = 0;
    for (self.viewports.items) |view| {
        if (view.buffer == id) {
            self.viewport.top = view.top;
            self.viewport.left = view.left;
            break;
        }
    }
}

fn rememberViewport(self: *Editor) !void {
    const id = self.connection.current().buffer;
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
