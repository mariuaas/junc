//! Measures cooperative 4 ms refresh steps separately from a 200-grapheme query.
const std = @import("std");
const litura = @import("litura");

pub fn main(init: std.process.Init) !void {
    if (comptime !litura.tree_sitter_enabled) return;
    for ([_][]const u8{ "zig", "lua" }) |language| {
        const line: []const u8 = if (std.mem.eql(u8, language, "zig"))
            "const name = \"界é\"; // comment\n"
        else
            "local name = \"界é\" -- comment\n";
        for ([_]usize{ 16 * 1024, 128 * 1024, 1024 * 1024 }) |bytes| {
            const text = try init.gpa.alloc(u8, bytes / line.len * line.len);
            defer init.gpa.free(text);
            for (0..text.len / line.len) |i| @memcpy(text[i * line.len ..][0..line.len], line);
            var document = try litura.BufferEngine.initFromText(init.gpa, text, null);
            defer document.deinit();
            _ = try litura.tree_sitter.TreeSitterTokenProvider.attachTokensBuiltin(&document, language);
            const first = try query(init.io, &document);
            const cached = try query(init.io, &document);
            var result = try document.submit(.{
                .id = .{ .value = 1 },
                .origin = document.revision,
                .payload = .{ .buffer_mutation = .{
                    .ops = &.{.{ .insert = .{ .pos = document.graphemeCount() / 2, .text = " " } }},
                } },
            });
            defer result.deinit(init.gpa);
            const edited = try query(init.io, &document);
            std.debug.print("{s} {d} bytes: first work/max/steps/query {d}/{d}/{d}/{d}; " ++
                "cached {d}/{d}; edited work/max/steps/query {d}/{d}/{d}/{d} (us)\n", .{
                language,          text.len,
                first.refresh_us,  first.max_step_us,
                first.steps,       first.query_us,
                cached.refresh_us, cached.query_us,
                edited.refresh_us, edited.max_step_us,
                edited.steps,      edited.query_us,
            });
        }
    }
}

const Timing = struct { refresh_us: i96, max_step_us: i96, steps: usize, query_us: i96 };
const Deadline = struct {
    io: std.Io,
    until_ns: i96,
    fn exhausted(context: ?*anyopaque) bool {
        const self: *Deadline = @ptrCast(@alignCast(context.?));
        return std.Io.Clock.awake.now(self.io).nanoseconds >= self.until_ns;
    }
};

fn query(io: std.Io, document: *litura.BufferEngine) !Timing {
    var result: Timing = .{ .refresh_us = 0, .max_step_us = 0, .steps = 0, .query_us = 0 };
    while (true) {
        const before = std.Io.Clock.awake.now(io).nanoseconds;
        var deadline: Deadline = .{ .io = io, .until_ns = before + 4 * std.time.ns_per_ms };
        const state = document.refreshView("tokens", .{ .context = &deadline, .exhausted = Deadline.exhausted });
        const elapsed = @divTrunc(std.Io.Clock.awake.now(io).nanoseconds - before, 1000);
        result.refresh_us += elapsed;
        result.max_step_us = @max(result.max_step_us, elapsed);
        result.steps += 1;
        if (state.kind == .stale) continue;
        if (state.kind != .available and state.kind != .partial) return error.SyntaxUnavailable;
        break;
    }
    const before_query = std.Io.Clock.awake.now(io).nanoseconds;
    const spans = try document.queryTokenSpans(0, @min(200, document.graphemeCount()), document.revision);
    defer document.allocator.free(spans);
    result.query_us = @divTrunc(std.Io.Clock.awake.now(io).nanoseconds - before_query, 1000);
    return result;
}
