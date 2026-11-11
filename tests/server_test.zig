//! Global registry and attachment contracts through the same host handlers used on the wire.
const std = @import("std");
const junc = @import("junc");
const allocator = std.testing.allocator;

fn request(
    registry: *junc.Registry,
    attachment: *junc.Registry.Attachment,
    arena: std.mem.Allocator,
    value: junc.protocol.Request,
) !junc.protocol.Response {
    return junc.server.handle(registry, attachment, arena, value);
}
fn apply(
    registry: *junc.Registry,
    attachment: *junc.Registry.Attachment,
    arena: std.mem.Allocator,
    edit: junc.protocol.Edit,
) !junc.protocol.Response {
    return request(registry, attachment, arena, .{
        .id = 1,
        .op = .submit,
        .buffer = attachment.selected.?,
        .edit = edit,
    });
}
fn replacement(state: junc.protocol.Snapshot, text: []const u8) junc.protocol.Edit {
    return .{
        .kind = .replace,
        .origin = state.revision,
        .interaction_origin = state.interaction_revision,
        .source = "test",
        .start = state.cursor,
        .finish = state.cursor,
        .text = text,
    };
}
fn expectText(buffer: *junc.Registry.Buffer, expected: []const u8) !void {
    const text = try buffer.document.getText();
    defer allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "canonical paths deduplicate and scratch buffers have independent nonreused identities" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "one.lua",
        .data = "local value=1\n",
    });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(directory);
    const path = try std.fs.path.join(allocator, &.{ directory, "one.lua" });
    defer allocator.free(path);
    const alias = try std.fs.path.join(allocator, &.{ directory, ".", "one.lua" });
    defer allocator.free(alias);
    var registry = junc.Registry.init(allocator);
    defer registry.deinit();
    const first = try registry.open(.{ .path = path });
    try std.testing.expectEqual(first, try registry.open(.{ .path = alias }));
    try std.testing.expectEqualStrings("one.lua", first.name);
    try std.testing.expectEqualStrings(path, first.path.?);
    const scratch = try registry.open(.{});
    const other = try registry.open(.{});
    try std.testing.expect(scratch.id != other.id and scratch.path == null);
    const old_id = scratch.id;
    try registry.kill(old_id, false);
    try std.testing.expectError(error.BufferNotFound, registry.get(old_id));
    try std.testing.expect((try registry.open(.{})).id > other.id);
    try expectText(first, "local value=1\n");
}

test "switching retains attachment sessions cursor selection and shared document history" {
    var registry = junc.Registry.init(allocator);
    defer registry.deinit();
    var attachment: junc.Registry.Attachment = .{ .allocator = allocator };
    defer attachment.deinit(&registry);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = (try request(&registry, &attachment, arena.allocator(), .{
        .id = 1,
        .op = .open,
    })).state.?;
    var state = (try apply(&registry, &attachment, arena.allocator(), replacement(a, "hello"))).state.?;
    state = (try apply(&registry, &attachment, arena.allocator(), .{
        .kind = .move,
        .origin = state.revision,
        .interaction_origin = state.interaction_revision,
        .source = "selection",
        .position = 2,
        .mark = 5,
    })).state.?;
    const b = (try request(&registry, &attachment, arena.allocator(), .{
        .id = 1,
        .op = .open,
    })).state.?;
    try std.testing.expect(b.buffer != a.buffer);
    const restored = (try request(&registry, &attachment, arena.allocator(), .{
        .id = 1,
        .op = .select,
        .buffer = a.buffer,
    })).state.?;
    try std.testing.expectEqual(state.cursor, restored.cursor);
    try std.testing.expectEqual(state.mark, restored.mark);
    try std.testing.expectEqual(state.session, restored.session);
    try std.testing.expectEqual(state.interaction_revision, restored.interaction_revision);
    try std.testing.expectEqual(state.revision, restored.revision);
    try std.testing.expectEqualStrings("llo", restored.selection);
    const undo = try apply(&registry, &attachment, arena.allocator(), .{
        .kind = .undo,
        .origin = restored.revision,
        .interaction_origin = restored.interaction_revision,
        .source = "undo",
    });
    try std.testing.expect(undo.event.?.kind == .edit_event);
    try expectText(try registry.get(a.buffer), "");
}

