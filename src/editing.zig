//! Borrowed document/session target shared by the main surface and minibuffer.
const std = @import("std");
const litura = @import("litura");

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

    /// Projects the inserted endpoint forward using Litura's public contextual splice plan.
    pub fn replacementCursor(self: Target, start: u32, finish: u32, text: []const u8) !u32 {
        const document = self.document;
        const allocator = document.allocator;
        const splice = try document.table.planReplace(start, finish, text);
        if (splice.isAligned()) return splice.new_end;
        const left = try document.getTextRange(splice.start, start);
        defer allocator.free(left);
        const right = try document.getTextRange(finish, splice.old_end);
        defer allocator.free(right);
        const region = try std.mem.concat(allocator, u8, &.{ left, text, right });
        defer allocator.free(region);
        const endpoint = left.len + text.len;
        var offset: usize = 0;
        var position_after = splice.start;
        var clusters = litura.segmentation.graphemeIterator(region);
        while (offset < endpoint) {
            const cluster = clusters.next() orelse return error.InvalidCommand;
            offset += cluster.len;
            position_after += 1;
        }
        return position_after;
    }
};
