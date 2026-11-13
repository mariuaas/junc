//! A client's attachment to the authoritative host and its immutable observations. Owns no
//! main-document engine or text replica. The host is a local server socket or, without a daemon,
//! an in-process host; both answer the same requests, so observation and submission share one path.
const std = @import("std");
const c = @import("host_c");
const paths = @import("paths.zig");
const wire = @import("wire.zig");
const protocol = @import("protocol.zig");
const submission = @import("submission.zig");
const InProcessHost = @import("InProcessHost.zig");
const Connection = @This();
const log = std.log.scoped(.client);

allocator: std.mem.Allocator,
transport: Transport,
next_id: u32 = 1,
server_pid: i32 = 0,
state_frame: ?std.json.Parsed(protocol.Response) = null,
view_frame: ?std.json.Parsed(protocol.Response) = null,
view_invalidated: bool = false,
observed_generation: u64 = 0,
invalidated_generation: u64 = 0,
needs_refresh: bool = false,
message: [512]u8 = @splat(0),
message_len: usize = 0,

const Transport = union(enum) {
    /// Owns the descriptor; fd is -1 once the connection is lost.
    socket: struct { fd: c_int, reader: wire.Reader = .{}, attached: bool = false },
    /// Borrows a host that outlives this connection. It never sends invalidation hints.
    in_process: *InProcessHost,
};

/// Connects to the per-user host, spawning a detached executable under its lifetime lock if absent.
/// Owns the descriptor and response arenas. The caller must deinit and must not copy the live
/// value. Call open or select before observing.
pub fn connect(allocator: std.mem.Allocator, options: struct {
    executable: [:0]const u8,
    runtime_directory: ?[]const u8 = null,
}) !Connection {
    var runtime = try paths.Runtime.init(allocator, .{ .directory = options.runtime_directory });
    defer runtime.deinit();
    var spawned = false;
    const start = try nowMs();
    while ((try nowMs()) - start < 5000) {
        if (try tryConnect(&runtime)) |fd| {
            var connection: Connection = .{ .allocator = allocator, .transport = .{ .socket = .{ .fd = fd } } };
            errdefer connection.deinit();
            const response = connection.call(.{ .id = 0, .op = .hello }) catch |err| {
                if (err == error.ConnectionLost) {
                    connection.deinit();
                    continue;
                }
                if (err == error.ServerBusy or err == error.IncompatibleServer) {
                    log.err("{s}", .{connection.errorMessage()});
                }
                return err;
            };
            defer response.deinit();
            connection.transport.socket.attached = true;
            return connection;
        }
        const lock = try runtime.openLock();
        if (c.flock(lock, c.LOCK_EX | c.LOCK_NB) == 0) {
            defer _ = c.close(lock);
            if (spawned) return error.ServerStartupFailed;
            try spawn(options.executable, &runtime, lock);
            spawned = true;
        } else {
            const code = wire.errno();
            _ = c.close(lock);
            if (code != c.EWOULDBLOCK and code != c.EAGAIN) return error.ServerLockFailed;
        }
        const delay: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 10_000_000 };
        _ = c.nanosleep(&delay, null);
    }
    return error.ServerStartupTimedOut;
}

fn nowMs() !i64 {
    var value: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &value) != 0) return error.MonotonicClockUnavailable;
    return @as(i64, @intCast(value.tv_sec)) * 1000 + @divTrunc(value.tv_nsec, 1_000_000);
}

fn tryConnect(runtime: *const paths.Runtime) !?c_int {
    if (!try runtime.checkSocket()) return null;
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketCreateFailed;
    errdefer _ = c.close(fd);
    var address = runtime.address();
    if (c.connect(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) {
        const code = wire.errno();
        if (code == c.ECONNREFUSED or code == c.ENOENT) {
            _ = c.close(fd);
            return null;
        }
        return error.SocketConnectFailed;
    }
    try wire.configure(fd, 30);
    if (c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) != 0) return error.SocketOptionFailed;
    return fd;
}

fn ignoreHangup(_: c_int) callconv(.c) void {}

