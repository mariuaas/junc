//! Owns the global buffer collection. Identities and canonical paths are host policy; Litura owns
//! text.
const std = @import("std");
const litura = @import("litura");
const paths = @import("paths.zig");
const protocol = @import("protocol.zig");
const local = @import("local_document.zig");
const Syntax = @import("SyntaxCache.zig");
const Registry = @This();

allocator: std.mem.Allocator,
buffers: std.ArrayListUnmanaged(*Buffer) = .empty,
next_id: u32 = 1,

pub const Buffer = struct {
    id: u32,
    path: ?[]u8,
    name: []u8,
    document: litura.BufferEngine,
    syntax: Syntax,

    /// Names and paths borrow this buffer until save/kill/deinit; numeric fields are copied.
    pub fn info(self: *const Buffer) protocol.BufferInfo {
        return .{
            .id = self.id,
            .path = self.path,
            .name = self.name,
            .revision = self.document.revision,
            .dirty = self.document.dirty(),
        };
    }
};

/// Creates an owning registry. Buffer addresses remain stable until kill/deinit; do not copy live
/// state.
pub fn init(allocator: std.mem.Allocator) Registry {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Registry) void {
    for (self.buffers.items) |buffer| self.destroy(buffer);
    self.buffers.deinit(self.allocator);
    self.* = undefined;
}

fn destroy(self: *Registry, buffer: *Buffer) void {
    buffer.syntax.deinit();
    buffer.document.deinit();
    if (buffer.path) |path| self.allocator.free(path);
    self.allocator.free(buffer.name);
    self.allocator.destroy(buffer);
}

/// Borrows a stable buffer owned by this registry; unknown ids return BufferNotFound.
pub fn get(self: *Registry, id: u32) !*Buffer {
    for (self.buffers.items) |buffer| if (buffer.id == id) return buffer;
    return error.BufferNotFound;
}

