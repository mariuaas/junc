//! Multiplexed local host. One event loop serializes authoritative edits; connections own sessions.
const std = @import("std");
const c = @import("host_c");
const paths = @import("paths.zig");
const wire = @import("wire.zig");
const protocol = @import("protocol.zig");
const Registry = @import("Registry.zig");
const local = @import("local_document.zig");
const log = std.log.scoped(.server);

// Process-global solely because POSIX signal handlers cannot carry an instance pointer.
// The handler does one lock-free store; all resource teardown happens in the event loop.
var interrupted: std.atomic.Value(bool) = .init(false);
fn stop(_: c_int) callconv(.c) void {
    interrupted.store(true, .monotonic);
}

fn installSignal(number: c_int, handler: *const fn (c_int) callconv(.c) void) !void {
    const previous = c.signal(number, handler);
    if (previous) |value| if (@intFromPtr(value) == std.math.maxInt(usize)) return error.SignalSetupFailed;
}

pub const idle_ms = 30_000;

fn nowMs() !i64 {
    var value: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &value) != 0) return error.MonotonicClockUnavailable;
    return @as(i64, @intCast(value.tv_sec)) * 1000 + @divTrunc(value.tv_nsec, 1_000_000);
}

fn validateLock(runtime: *const paths.Runtime, fd: c_int) !void {
    const other = try runtime.openLock();
    defer _ = c.close(other);
    var expected: c.struct_stat = undefined;
    var actual: c.struct_stat = undefined;
    if (c.fstat(other, &expected) != 0 or c.fstat(fd, &actual) != 0 or
        actual.st_ino != expected.st_ino or actual.st_dev != expected.st_dev)
    {
        return error.InvalidServerLock;
    }
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) return error.ServerAlreadyRunning;
}

fn listen(runtime: *const paths.Runtime) !c_int {
    if (try runtime.checkSocket()) {
        const probe = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (probe < 0) return error.SocketCreateFailed;
        defer _ = c.close(probe);
        var address = runtime.address();
        if (c.connect(probe, @ptrCast(&address), @sizeOf(@TypeOf(address))) == 0) {
            return error.LiveSocketWithoutLock;
        }
        const code = wire.errno();
        if (code != c.ECONNREFUSED and code != c.ENOENT) return error.UncertainSocketState;
        if (c.unlink(runtime.socket) != 0 and wire.errno() != c.ENOENT) return error.StaleSocketRemovalFailed;
    }
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketCreateFailed;
    errdefer _ = c.close(fd);
    _ = c.umask(0o177);
    var address = runtime.address();
    if (c.bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) return error.SocketBindFailed;
    errdefer _ = c.unlink(runtime.socket);
    if (c.chmod(runtime.socket, 0o600) != 0 or c.listen(fd, 16) != 0) return error.SocketListenFailed;
    return fd;
}

/// Handles only the explicit hosting operations; there is no remotely named native function
/// dispatch.
pub fn handle(
    registry: *Registry,
    attachment: *Registry.Attachment,
    arena: std.mem.Allocator,
    request: protocol.Request,
) !protocol.Response {
    var response: protocol.Response = .{ .id = request.id };
    switch (request.op) {
        .hello => return error.AlreadyAttached,
        .ping => {},
        .open => {
            const buffer = try registry.open(.{ .path = request.path });
            _ = try attachment.select(registry, buffer.id);
            response.state = try attachment.snapshot(registry, arena);
        },
        .select => {
            _ = try attachment.select(registry, request.buffer);
            response.state = try attachment.snapshot(registry, arena);
        },
        .list => {
            const result = try arena.alloc(protocol.BufferInfo, registry.buffers.items.len);
            for (registry.buffers.items, result) |buffer, *item| item.* = buffer.info();
            response.buffers = result;
        },
        .snapshot => {
            _ = try attachment.target(registry, request.buffer);
            response.state = try attachment.snapshot(registry, arena);
        },
        .observe => {
            _ = try attachment.target(registry, request.buffer);
            const state = try attachment.snapshot(registry, arena);
            var query = request;
            query.revision = state.revision;
            query.line_count = @max(1, request.line_count);
            query.first_line = @min(request.first_line, state.lines - 1);
            if (state.line < query.first_line) query.first_line = state.line;
            if (state.line - query.first_line >= query.line_count)
                query.first_line = state.line - (query.line_count - 1);
            response.state = state;
            response.view = try registry.view(arena, query);
        },
        .view => {
            _ = try attachment.target(registry, request.buffer);
            response.view = try registry.view(arena, request);
        },
        .submit => {
            const target = try attachment.target(registry, request.buffer);
            const edit = request.edit orelse return error.MissingIntent;
            if (edit.origin != target.document.revision) return error.StaleRevision;
            if (edit.interaction_origin != try target.document.interactionRevision(target.session)) {
                return error.StaleInteractionRevision;
            }
            var result = try local.submit(target, edit);
            defer result.deinit(registry.allocator);
            var event = local.event(result);
            event.source = try arena.dupe(u8, event.source);
            event.message = try arena.dupe(u8, event.message);
            response.event = event;
            response.state = try attachment.snapshot(registry, arena);
        },
        .save => {
            _ = try attachment.target(registry, request.buffer);
            try registry.save(request.buffer, request.path);
            response.state = try attachment.snapshot(registry, arena);
        },
        .kill => {
            try killBuffer(registry, attachment, request);
            if (attachment.selected != null) response.state = try attachment.snapshot(registry, arena);
        },
        .detach => {},
        .shutdown => if (registry.dirty()) {
            return error.DirtyBuffers;
        },
    }
    return response;
}

