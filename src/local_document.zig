//! Litura submission and observation adapter shared by hosted buffers and the client minibuffer.
const std = @import("std");
const litura = @import("litura");
const protocol = @import("protocol.zig");

pub const Target = struct {
    document: *litura.BufferEngine,
    cursor: litura.anchors.AnchorId,
    session: u32,

    pub fn position(self: Target) !u32 {
        return (try self.document.queryAnchor(self.cursor)).position orelse error.DeadCursor;
    }

    pub fn mark(self: Target) !?u32 {
        const anchor = try self.document.querySessionMark(self.session, self.cursor) orelse return null;
        return (try self.document.queryAnchor(anchor)).position;
    }

    pub fn linePosition(self: Target, line: u32, column: u32) !u32 {
        return @min((try self.document.lineStart(line)) + column, try self.document.lineEnd(line, false));
    }
};

/// Captures authoritative observations; only selection is allocated through the supplied allocator.
pub fn snapshot(
    allocator: std.mem.Allocator,
    target: Target,
    info: protocol.BufferInfo,
) !protocol.Snapshot {
    const document = target.document;
    const position = try target.position();
    const mark = try target.mark();
    const first = @min(position, mark orelse position);
    const last = @max(position, mark orelse position);
    const lc = try document.positionToLineCol(position);
    const selection = try document.getTextRange(first, last);
    defer document.allocator.free(selection);
    return .{
        .buffer = info.id,
        .name = info.name,
        .path = info.path,
        .revision = document.revision,
        .interaction_revision = try document.interactionRevision(target.session),
        .cursor_anchor = target.cursor.value,
        .session = target.session,
        .dirty = document.dirty(),
        .byte_count = @intCast(document.byteCount()),
        .count = document.graphemeCount(),
        .lines = document.lineCount(),
        .cursor = position,
        .mark = mark,
        .line = lc.line,
        .col = lc.col,
        .left = position -| 1,
        .right = @min(position + 1, document.graphemeCount()),
        .up = try target.linePosition(lc.line -| 1, lc.col),
        .down = try target.linePosition(@min(lc.line + 1, document.lineCount() - 1), lc.col),
        .home = try document.lineStart(lc.line),
        .end = try document.lineEnd(lc.line, false),
        .first = first,
        .last = last,
        .selection = try allocator.dupe(u8, selection),
    };
}

/// Copies lines [first_line, first_line + line_count) into arena as one immutable view, clamped
/// to the document. Tokens are left empty; a host with a syntax cache fills them in. Rejects an
/// empty range or a first line past the end with InvalidRange.
pub fn view(
    arena: std.mem.Allocator,
    document: *litura.BufferEngine,
    options: struct { buffer: u32, first_line: u32, line_count: u16 },
) !protocol.View {
    if (options.line_count == 0 or options.first_line >= document.lineCount()) return error.InvalidRange;
    const line_count = @min(options.line_count, document.lineCount() - options.first_line);
    const lines = try arena.alloc(protocol.Line, line_count);
    for (lines, 0..) |*line, index| {
        const number = options.first_line + @as(u32, @intCast(index));
        line.* = .{
            .start = try document.lineStart(number),
            .end = try document.lineEnd(number, false),
            .end_with_newline = try document.lineEnd(number, true),
        };
    }
    const start = lines[0].start;
    const end = lines[lines.len - 1].end_with_newline;
    const text = try document.getTextRange(start, end);
    defer document.allocator.free(text);
    // Byte offsets of each grapheme within text; boundaries[i] starts grapheme start + i.
    const boundaries = try arena.alloc(u32, end - start + 1);
    var iterator = try document.graphemeCursor(start);
    var offset: u32 = 0;
    boundaries[0] = 0;
    while (iterator.position < end) {
        offset += @intCast((try iterator.current()).len);
        boundaries[iterator.position - start + 1] = offset;
        if (!iterator.advance()) break;
    }
    return .{
        .buffer = options.buffer,
        .revision = document.revision,
        .first_line = options.first_line,
        .lines = lines,
        .start = start,
        .end = end,
        .text = try arena.dupe(u8, text),
        .boundaries = boundaries,
        .tokens = &.{},
        .syntax_state = .plain,
    };
}

/// Realizes the existing Lua editing intent as one public, revision-checked Litura submission.
/// The daemon, local test host and minibuffer share this path. Litura resolves replacement
/// endpoints.
pub fn submit(target: Target, edit: protocol.Edit) !litura.types.SubmitResult {
    if (edit.origin != target.document.revision) return error.StaleRevision;
    if (edit.interaction_origin != try target.document.interactionRevision(target.session)) {
        return error.StaleInteractionRevision;
    }
    var intent: litura.types.Intent = .{
        .origin = edit.origin,
        .source = edit.source,
        .cause = "lua-command",
        .payload = undefined,
    };
    if (edit.kind == .undo or edit.kind == .redo) {
        intent.payload = if (edit.kind == .undo) .{ .undo = .{} } else .{ .redo = .{} };
        return target.document.submit(intent);
    }
    var parts: [2]litura.types.IntentPayload = undefined;
    var part_count: usize = 0;
    var buffer_ops: [1]litura.types.BufferOp = undefined;
    if (edit.kind == .replace) {
        if (!std.unicode.utf8ValidateSlice(edit.text)) return error.InvalidUtf8;
        buffer_ops[0] = .{
            .replace = .{
                .start = edit.start,
                .end = edit.finish,
                .text = edit.text,
            },
        };
        parts[0] = .{ .buffer_mutation = .{ .ops = &buffer_ops } };
        part_count = 1;
    }
    const interactions = [_]litura.types.InteractionOp{.{ .place_cursor = .{
        .cursor = target.cursor,
        .at = if (edit.kind == .replace)
            .{ .edit = .{ .op = 0, .edge = .end } }
        else
            .{ .position = edit.position },
        .mark = if (edit.kind == .move and edit.mark != null) .{
            .position = edit.mark.?,
        } else null,
    } }};
    parts[part_count] = .{ .interaction_mutation = .{
        .session_id = target.session,
        .origin = edit.interaction_origin,
        .ops = &interactions,
    } };
    intent.payload = .{ .composite = .{ .parts = parts[0 .. part_count + 1] } };
    return target.document.submit(intent);
}

pub fn event(result: litura.types.SubmitResult) protocol.Event {
    return switch (result) {
        .edit_event => |value| .{
            .kind = .edit_event,
            .old_revision = value.old_revision,
            .new_revision = value.new_revision,
            .source = value.source,
        },
        .interaction_result => |value| .{
            .kind = .interaction_result,
            .old_revision = value.old_revision,
            .new_revision = value.new_revision,
            .session = value.session_id,
        },
        .validation_report => |value| .{ .kind = .validation_report, .message = value.message },
    };
}
