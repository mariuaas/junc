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
    return self.insert(canonical, text);
}

/// Creates a buffer holding text without reading the file system, for in-process hosts. A path is
/// canonicalized for identity and syntax detection; an identity already present is PathInUse.
/// The new buffer is clean at revision 0 and belongs to the registry until kill/deinit.
pub fn create(self: *Registry, options: struct { path: ?[]const u8 = null, text: []const u8 }) !*Buffer {
    const canonical = if (options.path) |value| try paths.canonical(self.allocator, value) else null;
    errdefer if (canonical) |value| self.allocator.free(value);
    if (canonical) |value| {
        for (self.buffers.items) |buffer| {
            if (buffer.path) |existing| if (std.mem.eql(u8, existing, value)) return error.PathInUse;
        }
    }
    return self.insert(canonical, options.text);
}

// Takes ownership of canonical only on success; text is copied into the new document.
fn insert(self: *Registry, canonical: ?[]u8, text: []const u8) !*Buffer {
    if (self.next_id == std.math.maxInt(u32)) return error.BufferIdsExhausted;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    const name = if (canonical) |value|
        try self.allocator.dupe(u8, std.fs.path.basename(value))
    else
        try std.fmt.allocPrint(self.allocator, "*scratch-{d}*", .{self.next_id});
    errdefer self.allocator.free(name);
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

/// Produces an immutable, revision-stamped view with this buffer's syntax tokens.
/// All returned slices belong to the caller's arena; text and offsets are observations, not a
/// replica.
pub fn view(self: *Registry, arena: std.mem.Allocator, request: protocol.Request) !protocol.View {
    const buffer = try self.get(request.buffer);
    const document = &buffer.document;
    if (request.revision != document.revision) return error.StaleRevision;
    var result = try local.view(arena, document, .{
        .buffer = buffer.id,
        .first_line = request.first_line,
        .line_count = request.line_count,
    });
    buffer.syntax.update(document, .{ .start = result.start, .end = result.end }) catch |err| {
        std.log.scoped(.server).warn("syntax unavailable: {s}", .{@errorName(err)});
    };
    result.tokens = try arena.dupe(Syntax.Span, buffer.syntax.spans);
    result.syntax_state = buffer.syntax.state;
    return result;
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
            var block = buffer.document.dropSession(.{ .id = local.requestId(), .session = visit.session }) catch |err| {
                std.log.scoped(.server).err("dropping interaction session: {s}", .{
                    @errorName(err),
                });
                continue;
            };
            block.deinit(registry.allocator);
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
        const created = try local.createSession(&buffer.document);
        const cursor = created.cursor;
        const session = created.session;
        self.visits.appendAssumeCapacity(.{ .buffer = id, .cursor = cursor, .session = session });
        self.selected = id;
        return .{ .document = &buffer.document, .cursor = cursor, .session = session };
    }

    pub fn target(self: *Attachment, registry: *Registry, id: u32) !local.Target {
        if (self.selected != id) return error.BufferNotSelected;
        return self.select(registry, id);
    }

    /// Selection observations are allocated through arena; names/path borrow the selected buffer.
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
