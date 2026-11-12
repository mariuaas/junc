//! Owns one persistent Litura input document/session, bounded history/output and completion
//! strings.
const std = @import("std");
const litura = @import("litura");
const protocol = @import("protocol.zig");
const local = @import("local_document.zig");
const submission = @import("submission.zig");
const Minibuffer = @This();

allocator: std.mem.Allocator,
document: litura.BufferEngine,
cursor: litura.anchors.AnchorId,
session: u32,
context: ?Context = null,
label: [128]u8 = @splat(0),
label_len: usize = 0,
namespace: [64]u8 = @splat(0),
namespace_len: usize = 0,
history: std.ArrayListUnmanaged(History) = .empty,
output: std.ArrayListUnmanaged([]u8) = .empty,
candidates: std.ArrayListUnmanaged([]u8) = .empty,
candidate_index: ?usize = null,
history_index: ?usize = null,
draft: ?[]u8 = null,
/// Backs the latest observe result; reset by the next observe.
view_arena: std.heap.ArenaAllocator,

pub const Context = enum { command, lua, prompt };
/// One rendered input line. View strings borrow the minibuffer until the next observe or deinit.
pub const Observation = struct { view: protocol.View, cursor: u32, mark: ?u32 };
pub const history_count_max = 50;
pub const output_count_max = 8;
pub const output_bytes_max = 4096;
pub const history_bytes_max = 64 * 1024;
pub const candidate_count_max = 256;
const History = struct { namespace: []u8, text: []u8 };

/// Creates an owning input document/session. Release with deinit; do not copy live instances.
pub fn init(allocator: std.mem.Allocator) !Minibuffer {
    var document = try litura.BufferEngine.init(allocator);
    errdefer document.deinit();
    const cursor = try document.createAnchor(0, .sticky);
    const session = try document.createSession(&.{cursor});
    return .{
        .allocator = allocator,
        .document = document,
        .cursor = cursor,
        .session = session,
        .view_arena = .init(allocator),
    };
}

pub fn deinit(self: *Minibuffer) void {
    self.clearCandidates();
    self.candidates.deinit(self.allocator);
    self.resetNavigation();
    for (self.history.items) |item| {
        self.allocator.free(item.namespace);
        self.allocator.free(item.text);
    }
    self.history.deinit(self.allocator);
    for (self.output.items) |item| self.allocator.free(item);
    self.output.deinit(self.allocator);
    self.document.deinit();
    self.view_arena.deinit();
    self.* = undefined;
}

fn target(self: *Minibuffer) local.Target {
    return .{ .document = &self.document, .cursor = self.cursor, .session = self.session };
}

pub fn position(self: *Minibuffer) !u32 {
    return self.target().position();
}

/// Command context for Lua. Only selection is allocated through allocator; other strings are
/// static.
pub fn snapshot(self: *Minibuffer, allocator: std.mem.Allocator) !protocol.Snapshot {
    return local.snapshot(allocator, self.target(), .{
        .id = 0,
        .name = "[scratch]",
        .path = null,
        .revision = self.document.revision,
        .dirty = self.document.dirty(),
    });
}

/// Submits through the shared Litura adapter; returns a summary owned through allocator.
pub fn submit(self: *Minibuffer, allocator: std.mem.Allocator, edit: protocol.Edit) !submission.Result {
    var result = try local.submit(self.target(), edit);
    defer result.deinit(self.document.allocator);
    return submission.copy(allocator, local.event(result));
}

/// Observes the cursor's line for rendering, with the same view shape as a hosted document.
pub fn observe(self: *Minibuffer) !Observation {
    _ = self.view_arena.reset(.retain_capacity);
    const cursor = try self.position();
    const line = (try self.document.positionToLineCol(cursor)).line;
    return .{
        .view = try local.view(self.view_arena.allocator(), &self.document, .{
            .buffer = 0,
            .first_line = line,
            .line_count = 1,
        }),
        .cursor = cursor,
        .mark = try self.target().mark(),
    };
}

pub fn prompt(self: *const Minibuffer) []const u8 {
    return self.label[0..self.label_len];
}

pub fn historyNamespace(self: *const Minibuffer) []const u8 {
    return self.namespace[0..self.namespace_len];
}

