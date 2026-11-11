//! Version-two hosting messages. Slices borrow their decoded frame arena, never document pointers.
const Syntax = @import("SyntaxCache.zig");

pub const version = 2;
pub const frame_bytes_max = 64 * 1024 * 1024;
pub const Op = enum {
    hello,
    ping,
    open,
    list,
    select,
    snapshot,
    view,
    observe,
    submit,
    save,
    kill,
    detach,
    shutdown,
};
pub const Edit = struct {
    kind: enum { replace, move, undo, redo },
    origin: u32,
    interaction_origin: u32,
    source: []const u8,
    start: u32 = 0,
    finish: u32 = 0,
    text: []const u8 = "",
    position: u32 = 0,
    mark: ?u32 = null,
};
pub const Request = struct {
    version: u32 = version,
    id: u32,
    op: Op,
    buffer: u32 = 0,
    path: ?[]const u8 = null,
    discard: bool = false,
    revision: ?u32 = null,
    first_line: u32 = 0,
    line_count: u16 = 0,
    edit: ?Edit = null,
};
pub const BufferInfo = struct {
    id: u32,
    name: []const u8,
    path: ?[]const u8,
    revision: u32,
    dirty: bool,
};
pub const Snapshot = struct {
    buffer: u32,
    name: []const u8,
    path: ?[]const u8,
    revision: u32,
    interaction_revision: u32,
    cursor_anchor: u32,
    session: u32,
    dirty: bool,
    byte_count: u32,
    count: u32,
    lines: u32,
    cursor: u32,
    mark: ?u32,
    line: u32,
    col: u32,
    left: u32,
    right: u32,
    up: u32,
    down: u32,
    home: u32,
    end: u32,
    first: u32,
    last: u32,
    selection: []const u8,
};
pub const Line = struct { start: u32, end: u32, end_with_newline: u32 };
pub const View = struct {
    buffer: u32,
    revision: u32,
    first_line: u32,
    lines: []const Line,
    start: u32,
    end: u32,
    text: []const u8,
    boundaries: []const u32,
    tokens: []const Syntax.Span,
    syntax_state: Syntax.State,
};
pub const Event = struct {
    kind: enum { edit_event, interaction_result, validation_report },
    old_revision: u32 = 0,
    new_revision: u32 = 0,
    session: u32 = 0,
    source: []const u8 = "",
    message: []const u8 = "",
};
pub const Failure = struct { code: []const u8, message: []const u8 };
/// Coalescible hosting hint, not a canonical Litura event. Null buffer invalidates all cached
/// observations.
pub const Invalidation = struct { generation: u64, buffer: ?u32 = null };
pub const Response = struct {
    version: u32 = version,
    id: u32,
    server_pid: i32 = 0,
    generation: u64 = 0,
    invalidation: ?Invalidation = null,
    busy: bool = false,
    failure: ?Failure = null,
    state: ?Snapshot = null,
    buffers: []const BufferInfo = &.{},
    view: ?View = null,
    event: ?Event = null,
};
