//! Server-side token cache for one hosted buffer. Litura owns providers and parsing; the cache
//! owns the spans copied into views. Clients render those spans and never own a cache.
const std = @import("std");
const litura = @import("litura");
const options = @import("build_options");
const syntax = @import("syntax.zig");
const Category = syntax.Category;
const Syntax = @This();

allocator: std.mem.Allocator,
language: ?Language = null,
max_bytes: usize = options.syntax_max_bytes,
spans: []Span = &.{},
revision: ?u32 = null,
start: u32 = 0,
end: u32 = 0,
failed_revision: ?u32 = null,
state: State = .plain,
query_count: usize = 0,
refresh_count: usize = 0,

pub const State = syntax.State;
pub const Language = enum { zig, lua, fennel };
pub const Span = syntax.Span;
const languages = .{
    .{ ".zig", Language.zig }, .{ ".lua", Language.lua }, .{ ".fnl", Language.fennel },
};

/// Extension matching is explicit and case-sensitive. Scratch and unknown paths remain plain.
pub fn detect(path: ?[]const u8) ?Language {
    const extension = std.fs.path.extension(path orelse return null);
    inline for (languages) |entry| {
        if (std.mem.eql(u8, extension, entry[0])) return entry[1];
    }
    return null;
}

/// Owns only cached spans; the document retains ownership of all attached providers.
pub fn init(allocator: std.mem.Allocator, path: ?[]const u8) Syntax {
    return .{ .allocator = allocator, .language = detect(path) };
}

pub fn deinit(self: *Syntax) void {
    self.clear();
    self.* = undefined;
}

fn clear(self: *Syntax) void {
    self.allocator.free(self.spans);
    self.spans = &.{};
    self.revision = null;
}

/// Attaches only the token facade, without parsing. Provider lifetime belongs to the document.
pub fn attach(self: *Syntax, document: *litura.BufferEngine) !void {
    const language = self.language orelse return;
    if (self.max_bytes != 0 and document.byteCount() > self.max_bytes) {
        self.state = .large;
        return;
    }
    if (comptime litura.tree_sitter_enabled) {
        if (!document.hasViewProvider("tokens")) {
            const attached = try litura.tree_sitter.TreeSitterTokenProvider.attachTokensBuiltin(
                document,
                @tagName(language),
            );
            if (!attached) self.state = .unavailable;
        }
    }
}

/// Queries one contiguous grapheme range for visible rows, once per revision/range.
/// Allocates normalized spans; a stale provider can allocate and parse the entire document
/// synchronously.
/// A stale query rebuilds the entire provider; same-revision queries and palette changes do not.
/// Failure clears stale styling and is not retried until the document revision changes.
pub fn update(self: *Syntax, document: *litura.BufferEngine, range: litura.types.Range) !void {
    if (self.language == null) return;
    if (self.max_bytes != 0 and document.byteCount() > self.max_bytes) {
        self.clear();
        self.state = .large;
        return;
    }
    if (self.failed_revision == document.revision) return;
    self.attach(document) catch |err| {
        self.clear();
        self.failed_revision = document.revision;
        self.state = .unavailable;
        return err;
    };
    const view = document.queryViewState("tokens");
    if (view.kind == .absent) {
        self.clear();
        self.state = .plain;
        return;
    }
    if (self.revision == document.revision and self.start == range.start and
        self.end == range.end and (view.kind == .available or view.kind == .partial))
    {
        return;
    }
    self.clear();
    self.failed_revision = document.revision;
    self.state = .unavailable;
    self.query_count += 1;
    if (view.kind == .stale) self.refresh_count += 1;
    const tokens = try document.queryTokenSpans(range.start, range.end, document.revision);
    defer document.allocator.free(tokens);
    const refreshed = document.queryViewState("tokens");
    if ((refreshed.kind != .available and refreshed.kind != .partial) or
        refreshed.revision != document.revision)
    {
        self.state = .unavailable;
        return;
    }
    var spans = try std.ArrayListUnmanaged(Span).initCapacity(self.allocator, tokens.len);
    errdefer spans.deinit(self.allocator);
    for (tokens) |token| {
        const category = Category.fromStyle(token.style) orelse continue;
        spans.appendAssumeCapacity(.{
            .start = token.start,
            .end = token.end,
            .category = category,
        });
    }
    self.spans = try spans.toOwnedSlice(self.allocator);
    self.revision = document.revision;
    self.start = range.start;
    self.end = range.end;
    self.failed_revision = null;
    self.state = .ready;
}

pub fn categoryAt(self: *const Syntax, position: u32) ?Category {
    return syntax.categoryAt(self.spans, position);
}
