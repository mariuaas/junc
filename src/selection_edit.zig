//! Builds one Litura composite for a session's cursor set. All positions are observed graphemes.
const std = @import("std");
const litura = @import("litura");
const protocol = @import("protocol.zig");
const local = @import("local_document.zig");
const CursorEdit = protocol.CursorEdit;

const Existing = struct { active: litura.anchors.AnchorId, fixed: ?litura.anchors.AnchorId };
fn endpoints(value: litura.types.events.SelectionValue) Existing {
    return .{
        .active = if (value.active == .start) value.start.anchor else value.end.anchor,
        .fixed = if (value.isCaret()) null else if (value.active == .start) value.end.anchor else value.start.anchor,
    };
}
fn find(values: []const litura.types.events.SelectionValue, anchor: u32) ?Existing {
    for (values) |value| {
        const result = endpoints(value);
        if (result.active.value == anchor) return result;
    }
    return null;
}
fn kept(value: Existing) litura.types.SelectionSpec {
    return if (value.fixed) |fixed|
        .{ .start = .{ .keep = fixed }, .end = .{ .keep = value.active } }
    else
        .{ .start = .{ .keep = value.active } };
}

/// Allocates only temporary request storage. Validation failures precede engine submission;
/// committed results own their data through the document allocator.
pub fn submit(
    target: local.Target,
    requested: protocol.Edit,
    base: litura.types.Intent,
) !litura.types.SubmitResult {
    const document = target.document;
    var arena = std.heap.ArenaAllocator.init(document.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const previous = try document.querySelections(allocator, target.session);
    var request = requested;
    if (request.kind == .add_next) {
        request.edits = try nextEdits(target, previous, allocator);
        request.kind = .selections;
    }
    var edits: []const CursorEdit = request.edits;
    if (request.kind == .replace or request.kind == .move) {
        const single = try allocator.alloc(CursorEdit, 1);
        single[0] = .{
            .kind = if (request.kind == .replace) .replace else .move,
            .cursor_anchor = target.cursor.value,
            .start = request.start,
            .finish = request.finish,
            .text = request.text,
            .position = request.position,
            .mark = request.mark,
        };
        edits = single;
    }
    if (edits.len == 0 or edits[0].cursor_anchor != target.cursor.value) return error.InvalidSelectionSet;
    for (edits, 0..) |edit, index| {
        if (edit.cursor_anchor == 0) {
            if (request.kind != .selections or edit.kind != .move) return error.InvalidSelectionSet;
        } else if (find(previous, edit.cursor_anchor) == null) return error.ForeignCursor;
        for (edits[0..index]) |earlier| {
            if (edit.cursor_anchor != 0 and edit.cursor_anchor == earlier.cursor_anchor) {
                return error.DuplicateCursor;
            }
        }
    }
    if (request.kind == .batch) {
        for (previous) |value| {
            const anchor = endpoints(value).active.value;
            var included = false;
            for (edits) |edit| if (edit.cursor_anchor == anchor) {
                included = true;
            };
            if (!included) return error.InvalidSelectionSet;
        }
    }
    const plan = try planEdits(allocator, document, edits, request.kind == .selections);
    const selections = try selectionSpecs(
        allocator,
        target.cursor,
        previous,
        edits,
        plan,
        request.kind == .replace or request.kind == .move,
    );
    const interactions = [_]litura.types.InteractionOp{.{ .set_selections = .{ .selections = selections } }};
    var parts: [2]litura.types.IntentPayload = undefined;
    var count: usize = 0;
    if (plan.ops.len > 0) {
        parts[count] = .{ .buffer_mutation = .{ .ops = plan.ops } };
        count += 1;
    }
    parts[count] = .{ .interaction_mutation = .{
        .session_id = target.session,
        .origin = request.interaction_origin,
        .ops = &interactions,
    } };
    var intent = base;
    intent.payload = .{ .composite = .{ .parts = parts[0 .. count + 1] } };
    return document.submit(intent);
}

const Plan = struct { ops: []const litura.types.BufferOp, op_for: []const ?u32 };

// Sort only request indices: selection order, and therefore the primary identity, stays unchanged.
fn planEdits(
    allocator: std.mem.Allocator,
    document: *litura.BufferEngine,
    edits: []const CursorEdit,
    selection_only: bool,
) !Plan {
    var ops: std.ArrayListUnmanaged(litura.types.BufferOp) = .empty;
    const op_for = try allocator.alloc(?u32, edits.len);
    @memset(op_for, null);
    const order = try allocator.alloc(usize, edits.len);
    for (order, 0..) |*index, i| index.* = i;
    std.mem.sort(usize, order, edits, struct {
        fn before(items: []const CursorEdit, a: usize, b: usize) bool {
            return items[a].start < items[b].start;
        }
    }.before);
    for (order) |index| {
        const edit = edits[index];
        if (edit.kind != .replace) continue;
        if (selection_only) return error.InvalidSelectionSet;
        if (edit.start > edit.finish or edit.finish > document.graphemeCount()) return error.InvalidRange;
        if (!std.unicode.utf8ValidateSlice(edit.text)) return error.InvalidUtf8;
        if (ops.items.len > 0) {
            const prior = &ops.items[ops.items.len - 1].replace;
            if (edit.start <= prior.end) {
                // Identical edits run once. Touching deletions collapse to one splice/caret.
                const identical = edit.start == prior.start and edit.finish == prior.end and
                    std.mem.eql(u8, edit.text, prior.text);
                if (!identical and !(edit.text.len == 0 and prior.text.len == 0)) return error.OverlappingEdits;
                prior.start = @min(prior.start, edit.start);
                prior.end = @max(prior.end, edit.finish);
                op_for[index] = @intCast(ops.items.len - 1);
                continue;
            }
        }
        op_for[index] = @intCast(ops.items.len);
        try ops.append(allocator, .{ .replace = .{ .start = edit.start, .end = edit.finish, .text = edit.text } });
    }
    // Build unions left-to-right, then submit right-to-left to retain origin coordinates.
    std.mem.reverse(litura.types.BufferOp, ops.items);
    for (op_for) |*index| if (index.*) |op| {
        index.* = @intCast(ops.items.len - 1 - op);
    };
    return .{ .ops = ops.items, .op_for = op_for };
}

fn selectionSpecs(
    allocator: std.mem.Allocator,
    primary: litura.anchors.AnchorId,
    previous: []const litura.types.events.SelectionValue,
    edits: []const CursorEdit,
    plan: Plan,
    legacy: bool,
) ![]const litura.types.SelectionSpec {
    var selections: std.ArrayListUnmanaged(litura.types.SelectionSpec) = .empty;
    for (edits, 0..) |edit, index| {
        var duplicate = false;
        for (edits[0..index], 0..) |earlier, j| {
            if (plan.op_for[index] != null and plan.op_for[index] == plan.op_for[j]) duplicate = true;
            if (edit.kind == .move and earlier.kind == .move and edit.position == earlier.position and
                edit.mark == earlier.mark) duplicate = true;
        }
        if (duplicate) continue;
        const old = find(previous, edit.cursor_anchor);
        if (edit.kind == .keep) {
            try selections.append(allocator, kept(old.?));
            continue;
        }
        if (plan.ops.len != 0 and edit.kind == .move) return error.MixedCursorActions;
        const at: litura.types.Target = if (plan.op_for[index]) |op|
            .{ .edit = .{ .op = op, .edge = .end } }
        else
            .{ .position = edit.position };
        const active: litura.types.Endpoint = if (old) |value|
            .{ .move = .{ .anchor = value.active, .to = at } }
        else
            .{ .new = at };
        const spec: litura.types.SelectionSpec = if (edit.kind == .move and edit.mark != null)
            .{ .start = if (old != null and old.?.fixed != null)
                .{ .move = .{ .anchor = old.?.fixed.?, .to = .{ .position = edit.mark.? } } }
            else
                .{ .new = .{ .position = edit.mark.? } }, .end = active }
        else
            .{ .start = active };
        try selections.append(allocator, spec);
    }
    // Legacy single-cursor extension intents affect the primary selection and retain the rest.
    if (legacy) {
        for (previous) |value| {
            const old = endpoints(value);
            if (old.active.value != primary.value) try selections.append(allocator, kept(old));
        }
    }
    return selections.items;
}

fn nextEdits(
    target: local.Target,
    values: []const litura.types.events.SelectionValue,
    allocator: std.mem.Allocator,
) ![]const CursorEdit {
    const document = target.document;
    var edits: std.ArrayListUnmanaged(CursorEdit) = .empty;
    for (values) |value| try edits.append(allocator, .{ .kind = .keep, .cursor_anchor = endpoints(value).active.value });
    const position = try target.position();
    const mark = try target.mark();
    if (mark == null or mark.? == position) {
        const word = try litura.spans.wordSpanAt(document, position) orelse return error.NoWord;
        edits.items[0] = .{ .cursor_anchor = target.cursor.value, .position = word.end, .mark = word.start };
    } else {
        const text = try document.getTextRange(@min(position, mark.?), @max(position, mark.?));
        defer document.allocator.free(text);
        var after: u32 = 0;
        for (values) |value| after = @max(after, @max(value.start.position orelse 0, value.end.position orelse 0));
        var start = after;
        var wrapped = false;
        while (true) {
            var match = (try document.findNext(text, start)) orelse {
                if (wrapped) return error.NoFurtherMatch;
                wrapped = true;
                start = 0;
                continue;
            };
            defer match.deinit(document.allocator);
            if (wrapped and match.start >= after) return error.NoFurtherMatch;
            var overlaps = false;
            for (values) |value| {
                const a = value.start.position orelse continue;
                const b = value.end.position orelse continue;
                if (match.start < @max(a, b) and match.end > @min(a, b)) overlaps = true;
            }
            if (!overlaps) {
                try edits.append(allocator, .{ .position = match.end, .mark = match.start });
                break;
            }
            start = match.end;
        }
    }
    return edits.items;
}