test "server submissions and observed views use Litura graphemes across combining input and history" {
    var registry = junc.Registry.init(allocator);
    defer registry.deinit();
    var attachment: junc.Registry.Attachment = .{ .allocator = allocator };
    defer attachment.deinit(&registry);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var state = (try request(&registry, &attachment, arena.allocator(), .{
        .id = 1,
        .op = .open,
    })).state.?;
    state = (try apply(&registry, &attachment, arena.allocator(), replacement(state, "界e"))).state.?;
    state = (try apply(&registry, &attachment, arena.allocator(), replacement(state, "́"))).state.?;
    try std.testing.expectEqual(@as(u32, 2), state.count);
    try std.testing.expectEqual(@as(u32, 2), state.cursor);
    const view = (try request(&registry, &attachment, arena.allocator(), .{
        .id = 1,
        .op = .view,
        .buffer = state.buffer,
        .revision = state.revision,
        .first_line = 0,
        .line_count = 1,
    })).view.?;
    try std.testing.expectEqualStrings("界é", view.text);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 6 }, view.boundaries);
    state = (try apply(&registry, &attachment, arena.allocator(), .{
        .kind = .replace,
        .origin = state.revision,
        .interaction_origin = state.interaction_revision,
        .source = "backspace",
        .start = 1,
        .finish = 2,
    })).state.?;
    try expectText(try registry.get(state.buffer), "界");
    state = (try apply(&registry, &attachment, arena.allocator(), .{
        .kind = .undo,
        .origin = state.revision,
        .interaction_origin = state.interaction_revision,
        .source = "undo",
    })).state.?;
    try expectText(try registry.get(state.buffer), "界é");
    _ = try apply(&registry, &attachment, arena.allocator(), .{
        .kind = .redo,
        .origin = state.revision,
        .interaction_origin = state.interaction_revision,
        .source = "redo",
    });
    try expectText(try registry.get(state.buffer), "界");
}

test "stale document or interaction origins cannot mutate the authoritative buffer" {
    var registry = junc.Registry.init(allocator);
    defer registry.deinit();
    var attachment: junc.Registry.Attachment = .{ .allocator = allocator };
    defer attachment.deinit(&registry);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const initial = (try request(&registry, &attachment, arena.allocator(), .{
        .id = 1,
        .op = .open,
    })).state.?;
    const current = (try apply(&registry, &attachment, arena.allocator(), replacement(initial, "safe"))).state.?;
    try std.testing.expectError(error.StaleRevision, apply(&registry, &attachment, arena.allocator(), replacement(initial, "bad")));
    var stale = replacement(current, "bad");
    stale.interaction_origin = initial.interaction_revision;
    try std.testing.expectError(error.StaleInteractionRevision, apply(&registry, &attachment, arena.allocator(), stale));
    try std.testing.expectEqual(current.revision, (try registry.get(current.buffer)).document.revision);
    try expectText(try registry.get(current.buffer), "safe");
    const other = (try request(&registry, &attachment, arena.allocator(), .{
        .id = 1,
        .op = .open,
    })).state.?;
    try std.testing.expectError(error.BufferNotSelected, request(&registry, &attachment, arena.allocator(), .{
        .id = 1,
        .op = .submit,
        .buffer = current.buffer,
        .edit = replacement(current, "wrong target"),
    }));
    try expectText(try registry.get(other.buffer), "");
    try expectText(try registry.get(current.buffer), "safe");
}