fn spawn(executable: [:0]const u8, runtime: *const paths.Runtime, lock: c_int) !void {
    const argv = [_:null]?[*:0]const u8{ executable.ptr, "--serve", "3", runtime.directory.ptr };
    const log_fd = try runtime.openLog();
    defer _ = c.close(log_fd);
    const descriptor_limit = c.sysconf(c._SC_OPEN_MAX);
    if (descriptor_limit < 4 or descriptor_limit > std.math.maxInt(c_int)) return error.ServerFdLimitFailed;
    const child = c.fork();
    if (child < 0) return error.ServerForkFailed;
    if (child == 0) {
        // Only async-signal-safe C operations occur between fork and exec. No allocator or Zig Io.
        _ = c.signal(c.SIGHUP, ignoreHangup);
        if (c.setsid() < 0) c._exit(126);
        const detached = c.fork();
        if (detached < 0) c._exit(126);
        if (detached != 0) c._exit(0);
        const null_fd = c.open("/dev/null", c.O_RDWR);
        if (null_fd < 0) c._exit(126);
        for (0..2) |index| {
            if (c.dup2(null_fd, @intCast(index)) < 0) c._exit(126);
        }
        if (c.dup2(log_fd, 2) < 0) c._exit(126);
        _ = c.close(log_fd);
        if (null_fd > 2) _ = c.close(null_fd);
        if (lock != 3) {
            if (c.dup2(lock, 3) < 0) c._exit(126);
        }
        if (c.chdir("/") != 0 or c.fcntl(3, c.F_SETFD, @as(c_int, 0)) != 0) c._exit(126);
        var descriptor: c_int = 4;
        while (descriptor < descriptor_limit) : (descriptor += 1) {
            _ = c.close(descriptor);
        }
        _ = c.execv(executable, @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    var status: c_int = 0;
    while (c.waitpid(child, &status, 0) < 0) {
        if (wire.errno() != c.EINTR) return error.ServerWaitFailed;
    }
    if (status != 0) return error.ServerForkFailed;
}

/// Attaches to an in-process host and selects its initial buffer. The host must outlive the
/// returned connection, which must not be copied while live.
pub fn attach(allocator: std.mem.Allocator, host: *InProcessHost) !Connection {
    var connection: Connection = .{ .allocator = allocator, .transport = .{ .in_process = host } };
    errdefer connection.deinit();
    try connection.select(host.initial_buffer);
    return connection;
}

pub fn deinit(self: *Connection) void {
    switch (self.transport) {
        .socket => |*socket| {
            if (socket.attached and socket.fd >= 0) {
                const response = self.call(.{ .id = 0, .op = .detach }) catch |err| failed: {
                    log.warn("detach acknowledgement unavailable: {s}", .{@errorName(err)});
                    break :failed null;
                };
                if (response) |value| value.deinit();
            }
            if (socket.fd >= 0) _ = c.close(socket.fd);
            socket.reader.deinit(self.allocator);
        },
        .in_process => {},
    }
    if (self.state_frame) |value| value.deinit();
    if (self.view_frame) |value| value.deinit();
    self.* = undefined;
}

pub fn errorMessage(self: *const Connection) []const u8 {
    return self.message[0..self.message_len];
}

/// False once a socket transport has been lost; an in-process host is always reachable.
pub fn connected(self: *const Connection) bool {
    return switch (self.transport) {
        .socket => |socket| socket.fd >= 0,
        .in_process => true,
    };
}

fn disconnect(self: *Connection) void {
    const socket = &self.transport.socket;
    if (socket.fd >= 0) _ = c.close(socket.fd);
    socket.fd = -1;
    socket.attached = false;
}

fn nextFrame(self: *Connection, wait: bool) !?std.json.Parsed(protocol.Response) {
    const socket = &self.transport.socket;
    const started = try nowMs();
    while (true) {
        if (try socket.reader.next(self.allocator, socket.fd)) |bytes| {
            defer self.allocator.free(bytes);
            try self.checkVersion(bytes);
            return try std.json.parseFromSlice(protocol.Response, self.allocator, bytes, .{
                .allocate = .alloc_always,
            });
        }
        if (!wait) return null;
        if ((try nowMs()) - started >= 30_000) return error.ResponseTimedOut;
        var descriptor: c.struct_pollfd = .{ .fd = socket.fd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&descriptor, 1, 100) < 0 and wire.errno() != c.EINTR) return error.SocketPollFailed;
    }
}

// Rejects a frame from a server speaking another protocol version before decoding the rest, whose
// shape may differ. Records an explanation for the user.
fn checkVersion(self: *Connection, bytes: []const u8) !void {
    const envelope = std.json.parseFromSlice(protocol.Envelope, self.allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidServerResponse,
    };
    defer envelope.deinit();
    if (envelope.value.version == protocol.version) return;
    const message = std.fmt.bufPrint(
        &self.message,
        "The running junc server speaks hosting protocol {d}, but this client needs {d}. " ++
            "Stop it with shutdown-server from its own junc executable, then start again.",
        .{ envelope.value.version, protocol.version },
    ) catch "The running junc server speaks an incompatible hosting protocol.";
    if (message.ptr != &self.message) @memcpy(self.message[0..message.len], message);
    self.message_len = message.len;
    return error.IncompatibleServer;
}

fn notice(self: *Connection, response: protocol.Response) !void {
    if (response.version != protocol.version or response.id != 0) return error.InvalidServerResponse;
    const invalidation = response.invalidation orelse return error.InvalidServerResponse;
    if (invalidation.generation <= self.observed_generation) return;
    if (self.state_frame == null and self.view_frame == null) return;
    if (invalidation.buffer) |id| if (id != self.current().buffer) return;
    self.invalidated_generation = @max(self.invalidated_generation, invalidation.generation);
    self.needs_refresh = true;
    self.view_invalidated = true;
}

/// Consumes only coalescible hosting hints while idle. No document command is synthesized or
/// retried.
pub fn pollInvalidations(self: *Connection) !bool {
    if (self.transport == .in_process) return self.needs_refresh;
    if (!self.connected()) return error.ConnectionLost;
    errdefer self.disconnect();
    while (true) {
        const frame = (self.nextFrame(false) catch |err| switch (err) {
            error.EndOfStream, error.SocketReadFailed => return error.ConnectionLost,
            else => return err,
        }) orelse return self.needs_refresh;
        defer frame.deinit();
        try self.notice(frame.value);
    }
}

/// Success returns an owning decoded response; the caller must deinit it. Failure can replace
/// current state.
/// One request/response exchange. Hints can precede a reply; they never replace it or change its
/// origin.
/// Once transmitted, a command is never retried, including after a stale-coordinate rejection.
pub fn call(self: *Connection, request: protocol.Request) !std.json.Parsed(protocol.Response) {
    if (!self.connected()) return error.ConnectionLost;
    if (self.next_id == std.math.maxInt(u32)) return error.RequestIdsExhausted;
    var outgoing = request;
    outgoing.id = self.next_id;
    self.message_len = 0;
    const response = switch (self.transport) {
        .socket => try self.exchange(outgoing),
        .in_process => |host| result: {
            self.next_id += 1;
            break :result try host.call(self.allocator, outgoing);
        },
    };
    if (response.value.version != protocol.version or response.value.id != outgoing.id) {
        response.deinit();
        if (self.transport == .socket) self.disconnect();
        return error.InvalidServerResponse;
    }
    self.server_pid = response.value.server_pid;
    if (response.value.failure) |failure| {
        const busy = std.mem.eql(u8, failure.code, "Busy");
        self.message_len = @min(self.message.len, failure.message.len);
        @memcpy(self.message[0..self.message_len], failure.message[0..self.message_len]);
        if (response.value.state != null) try self.acceptState(response) else response.deinit();
        return if (busy) error.ServerBusy else error.ServerRejected;
    }
    return response;
}

// Sends one framed request and returns the first reply frame, consuming hints that precede it.
fn exchange(self: *Connection, outgoing: protocol.Request) !std.json.Parsed(protocol.Response) {
    wire.sendRequest(self.allocator, self.transport.socket.fd, outgoing) catch |err| {
        if (err == error.OutOfMemory or err == error.FrameTooLarge) return err;
        self.disconnect();
        return error.ConnectionLost;
    };
    self.next_id += 1;
    while (true) {
        const response = (self.nextFrame(true) catch |err| {
            self.disconnect();
            return if (err == error.IncompatibleServer) err else error.ConnectionLost;
        }).?;
        if (response.value.id != 0) return response;
        self.notice(response.value) catch |err| {
            response.deinit();
            self.disconnect();
            return err;
        };
        response.deinit();
    }
}

/// Borrows the latest observation; state-changing calls or prepareView can invalidate its strings.
pub fn current(self: *const Connection) protocol.Snapshot {
    if (self.state_frame) |frame| return frame.value.state.?;
    std.debug.assert(self.view_frame != null);
    return self.view_frame.?.value.state.?;
}

fn acceptState(self: *Connection, response: std.json.Parsed(protocol.Response)) !void {
    if (response.value.state == null) {
        response.deinit();
        return error.InvalidServerResponse;
    }
    if (self.state_frame) |old| old.deinit();
    self.state_frame = response;
    self.observed_generation = @max(self.observed_generation, response.value.generation);
    self.needs_refresh = self.invalidated_generation > response.value.generation;
    self.view_invalidated = true;
    // Keep the previous view alive until the frontend has cleared its borrowed cells and prepares
    // another.
}

fn absolutePath(self: *Connection, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = try std.process.currentPathAlloc(io, self.allocator);
    defer self.allocator.free(cwd);
    return std.fs.path.resolve(self.allocator, &.{ cwd, path });
}

/// Opens/selects a file or new scratch buffer; adopts the response without creating a local
/// document.
pub fn open(self: *Connection, options: struct { path: ?[]const u8 = null }) !void {
    const path = options.path;
    const absolute = if (path) |value| try self.absolutePath(value) else null;
    defer if (absolute) |value| self.allocator.free(value);
    try self.acceptState(try self.call(.{ .id = 0, .op = .open, .path = absolute }));
}

pub fn select(self: *Connection, id: u32) !void {
    try self.acceptState(try self.call(.{ .id = 0, .op = .select, .buffer = id }));
}

pub fn kill(self: *Connection, id: u32, discard: bool) !void {
    try self.acceptState(try self.call(.{
        .id = 0,
        .op = .kill,
        .buffer = id,
        .discard = discard,
    }));
}

/// Saves to the supplied path or existing buffer path; unnamed buffers require an explicit path.
pub fn save(self: *Connection, options: struct { path: ?[]const u8 = null }) !void {
    const absolute = if (options.path) |path| try self.absolutePath(path) else null;
    defer if (absolute) |value| self.allocator.free(value);
    try self.acceptState(try self.call(.{
        .id = 0,
        .op = .save,
        .buffer = self.current().buffer,
        .path = absolute,
    }));
    self.view_invalidated = true;
}

/// Returns a result owned through result_allocator; transmitted edits are never replayed.
/// The authoritative mutation may precede an allocation/connection failure while receiving its
/// result.
pub fn submit(
    self: *Connection,
    result_allocator: std.mem.Allocator,
    id: u32,
    edit: protocol.Edit,
) !submission.Result {
    const response = try self.call(.{ .id = 0, .op = .submit, .buffer = id, .edit = edit });
    const event = response.value.event orelse {
        response.deinit();
        return error.InvalidServerResponse;
    };
    var result = submission.copy(result_allocator, event) catch |err| {
        response.deinit();
        return err;
    };
    errdefer result.deinit(result_allocator);
    try self.acceptState(response);
    return result;
}

/// Observes lines of the selected buffer starting at first_line, together with a fresh snapshot.
/// The host clamps first_line to the document; it does not move the range to follow the cursor.
/// Views are cached only by authoritative buffer/revision/range; no speculative edits are applied.
/// Allocates and performs a request unless the cached view still matches. The previous view's
/// strings are released, so clear cells borrowing them first.
pub fn prepareView(self: *Connection, first_line: u32, line_count: u16) !void {
    const id = self.current().buffer;
    const rows = @max(1, line_count);
    if (self.view_frame) |frame| {
        const cached = frame.value.view.?;
        const count = if (first_line < self.current().lines)
            @min(rows, self.current().lines - first_line)
        else
            0;
        if (!self.needs_refresh and !self.view_invalidated and cached.buffer == id and
            cached.revision == self.current().revision and
            cached.first_line == first_line and cached.lines.len == count)
        {
            return;
        }
    }
    const response = try self.call(.{
        .id = 0,
        .op = .observe,
        .buffer = id,
        .first_line = first_line,
        .line_count = rows,
    });
    errdefer response.deinit();
    const observed = response.value.view orelse return error.InvalidServerResponse;
    const state = response.value.state orelse return error.InvalidServerResponse;
    if (observed.buffer != id or state.buffer != id or observed.revision != state.revision or
        observed.boundaries.len != observed.end - observed.start + 1)
    {
        return error.InvalidServerResponse;
    }
    if (self.view_frame) |old| old.deinit();
    if (self.state_frame) |old| old.deinit();
    self.state_frame = null;
    self.view_frame = response;
    self.observed_generation = @max(self.observed_generation, response.value.generation);
    self.needs_refresh = self.invalidated_generation > response.value.generation;
    self.view_invalidated = self.needs_refresh;
}

/// Grapheme offset of column on line, clamped to that line's content. Observes that one line and
/// replaces the prepared view.
pub fn linePosition(self: *Connection, line: u32, column: u32) !u32 {
    const lines = self.current().lines;
    if (lines == 0) return 0;
    const number = @min(line, lines - 1);
    try self.prepareView(number, 1);
    const observed = self.view() orelse return error.ViewNotPrepared;
    const row = observed.lines[0];
    return @min(row.start + column, row.end);
}

/// Borrows the prepared view while it observes the current buffer and revision; null otherwise.
/// Strings stay valid until the next successful prepareView or deinit.
pub fn view(self: *const Connection) ?*const protocol.View {
    if (self.view_frame == null) return null;
    const observed = &self.view_frame.?.value.view.?;
    const state = self.current();
    if (observed.buffer != state.buffer or observed.revision != state.revision) return null;
    return observed;
}

pub fn shutdown(self: *Connection) !void {
    const response = try self.call(.{ .id = 0, .op = .shutdown });
    response.deinit();
    switch (self.transport) {
        .socket => |*socket| socket.attached = false,
        .in_process => {},
    }
}