fn killBuffer(
    registry: *Registry,
    attachment: *Registry.Attachment,
    request: protocol.Request,
) !void {
    const buffer = try registry.get(request.buffer);
    if (buffer.document.dirty() and !request.discard) return error.DirtyBuffer;
    if (attachment.selected == request.buffer) {
        var fallback: ?u32 = null;
        for (registry.buffers.items) |other| {
            if (other.id != request.buffer) {
                fallback = other.id;
                break;
            }
        }
        const next = fallback orelse (try registry.open(.{})).id;
        _ = attachment.select(registry, next) catch |err| {
            if (fallback == null) registry.kill(next, true) catch |cleanup_error| {
                log.err("removing an unused fallback buffer: {s}", .{@errorName(cleanup_error)});
            };
            return err;
        };
    }
    try registry.kill(request.buffer, request.discard);
    attachment.forget(request.buffer);
}

// A connection holds at most one encoded frame and one coalesced unsent hint.
// In-flight frames are never rewritten, so replies and notifications cannot interleave bytes.
const Client = struct {
    fd: c_int,
    attachment: Registry.Attachment,
    reader: wire.Reader = .{},
    outgoing: ?wire.Outgoing = null,
    pending: ?protocol.Invalidation = null,
    attached: bool = false,
    closing: bool = false,
    closed: bool = false,
    shutdown: bool = false,
    last_id: u32 = 0,
    accepted_ms: i64,
    partial_ms: ?i64 = null,
    write_progress_ms: i64,

    fn deinit(self: *Client, registry: *Registry) void {
        self.reader.deinit(registry.allocator);
        if (self.outgoing) |*frame| frame.deinit(registry.allocator);
        self.attachment.deinit(registry);
        _ = c.close(self.fd);
        self.* = undefined;
    }
};

const clients_max = 64;
const progress_timeout_ms = 5000;

