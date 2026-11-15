//! Server-side token cache for one hosted buffer. Litura owns providers and parsing; the cache
//! owns the spans copied into views. Clients render those spans and never own a cache.
const std = @import("std");
const litura = @import("litura");
const syntax = @import("syntax.zig");
const Category = syntax.Category;
const Syntax = @This();

allocator: std.mem.Allocator,
language: ?Language = null,
requested: bool = false,
spans: []Span = &.{},
revision: ?u32 = null,
start: u32 = 0,
end: u32 = 0,
failed_revision: ?u32 = null,
state: State = .plain,
query_count: usize = 0,
refresh_count: usize = 0,

pub const State = syntax.State;
pub const Language = enum { zig, lua };
pub const Span = syntax.Span;
const languages = .{
    .{ ".zig", Language.zig }, .{ ".lua", Language.lua },
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

/// True only for requested syntax that still needs maintenance. No allocation or parsing.
pub fn needsMaintenance(self: *const Syntax, document: *litura.BufferEngine) bool {
    if (!self.requested or self.language == null or self.failed_revision == document.revision) return false;
    const view = document.queryViewState("tokens");
    return view.kind == .stale or (litura.tree_sitter_enabled and view.kind == .absent);
}

/// One host-scheduled cooperative step. True means current-revision syntax became ready and
/// observers should invalidate their cached views. Stale is resumable, not a failure.
pub fn maintain(self: *Syntax, document: *litura.BufferEngine, budget: litura.views.RefreshBudget) !bool {
    if (!self.needsMaintenance(document)) return false;
    errdefer {
        self.clear();
        self.failed_revision = document.revision;
        self.state = .unavailable;
    }
    try self.attach(document);
    const before = document.queryViewState("tokens");
    if (before.kind == .absent or before.kind == .unavailable) {
        self.failed_revision = document.revision;
        self.state = .unavailable;
        return false;
    }
    self.refresh_count += 1;
    const view = document.refreshView("tokens", budget);
    if ((view.kind == .available or view.kind == .partial) and view.revision == document.revision) {
        return true;
    }
    self.clear();
    self.state = .stale;
    if (view.kind == .unavailable) {
        self.failed_revision = document.revision;
        self.state = .unavailable;
    }
    return false;
}

/// Queries current tokens for visible rows. Never attaches, refreshes or parses. Requests
/// maintenance on first use; stale coordinates are discarded and the text renders unstyled.
pub fn update(self: *Syntax, document: *litura.BufferEngine, range: litura.types.Range) !void {
    self.requested = true;
    if (self.language == null) return;
    const view = document.queryViewState("tokens");
    if (view.kind == .absent and !litura.tree_sitter_enabled) {
        self.clear();
        self.state = .plain;
        return;
    }
    if ((view.kind != .available and view.kind != .partial) or view.revision != document.revision) {
        self.clear();
        self.state = if (view.kind == .unavailable or self.failed_revision == document.revision)
            .unavailable
        else
            .stale;
        return;
    }
    if (self.failed_revision == document.revision) return;
    if (self.revision == document.revision and self.start == range.start and self.end == range.end) return;
    self.clear();
    errdefer {
        self.failed_revision = document.revision;
        self.state = .unavailable;
    }
    self.query_count += 1;
    const tokens = try document.queryTokenSpans(range.start, range.end, document.revision);
    defer document.allocator.free(tokens);
    var spans = try std.ArrayListUnmanaged(Span).initCapacity(self.allocator, tokens.len);
    errdefer spans.deinit(self.allocator);
    for (tokens) |token| {
        const category = Category.fromStyle(token.style) orelse continue;
        spans.appendAssumeCapacity(.{ .start = token.start, .end = token.end, .category = category });
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
