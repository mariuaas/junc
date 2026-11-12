//! Litura's normalized Tree-sitter style groups and the token spans observations carry.
const std = @import("std");

pub const Category = enum {
    comment,
    string,
    number,
    constant,
    keyword,
    function,
    identifier,
    operator,
    punctuation,

    pub fn fromStyle(style: []const u8) ?Category {
        inline for (std.meta.fields(Category)) |field| {
            if (std.mem.eql(u8, style, "syntax:" ++ field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};
pub const category_count = std.meta.fields(Category).len;

/// Highlighting availability for one observed range.
pub const State = enum { plain, ready, unavailable, large };
/// Grapheme range [start, end) in document coordinates.
pub const Span = struct { start: u32, end: u32, category: Category };

/// Binary search over sorted, non-overlapping spans; positions are grapheme offsets.
pub fn categoryAt(spans: []const Span, position: u32) ?Category {
    var low: usize = 0;
    var high = spans.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (spans[middle].end <= position) low = middle + 1 else high = middle;
    }
    if (low < spans.len and spans[low].start <= position) return spans[low].category;
    return null;
}
