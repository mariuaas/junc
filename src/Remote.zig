//! Owns one local connection and immutable observations, never a main-document engine or text
//! replica.
const std = @import("std");
const c = @import("host_c");
const paths = @import("paths.zig");
const wire = @import("wire.zig");
const protocol = @import("protocol.zig");
const submission = @import("submission.zig");
const Remote = @This();
const log = std.log.scoped(.client);

allocator: std.mem.Allocator,
fd: c_int,
next_id: u32 = 1,
server_pid: i32 = 0,
attached: bool = false,
state_frame: ?std.json.Parsed(protocol.Response) = null,
view_frame: ?std.json.Parsed(protocol.Response) = null,
view_invalidated: bool = false,
reader: wire.Reader = .{},
observed_generation: u64 = 0,
invalidated_generation: u64 = 0,
needs_refresh: bool = false,
message: [512]u8 = @splat(0),
message_len: usize = 0,

/// Connects to the per-user host, spawning a detached executable under its lifetime lock if absent.
/// Owns the descriptor and response arenas. The caller must deinit and must not copy the live
/// value.
pub fn connect(allocator: std.mem.Allocator, options: struct {
    executable: [:0]const u8,
    runtime_directory: ?[]const u8 = null,
}) !Remote {
    var runtime = try paths.Runtime.init(allocator, .{ .directory = options.runtime_directory });
    defer runtime.deinit();
    var spawned = false;
    const start = try nowMs();
    while ((try nowMs()) - start < 5000) {
        if (try tryConnect(&runtime)) |fd| {
            var remote: Remote = .{ .allocator = allocator, .fd = fd };
            errdefer remote.deinit();
            const response = remote.call(.{ .id = 0, .op = .hello }) catch |err| {
                if (err == error.ConnectionLost) {
                    remote.deinit();
                    continue;
                }
                if (err == error.ServerBusy) log.err("{s}", .{remote.errorMessage()});
                return err;
            };
            defer response.deinit();
            remote.attached = true;
            return remote;
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
        for (0..3) |index| {
            if (c.dup2(null_fd, @intCast(index)) < 0) c._exit(126);
        }
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

pub fn deinit(self: *Remote) void {
    if (self.attached and self.fd >= 0) {
        const response = self.call(.{ .id = 0, .op = .detach }) catch |err| failed: {
            log.warn("detach acknowledgement unavailable: {s}", .{@errorName(err)});
            break :failed null;
        };
        if (response) |value| value.deinit();
    }
    if (self.fd >= 0) _ = c.close(self.fd);
    self.reader.deinit(self.allocator);
    if (self.state_frame) |value| value.deinit();
    if (self.view_frame) |value| value.deinit();
    self.* = undefined;
}

pub fn errorMessage(self: *const Remote) []const u8 {
    return self.message[0..self.message_len];
}

fn disconnect(self: *Remote) void {
    if (self.fd >= 0) _ = c.close(self.fd);
    self.fd = -1;
    self.attached = false;
}

fn nextFrame(self: *Remote, wait: bool) !?std.json.Parsed(protocol.Response) {
    const started = try nowMs();
    while (true) {
        if (try self.reader.next(self.allocator, self.fd)) |bytes| {
            defer self.allocator.free(bytes);
            return try std.json.parseFromSlice(protocol.Response, self.allocator, bytes, .{
                .allocate = .alloc_always,
            });
        }
        if (!wait) return null;
        if ((try nowMs()) - started >= 30_000) return error.ResponseTimedOut;
        var descriptor: c.struct_pollfd = .{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&descriptor, 1, 100) < 0 and wire.errno() != c.EINTR) return error.SocketPollFailed;
    }
}

fn notice(self: *Remote, response: protocol.Response) !void {
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
pub fn pollInvalidations(self: *Remote) !bool {
    if (self.fd < 0) return error.ConnectionLost;
    errdefer self.disconnect();
    while (try self.nextFrame(false)) |frame| {
        defer frame.deinit();
        try self.notice(frame.value);
    }
    return self.needs_refresh;
}

/// Success returns an owning decoded response; the caller must deinit it. Failure can replace
/// current state.
/// One request/response exchange. Hints can precede a reply; they never replace it or change its
/// origin.
/// Once transmitted, a command is never retried, including after a stale-coordinate rejection.
pub fn call(self: *Remote, request: protocol.Request) !std.json.Parsed(protocol.Response) {
    if (self.fd < 0) return error.ConnectionLost;
    if (self.next_id == std.math.maxInt(u32)) return error.RequestIdsExhausted;
    var outgoing = request;
    outgoing.id = self.next_id;
    self.message_len = 0;
    wire.sendRequest(self.allocator, self.fd, outgoing) catch |err| {
        if (err == error.OutOfMemory or err == error.FrameTooLarge) return err;
        self.disconnect();
        return error.ConnectionLost;
    };
    self.next_id += 1;
    while (true) {
        const response = (self.nextFrame(true) catch {
            self.disconnect();
            return error.ConnectionLost;
        }).?;
        if (response.value.id == 0) {
            self.notice(response.value) catch |err| {
                response.deinit();
                self.disconnect();
                return err;
            };
            response.deinit();
            continue;
        }
        if (response.value.version != protocol.version or response.value.id != outgoing.id) {
            response.deinit();
            self.disconnect();
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
}

/// Borrows the latest observation; state-changing calls or prepareView can invalidate its strings.
pub fn current(self: *const Remote) protocol.Snapshot {
    if (self.state_frame) |frame| return frame.value.state.?;
    std.debug.assert(self.view_frame != null);
    return self.view_frame.?.value.state.?;
}

fn acceptState(self: *Remote, response: std.json.Parsed(protocol.Response)) !void {
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

fn absolutePath(self: *Remote, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = try std.process.currentPathAlloc(io, self.allocator);
    defer self.allocator.free(cwd);
    return std.fs.path.resolve(self.allocator, &.{ cwd, path });
}

/// Opens/selects a file or new scratch buffer; adopts the response without creating a local
/// document.
pub fn open(self: *Remote, options: struct { path: ?[]const u8 = null }) !void {
    const path = options.path;
    const absolute = if (path) |value| try self.absolutePath(value) else null;
    defer if (absolute) |value| self.allocator.free(value);
    try self.acceptState(try self.call(.{ .id = 0, .op = .open, .path = absolute }));
}

pub fn select(self: *Remote, id: u32) !void {
    try self.acceptState(try self.call(.{ .id = 0, .op = .select, .buffer = id }));
}

pub fn kill(self: *Remote, id: u32, discard: bool) !void {
    try self.acceptState(try self.call(.{
        .id = 0,
        .op = .kill,
        .buffer = id,
        .discard = discard,
    }));
}

pub fn save(self: *Remote, options: struct { path: ?[]const u8 = null }) !void {
    const path = options.path;
    const explicit: ?[]const u8 = if (path) |value|
        value
    else if (self.current().path == null)
        "scratch.txt"
    else
        null;
    const absolute = if (explicit) |value| try self.absolutePath(value) else null;
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
    self: *Remote,
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

/// Views are cached only by authoritative buffer/revision/range; no speculative edits are applied.
/// Returned strings stay valid until the next successful prepareView or deinit.
pub fn prepareView(self: *Remote, id: u32, first_line: u32, line_count: u16) !void {
    if (self.current().buffer != id) return error.BufferChanged;
    const rows = @max(1, line_count);
    if (self.view_frame) |frame| {
        const view = frame.value.view.?;
        const count = if (first_line < self.current().lines)
            @min(rows, self.current().lines - first_line)
        else
            0;
        if (!self.needs_refresh and !self.view_invalidated and view.buffer == id and
            view.revision == self.current().revision and
            view.first_line == first_line and view.lines.len == count)
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
    const view = response.value.view orelse return error.InvalidServerResponse;
    const state = response.value.state orelse return error.InvalidServerResponse;
    if (view.buffer != id or state.buffer != id or view.revision != state.revision or
        view.boundaries.len != view.end - view.start + 1)
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

pub fn shutdown(self: *Remote) !void {
    const response = try self.call(.{ .id = 0, .op = .shutdown });
    response.deinit();
    self.attached = false;
}