/// Replaces input through Litura's revision-aware public submission path; no direct anchor writes.
pub fn setText(self: *Minibuffer, text: []const u8) !void {
    var result = try self.submit(self.allocator, .{
        .kind = .replace,
        .origin = self.document.revision,
        .interaction_origin = try self.document.interactionRevision(self.session),
        .source = "minibuffer",
        .start = 0,
        .finish = self.document.graphemeCount(),
        .text = text,
    });
    defer result.deinit(self.allocator);
    if (result == .validation_report) return error.InvalidInput;
}

pub fn open(
    self: *Minibuffer,
    context: Context,
    label: []const u8,
    namespace: []const u8,
    initial: []const u8,
) !void {
    if (label.len >= self.label.len or namespace.len == 0 or namespace.len >= self.namespace.len) {
        return error.InvalidPrompt;
    }
    if (!printable(label) or !printable(namespace)) return error.InvalidPrompt;
    try self.setText(initial);
    self.cancel();
    @memcpy(self.label[0..label.len], label);
    @memcpy(self.namespace[0..namespace.len], namespace);
    self.label_len = label.len;
    self.namespace_len = namespace.len;
    self.context = context;
}

pub fn cancel(self: *Minibuffer) void {
    self.context = null;
    self.clearCandidates();
    self.resetNavigation();
}

pub fn resetNavigation(self: *Minibuffer) void {
    if (self.draft) |draft| self.allocator.free(draft);
    self.draft = null;
    self.history_index = null;
}

pub fn clearCandidates(self: *Minibuffer) void {
    for (self.candidates.items) |item| self.allocator.free(item);
    self.candidates.clearRetainingCapacity();
    self.candidate_index = null;
}

pub fn remember(self: *Minibuffer, text: []const u8) !void {
    if (text.len == 0 or text.len > history_bytes_max) return;
    const namespace = try self.allocator.dupe(u8, self.historyNamespace());
    errdefer self.allocator.free(namespace);
    const saved = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(saved);
    try self.history.append(self.allocator, .{ .namespace = namespace, .text = saved });
    if (self.history.items.len > history_count_max) {
        const old = self.history.orderedRemove(0);
        self.allocator.free(old.namespace);
        self.allocator.free(old.text);
    }
}

/// Output is bounded and made safe for one-line terminal display, preserving UTF-8 clusters.
pub fn appendOutput(self: *Minibuffer, text: []const u8) !void {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(self.allocator);
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    var clusters = litura.segmentation.graphemeIterator(text);
    while (clusters.next()) |cluster| {
        if (bytes.items.len + cluster.len > output_bytes_max) break;
        for (cluster) |byte| try bytes.append(self.allocator, if (byte < 32 or byte == 127) ' ' else byte);
    }
    const owned = try bytes.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(owned);
    try self.output.append(self.allocator, owned);
    if (self.output.items.len > output_count_max) self.allocator.free(self.output.orderedRemove(0));
}

pub fn navigateHistory(self: *Minibuffer, backward: bool) !void {
    if (self.draft == null) self.draft = try self.document.getText();
    var index = self.history_index orelse self.history.items.len;
    if (backward) {
        while (index > 0) {
            index -= 1;
            const item = self.history.items[index];
            if (!std.mem.eql(u8, item.namespace, self.historyNamespace())) continue;
            try self.setText(item.text);
            self.history_index = index;
            return;
        }
    } else {
        index = @min(index + 1, self.history.items.len);
        while (index < self.history.items.len) : (index += 1) {
            const item = self.history.items[index];
            if (!std.mem.eql(u8, item.namespace, self.historyNamespace())) continue;
            try self.setText(item.text);
            self.history_index = index;
            return;
        }
        try self.setText(self.draft.?);
        self.history_index = null;
    }
}

pub fn cycleCandidate(self: *Minibuffer, backward: bool) !void {
    const count = self.candidates.items.len;
    if (count == 0) return;
    const index = if (self.candidate_index) |current|
        if (backward) (current + count - 1) % count else (current + 1) % count
    else if (backward) count - 1 else 0;
    try self.setText(self.candidates.items[index]);
    self.candidate_index = index;
}

pub fn printable(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |byte| if (byte < 32 or byte == 127) return false;
    return true;
}
