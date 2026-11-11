//! Litura's normalized Tree-sitter style groups; capture subcategories remain engine metadata.
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