const Host = struct {
    allocator: std.mem.Allocator,
    registry: Registry,
    clients: std.ArrayListUnmanaged(Client) = .empty,
    generation: u64 = 0,
    stopping: bool = false,

    fn deinit(self: *Host) void {
        for (self.clients.items) |*client| client.deinit(&self.registry);
        self.clients.deinit(self.allocator);
        self.registry.deinit();
        self.* = undefined;
    }

    fn attachedCount(self: *const Host) usize {
        var count: usize = 0;
        for (self.clients.items) |client| if (client.attached and !client.closed) {
            count += 1;
        };
        return count;
    }

    fn accept(self: *Host, listener: c_int, now: i64) !void {
        const fd = c.accept(listener, null, null);
        if (fd < 0) return error.SocketAcceptFailed;
        errdefer _ = c.close(fd);
        if (self.clients.items.len >= clients_max) return error.TooManyClients;
        try wire.configure(fd, 2);
        const flags = c.fcntl(fd, c.F_GETFL);
        if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) != 0) {
            return error.SocketOptionFailed;
        }
        try self.clients.append(self.allocator, .{
            .fd = fd,
            .attachment = .{ .allocator = self.allocator },
            .accepted_ms = now,
            .write_progress_ms = now,
        });
    }

    fn queue(self: *Host, client: *Client, response: protocol.Response, now: i64) !void {
        std.debug.assert(client.outgoing == null);
        client.outgoing = wire.Outgoing.init(self.allocator, response) catch |err| failed: {
            if (err != error.FrameTooLarge) return err;
            break :failed try wire.Outgoing.init(self.allocator, .{
                .id = response.id,
                .server_pid = c.getpid(),
                .generation = self.generation,
                .failure = .{
                    .code = "FrameTooLarge",
                    .message = "Requested observation exceeds the transport frame limit",
                },
            });
        };
        client.write_progress_ms = now;
    }

    fn invalidate(self: *Host, actor: c_int, buffer: ?u32) void {
        self.generation += 1;
        for (self.clients.items) |*client| {
            if (!client.attached or client.closing or client.closed or client.fd == actor) continue;
            if (buffer) |id| if (client.attachment.selected != id) continue;
            const scope = if (client.pending) |old|
                if (old.buffer == buffer) buffer else null
            else
                buffer;
            client.pending = .{ .generation = self.generation, .buffer = scope };
        }
    }

    fn guard(self: *const Host, actor: c_int, request: protocol.Request) !void {
        if (request.op == .kill) {
            for (self.clients.items) |other| {
                if (other.fd != actor and other.attached and !other.closed and
                    other.attachment.selected == request.buffer)
                {
                    return error.BufferInUse;
                }
            }
        }
        if (request.op == .shutdown and self.attachedCount() > 1) return error.ClientsAttached;
    }

    fn process(self: *Host, client: *Client, bytes: []const u8, now: i64) !void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const request = try std.json.parseFromSliceLeaky(protocol.Request, arena.allocator(), bytes, .{});
        var response: protocol.Response = .{
            .id = request.id,
            .server_pid = c.getpid(),
            .generation = self.generation,
        };
        if (request.version != protocol.version) {
            response.failure = .{
                .code = "UnsupportedVersion",
                .message = "Incompatible junc hosting protocol",
            };
            client.closing = true;
        } else if (!client.attached) {
            if (request.op == .ping) {
                response.busy = self.attachedCount() != 0;
                client.closing = true;
            } else if (request.op != .hello or request.id != 1 or self.stopping) {
                response.failure = .{
                    .code = "ExpectedHello",
                    .message = "A running host requires hello with id 1",
                };
                client.closing = true;
            } else {
                client.attached = true;
                client.last_id = request.id;
            }
        } else if (client.last_id == std.math.maxInt(u32) or request.id != client.last_id + 1) {
            response.failure = .{
                .code = "ProtocolOrder",
                .message = "Monotonically ordered request ids are required",
            };
            client.closing = true;
        } else {
            client.last_id = request.id;
            response = self.dispatch(client, request, arena.allocator());
            response.server_pid = c.getpid();
            response.generation = self.generation;
            if (response.failure == null) switch (request.op) {
                .detach => client.closing = true,
                .shutdown => {
                    client.closing = true;
                    client.shutdown = true;
                    self.stopping = true;
                },
                else => {},
            };
        }
        try self.queue(client, response, now);
    }

    fn dispatch(
        self: *Host,
        client: *Client,
        request: protocol.Request,
        arena: std.mem.Allocator,
    ) protocol.Response {
        const before = if (self.registry.get(request.buffer)) |buffer| buffer.document.revision else |_| null;
        var response: protocol.Response = transaction: {
            self.guard(client.fd, request) catch |err| break :transaction .{
                .id = request.id,
                .failure = .{ .code = @errorName(err), .message = @errorName(err) },
            };
            break :transaction handle(&self.registry, &client.attachment, arena, request) catch |err| .{
                .id = request.id,
                .failure = .{ .code = @errorName(err), .message = @errorName(err) },
            };
        };
        // Hints describe potentially changed observations, including a commit followed by an error.
        // They neither manufacture canonical events nor promise one notification per submission.
        const after = if (self.registry.get(request.buffer)) |buffer| buffer.document.revision else |_| null;
        switch (request.op) {
            .submit => if (before != after) {
                self.invalidate(client.fd, request.buffer);
            },
            .open, .save, .kill => self.invalidate(client.fd, null),
            else => {},
        }
        if (response.failure != null and client.attachment.selected != null) {
            response.state = client.attachment.snapshot(&self.registry, arena) catch |err| failed: {
                log.warn("failure observation unavailable: {s}", .{@errorName(err)});
                break :failed null;
            };
        }
        if (request.op == .kill and response.failure == null) {
            for (self.clients.items) |*other| if (other.fd != client.fd) {
                other.attachment.forget(request.buffer);
            };
        }
        return response;
    }

    fn tick(self: *Host, client: *Client, revents: c_short, now: i64) !void {
        if (!client.attached and now - client.accepted_ms >= progress_timeout_ms) {
            return error.HandshakeTimedOut;
        }
        if (client.partial_ms) |since| {
            if (now - since >= progress_timeout_ms) return error.PartialFrameTimedOut;
        }
        if (client.outgoing != null and now - client.write_progress_ms >= progress_timeout_ms) {
            return error.SlowReader;
        }
        if (!client.closing and client.outgoing == null and
            revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0)
        {
            if (try client.reader.next(self.allocator, client.fd)) |bytes| {
                defer self.allocator.free(bytes);
                client.partial_ms = null;
                try self.process(client, bytes, now);
            } else if (client.reader.partial() and client.partial_ms == null) client.partial_ms = now;
        }
        if (client.outgoing == null and !client.closing) {
            if (client.pending) |pending| {
                try self.queue(client, .{
                    .id = 0,
                    .server_pid = c.getpid(),
                    .generation = pending.generation,
                    .invalidation = pending,
                }, now);
                client.pending = null;
            }
        }
        if (client.outgoing) |*frame| {
            const before = frame.offset;
            const complete = try frame.flush(client.fd);
            if (frame.offset != before) client.write_progress_ms = now;
            if (complete) {
                frame.deinit(self.allocator);
                client.outgoing = null;
                if (client.closing) client.closed = true;
            }
        }
    }
};