test "selection replacement places the cursor at the projected inserted endpoint" {
    // Both cases change boundaries in right context; the requested endpoint need not survive.
    const Case = struct {
        initial: []const u8,
        replacement: []const u8,
        expected: []const u8,
        first: u32,
        last: u32,
    };
    for ([_]Case{
        .{ .initial = "e\ń!", .replacement = "", .expected = "é!", .first = 1, .last = 2 },
        .{ .initial = "🇳🇴🇸🇪", .replacement = "🇦", .expected = "🇦🇸🇪", .first = 0, .last = 1 },
    }) |case| {
        var registry = junc.Registry.init(allocator);
        defer registry.deinit();
        var attachment: junc.Registry.Attachment = .{ .allocator = allocator };
        defer attachment.deinit(&registry);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        var state = (try request(&registry, &attachment, arena.allocator(), .{
            .id = 1,
            .op = .open,
        })).state.?;
        state = (try apply(&registry, &attachment, arena.allocator(), replacement(state, case.initial))).state.?;
        state = (try apply(&registry, &attachment, arena.allocator(), .{
            .kind = .move,
            .origin = state.revision,
            .interaction_origin = state.interaction_revision,
            .source = "select",
            .position = case.last,
            .mark = case.first,
        })).state.?;
        const response = try apply(&registry, &attachment, arena.allocator(), .{
            .kind = .replace,
            .origin = state.revision,
            .interaction_origin = state.interaction_revision,
            .source = "selection-replacement",
            .start = state.first,
            .finish = state.last,
            .text = case.replacement,
        });
        try std.testing.expectEqual(state.interaction_revision + 1, response.state.?.interaction_revision);
        state = response.state.?;
        try std.testing.expectEqual(@as(u32, 1), state.cursor);
        try std.testing.expectEqual(@as(u32, 2), state.count);
        try std.testing.expectEqual(@as(?u32, null), state.mark);
        try std.testing.expectEqual(state.revision, response.event.?.new_revision);
        try expectText(try registry.get(state.buffer), case.expected);
        state = (try apply(&registry, &attachment, arena.allocator(), .{
            .kind = .undo,
            .origin = state.revision,
            .interaction_origin = state.interaction_revision,
            .source = "undo",
        })).state.?;
        try expectText(try registry.get(state.buffer), case.initial);
        _ = try apply(&registry, &attachment, arena.allocator(), .{
            .kind = .redo,
            .origin = state.revision,
            .interaction_origin = state.interaction_revision,
            .source = "redo",
        });
        try expectText(try registry.get(state.buffer), case.expected);
    }
}

test "peer anchor rebasing preserves interaction revision but invalidates positional origins" {
    // A peer changes coordinates without changing our interaction CAS; the document origin must reject.
    var registry = junc.Registry.init(allocator);
    defer registry.deinit();
    var a: junc.Registry.Attachment = .{ .allocator = allocator };
    defer a.deinit(&registry);
    var b: junc.Registry.Attachment = .{ .allocator = allocator };
    defer b.deinit(&registry);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var state_a = (try request(&registry, &a, arena.allocator(), .{
        .id = 1,
        .op = .open,
    })).state.?;
    state_a = (try apply(&registry, &a, arena.allocator(), replacement(state_a, "ab"))).state.?;
    const state_b = (try request(&registry, &b, arena.allocator(), .{
        .id = 1,
        .op = .select,
        .buffer = state_a.buffer,
    })).state.?;
    const selected = (try apply(&registry, &b, arena.allocator(), .{
        .kind = .move,
        .origin = state_b.revision,
        .interaction_origin = state_b.interaction_revision,
        .source = "select",
        .position = 2,
        .mark = 1,
    })).state.?;
    var insert = replacement(state_a, "X");
    insert.start = 0;
    insert.finish = 0;
    state_a = (try apply(&registry, &a, arena.allocator(), insert)).state.?;
    const observed = (try request(&registry, &b, arena.allocator(), .{
        .id = 1,
        .op = .observe,
        .buffer = state_a.buffer,
        .line_count = 1,
    }));
    const fresh = observed.state.?;
    try std.testing.expectEqual(state_a.revision, observed.view.?.revision);
    try std.testing.expectEqual(selected.interaction_revision, fresh.interaction_revision);
    try std.testing.expectEqual(@as(u32, 3), fresh.cursor);
    try std.testing.expectEqual(@as(?u32, 2), fresh.mark);
    try std.testing.expectError(error.StaleRevision, apply(&registry, &b, arena.allocator(), .{
        .kind = .move,
        .origin = selected.revision,
        .interaction_origin = fresh.interaction_revision,
        .source = "stale-position",
        .position = 0,
    }));
    try std.testing.expectEqual(fresh.cursor, try (try b.target(&registry, state_a.buffer)).position());
    try expectText(try registry.get(state_a.buffer), "Xab");
}

