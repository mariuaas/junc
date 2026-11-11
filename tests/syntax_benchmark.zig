//! Measures the unmodified provider: first refresh, repeated visible query and post-edit refresh.
const std = @import("std");
const litura = @import("litura");

pub fn main(init: std.process.Init) !void {
    if (comptime !litura.tree_sitter_enabled) return;
    for ([_][]const u8{ "zig", "lua", "fennel" }) |language| {
        const line: []const u8 = if (std.mem.eql(u8, language, "zig"))
            "const name = \"界é\"; // comment\n"
        else if (std.mem.eql(u8, language, "lua"))
            "local name = \"界é\" -- comment\n"
        else
            "(local name \"界é\") ; comment\n";
        for ([_]usize{ 16 * 1024, 128 * 1024, 1024 * 1024 }) |bytes| {
            const text = try init.gpa.alloc(u8, bytes / line.len * line.len);
            defer init.gpa.free(text);
            for (0..text.len / line.len) |i| @memcpy(text[i * line.len ..][0..line.len], line);
            var document = try litura.BufferEngine.initFromText(init.gpa, text, null);
            defer document.deinit();
            _ = try litura.tree_sitter.TreeSitterTokenProvider.attachTokensBuiltin(&document, language);
            const first = try query(init.io, &document);
            const cached = try query(init.io, &document);
            var result = try document.submit(.{ .payload = .{ .buffer_mutation = .{
                .ops = &.{.{ .insert = .{ .pos = 0, .text = " " } }},
            } } });
            defer result.deinit(init.gpa);
            const edited = try query(init.io, &document);
            std.debug.print("{s} {d} bytes: first {d} us, cached {d} us, edited {d} us\n", .{ language, text.len, first, cached, edited });
        }
    }
}

fn query(io: std.Io, document: *litura.BufferEngine) !i96 {
    const before = std.Io.Clock.awake.now(io);
    const spans = try document.queryTokenSpans(0, @min(200, document.graphemeCount()), document.revision);
    defer document.allocator.free(spans);
    return @divTrunc(std.Io.Clock.awake.now(io).nanoseconds - before.nanoseconds, 1000);
}