/// Reads/allocates a buffer or borrows the existing canonical identity; null path creates scratch.
/// The returned buffer belongs to the registry until kill/deinit; existing state survives
/// rejection.
pub fn open(self: *Registry, options: struct { path: ?[]const u8 = null }) !*Buffer {
    const path = options.path;
    const canonical = if (path) |value| try paths.canonical(self.allocator, value) else null;
    errdefer if (canonical) |value| self.allocator.free(value);
    if (canonical) |value| {
        for (self.buffers.items) |buffer| {
            if (buffer.path) |existing| {
                if (std.mem.eql(u8, existing, value)) {
                    self.allocator.free(value);
                    return buffer;
                }
            }
        }
    }
    if (self.next_id == std.math.maxInt(u32)) return error.BufferIdsExhausted;
    const name = if (canonical) |value|
        try self.allocator.dupe(u8, std.fs.path.basename(value))
    else
        try std.fmt.allocPrint(self.allocator, "*scratch-{d}*", .{self.next_id});
    errdefer self.allocator.free(name);
    if (canonical) |value| try paths.ordinaryFile(self.allocator, value);
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = if (canonical) |value|
        std.Io.Dir.cwd().readFileAlloc(
            io,
            value,
            self.allocator,
            .limited(litura.BufferEngine.max_file_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => try self.allocator.dupe(u8, ""),
            else => return err,
        }
    else
        try self.allocator.dupe(u8, "");
    defer self.allocator.free(text);
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    const buffer = try self.allocator.create(Buffer);
    errdefer self.allocator.destroy(buffer);
    buffer.* = .{
        .id = self.next_id,
        .path = canonical,
        .name = name,
        .document = try litura.BufferEngine.initFromText(self.allocator, text, canonical),
        .syntax = Syntax.init(self.allocator, canonical),
    };
    errdefer buffer.document.deinit();
    errdefer buffer.syntax.deinit();
    try self.buffers.append(self.allocator, buffer);
    self.next_id += 1;
    return buffer;
}

pub fn dirty(self: *const Registry) bool {
    for (self.buffers.items) |buffer| if (buffer.document.dirty()) return true;
    return false;
}

/// Dirty content is retained unless the request explicitly confirms discard.
pub fn kill(self: *Registry, id: u32, discard: bool) !void {
    const buffer = try self.get(id);
    if (buffer.document.dirty() and !discard) return error.DirtyBuffer;
    for (self.buffers.items, 0..) |item, index| {
        if (item == buffer) {
            _ = self.buffers.orderedRemove(index);
            self.destroy(buffer);
            return;
        }
    }
}

/// Registry identity commits after a successful write, even though Litura's save-as path can change
/// on error.
pub fn save(self: *Registry, id: u32, path: ?[]const u8) !void {
    const buffer = try self.get(id);
    const destination = if (path) |value|
        try paths.canonical(self.allocator, value)
    else
        try self.allocator.dupe(u8, buffer.path orelse return error.PathRequired);
    errdefer self.allocator.free(destination);
    for (self.buffers.items) |other| {
        if (other.id == id) continue;
        if (other.path) |value| if (std.mem.eql(u8, value, destination)) return error.PathInUse;
    }
    const name = try self.allocator.dupe(u8, std.fs.path.basename(destination));
    errdefer self.allocator.free(name);
    try paths.ordinaryFile(self.allocator, destination);
    try buffer.document.save(destination);
    const new_language = Syntax.detect(destination);
    if (new_language != buffer.syntax.language and !buffer.document.hasViewProvider("tokens")) {
        buffer.syntax.deinit();
        buffer.syntax = Syntax.init(self.allocator, destination);
    }
    if (buffer.path) |old| self.allocator.free(old);
    self.allocator.free(buffer.name);
    buffer.path = destination;
    buffer.name = name;
}

/// Produces an immutable, revision-stamped view using Litura's grapheme cursor and token provider.
/// All returned slices belong to the caller's arena; text and offsets are observations, not a
/// replica.
pub fn view(self: *Registry, arena: std.mem.Allocator, request: protocol.Request) !protocol.View {
    const buffer = try self.get(request.buffer);
    const document = &buffer.document;
    if (request.revision != document.revision) return error.StaleRevision;
    if (request.line_count == 0 or request.first_line >= document.lineCount()) return error.InvalidRange;
    const line_count = @min(request.line_count, document.lineCount() - request.first_line);
    const lines = try arena.alloc(protocol.Line, line_count);
    for (lines, 0..) |*line, index| {
        const number = request.first_line + @as(u32, @intCast(index));
        line.* = .{
            .start = try document.lineStart(number),
            .end = try document.lineEnd(number, false),
            .end_with_newline = try document.lineEnd(number, true),
        };
    }
    const start = lines[0].start;
    const end = lines[lines.len - 1].end_with_newline;
    const text = try document.getTextRange(start, end);
    defer self.allocator.free(text);
    const boundaries = try arena.alloc(u32, end - start + 1);
    var iterator = try document.graphemeCursor(start);
    var offset: u32 = 0;
    boundaries[0] = 0;
    while (iterator.position < end) {
        offset += @intCast((try iterator.current()).len);
        boundaries[iterator.position - start + 1] = offset;
        if (!iterator.advance()) break;
    }
    buffer.syntax.update(document, .{ .start = start, .end = end }) catch |err| {
        std.log.scoped(.server).warn("syntax unavailable: {s}", .{@errorName(err)});
    };
    return .{
        .buffer = buffer.id,
        .revision = document.revision,
        .first_line = request.first_line,
        .lines = lines,
        .start = start,
        .end = end,
        .text = try arena.dupe(u8, text),
        .boundaries = boundaries,
        .tokens = try arena.dupe(Syntax.Span, buffer.syntax.spans),
        .syntax_state = buffer.syntax.state,
    };
}

/// Owns this attachment's per-buffer interaction sessions. Drop them on detach, not on switching.
pub const Attachment = struct {
    allocator: std.mem.Allocator,
    visits: std.ArrayListUnmanaged(Visit) = .empty,
    selected: ?u32 = null,

    const Visit = struct { buffer: u32, cursor: litura.anchors.AnchorId, session: u32 };

    pub fn deinit(self: *Attachment, registry: *Registry) void {
        for (self.visits.items) |visit| {
            const buffer = registry.get(visit.buffer) catch |err| {
                std.log.scoped(.server).err("detaching missing buffer: {s}", .{@errorName(err)});
                continue;
            };
            buffer.document.dropSession(visit.session, visit.cursor) catch |err| {
                std.log.scoped(.server).err("dropping interaction session: {s}", .{
                    @errorName(err),
                });
            };
        }
        self.visits.deinit(self.allocator);
        self.* = undefined;
    }

    /// Creates or reuses a session owned by this attachment; returned target borrows its buffer.
    pub fn select(self: *Attachment, registry: *Registry, id: u32) !local.Target {
        const buffer = try registry.get(id);
        for (self.visits.items) |visit| {
            if (visit.buffer == id) {
                self.selected = id;
                return .{
                    .document = &buffer.document,
                    .cursor = visit.cursor,
                    .session = visit.session,
                };
            }
        }
        try self.visits.ensureUnusedCapacity(self.allocator, 1);
        const cursor = try buffer.document.createAnchor(0, .sticky);
        errdefer buffer.document.dropAnchor(cursor) catch |err| {
            std.log.scoped(.server).err("rolling back cursor: {s}", .{@errorName(err)});
        };
        const session = try buffer.document.createSession(&.{cursor});
        self.visits.appendAssumeCapacity(.{ .buffer = id, .cursor = cursor, .session = session });
        self.selected = id;
        return .{ .document = &buffer.document, .cursor = cursor, .session = session };
    }

    pub fn target(self: *Attachment, registry: *Registry, id: u32) !local.Target {
        if (self.selected != id) return error.BufferNotSelected;
        return self.select(registry, id);
    }

    /// Only selection is allocated through arena; other strings borrow the selected buffer.
    pub fn snapshot(
        self: *Attachment,
        registry: *Registry,
        arena: std.mem.Allocator,
    ) !protocol.Snapshot {
        const id = self.selected orelse return error.NoSelectedBuffer;
        const buffer = try registry.get(id);
        const result = try local.snapshot(arena, try self.target(registry, id), buffer.info());
        return result;
    }

    /// Removes a visit after its buffer has been destroyed; never drops resources in a live buffer.
    pub fn forget(self: *Attachment, id: u32) void {
        for (self.visits.items, 0..) |visit, index| {
            if (visit.buffer == id) {
                _ = self.visits.orderedRemove(index);
                break;
            }
        }
    }
};