/// Independent attachments share authoritative documents. Per-connection framing and output are
/// bounded;
/// a slow or partial peer never blocks another client. SIGTERM remains explicit nonpersistent
/// termination.
pub fn run(allocator: std.mem.Allocator, runtime: *const paths.Runtime, lock_fd: c_int) !void {
    defer _ = c.close(lock_fd);
    try validateLock(runtime, lock_fd);
    const listener = try listen(runtime);
    defer _ = c.close(listener);
    var bound: c.struct_stat = undefined;
    if (c.lstat(runtime.socket, &bound) != 0) return error.SocketStatFailed;
    defer {
        var current: c.struct_stat = undefined;
        if (c.lstat(runtime.socket, &current) == 0 and
            current.st_ino == bound.st_ino and current.st_dev == bound.st_dev)
        {
            if (c.unlink(runtime.socket) != 0) log.err("removing socket failed", .{});
        }
    }
    try installSignal(c.SIGTERM, stop);
    try installSignal(c.SIGINT, stop);
    var host: Host = .{ .allocator = allocator, .registry = .init(allocator) };
    defer host.deinit();
    var polls: std.ArrayListUnmanaged(c.struct_pollfd) = .empty;
    defer polls.deinit(allocator);
    var last_activity = try nowMs();
    while (!interrupted.load(.monotonic)) {
        try polls.resize(allocator, host.clients.items.len + 1);
        polls.items[0] = .{ .fd = listener, .events = c.POLLIN, .revents = 0 };
        for (host.clients.items, polls.items[1..]) |client, *item| item.* = .{
            .fd = client.fd,
            .events = if (client.outgoing != null) c.POLLOUT else c.POLLIN,
            .revents = 0,
        };
        var timeout: c_int = 100;
        for (host.clients.items) |client| {
            if (client.pending != null and client.outgoing == null) {
                timeout = 0;
                break;
            }
        }
        const count = c.poll(polls.items.ptr, @intCast(polls.items.len), timeout);
        if (count < 0) {
            if (wire.errno() == c.EINTR) continue;
            return error.ServerPollFailed;
        }
        const now = try nowMs();
        for (host.clients.items, polls.items[1..]) |*client, item| {
            host.tick(client, item.revents, now) catch |err| {
                if (err != error.EndOfStream) log.warn("client detached: {s}", .{@errorName(err)});
                client.closed = true;
            };
            if (item.revents != 0) last_activity = now;
            if (client.shutdown and client.closed) return;
        }
        var index = host.clients.items.len;
        while (index > 0) {
            index -= 1;
            if (!host.clients.items[index].closed) continue;
            var removed = host.clients.orderedRemove(index);
            removed.deinit(&host.registry);
            last_activity = now;
        }
        if (polls.items[0].revents & c.POLLIN != 0) {
            host.accept(listener, now) catch |err| {
                log.warn("accept rejected: {s}", .{@errorName(err)});
            };
        }
        if (host.attachedCount() == 0 and !host.registry.dirty() and now - last_activity >= idle_ms) return;
    }
}