test "detach drops attachment interaction resources without destroying dirty documents" {
    var registry = junc.Registry.init(allocator);
    defer registry.deinit();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var first: junc.Registry.Attachment = .{ .allocator = allocator };
    const initial = (try request(&registry, &first, arena.allocator(), .{
        .id = 1,
        .op = .open,
    })).state.?;
    const state = (try apply(&registry, &first, arena.allocator(), replacement(initial, "unsaved"))).state.?;
    const buffer = try registry.get(state.buffer);
    first.deinit(&registry);
    try std.testing.expectEqual(@as(u32, 0), buffer.document.sessions.count());
    try std.testing.expect(buffer.document.dirty());
    try expectText(buffer, "unsaved");
    var next: junc.Registry.Attachment = .{ .allocator = allocator };
    defer next.deinit(&registry);
    const restored = (try request(&registry, &next, arena.allocator(), .{
        .id = 1,
        .op = .select,
        .buffer = state.buffer,
    })).state.?;
    try std.testing.expect(restored.session != state.session);
    try std.testing.expectEqual(@as(u32, 0), restored.cursor);
    try std.testing.expectEqual(state.revision, restored.revision);
    try std.testing.expectEqual(@as(usize, 1), buffer.document.undo_stack.items.len);
}

test "save canonical identity and dirty protection survive failed saves and explicit buffer killing" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(directory);
    const path = try std.fs.path.join(allocator, &.{ directory, "saved.txt" });
    defer allocator.free(path);
    var registry = junc.Registry.init(allocator);
    defer registry.deinit();
    var attachment: junc.Registry.Attachment = .{ .allocator = allocator };
    defer attachment.deinit(&registry);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const initial = (try request(&registry, &attachment, arena.allocator(), .{
        .id = 1,
        .op = .open,
    })).state.?;
    const state = (try apply(&registry, &attachment, arena.allocator(), replacement(initial, "keep me"))).state.?;
    try std.testing.expectError(error.DirtyBuffer, registry.kill(state.buffer, false));
    try std.testing.expectError(error.DirtyBuffers, request(&registry, &attachment, arena.allocator(), .{
        .id = 1,
        .op = .shutdown,
    }));
    try registry.save(state.buffer, path);
    const buffer = try registry.get(state.buffer);
    try std.testing.expect(!buffer.document.dirty());
    try std.testing.expectEqual(buffer, try registry.open(.{ .path = path }));
    const loaded = try temporary.dir.readFileAlloc(std.testing.io, "saved.txt", allocator, .limited(128));
    defer allocator.free(loaded);
    try std.testing.expectEqualStrings("keep me", loaded);
    const other = try registry.open(.{});
    try std.testing.expectError(error.PathInUse, registry.save(other.id, path));
    // Saving to a directory fails inside Litura; the host keeps its original canonical identity.
    try std.testing.expectError(error.IsDir, registry.save(state.buffer, directory));
    try std.testing.expectEqualStrings(path, buffer.path.?);
    try registry.save(state.buffer, null);
    _ = try request(&registry, &attachment, arena.allocator(), .{
        .id = 1,
        .op = .kill,
        .buffer = state.buffer,
    });
    try std.testing.expectError(error.BufferNotFound, registry.get(state.buffer));
    try std.testing.expectEqual(other.id, attachment.selected.?);
}
