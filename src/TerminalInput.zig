//! Terminal reader with one owned event per paste; normal event decoding/capabilities use libvaxis.
const std = @import("std");
const vaxis = @import("vaxis");
const Input = @This();
const escape_wait_ms = 10;

allocator: std.mem.Allocator,
loop: vaxis.Loop(Event),
future: ?std.Io.Future(void) = null,
stopping: std.atomic.Value(bool) = .init(false),

pub const Decoder = @import("PasteDecoder.zig");
pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    color_report: vaxis.Color.Report,
    paste: []const u8,
    failure: []const u8,
};

/// Borrows tty/vaxis. Keep this instance stable after start, then deinit before either borrow ends.
pub fn init(io: std.Io, allocator: std.mem.Allocator, tty: *vaxis.Tty, vx: *vaxis.Vaxis) Input {
    return .{ .allocator = allocator, .loop = .init(io, tty, vx) };
}

pub fn start(self: *Input) !void {
    std.debug.assert(self.future == null);
    self.future = try self.loop.io.concurrent(run, .{self});
}

/// Cancels reads/queue waits, frees incomplete and queued input, and joins the reader.
pub fn deinit(self: *Input) void {
    self.stopping.store(true, .release);
    if (self.future) |*future| future.cancel(self.loop.io);
    while (self.loop.tryEvent() catch |err| failed: {
        std.log.scoped(.input).warn("draining input: {s}", .{@errorName(err)});
        break :failed null;
    }) |event| self.release(event);
    self.* = undefined;
}

/// Transfers ownership of key text/paste bytes; the caller must release every returned event.
pub fn tryEvent(self: *Input) !?Event {
    return self.loop.tryEvent();
}

pub fn release(self: *Input, event: Event) void {
    switch (event) {
        .key_press => |key| if (key.text) |text| self.allocator.free(text),
        .paste => |text| self.allocator.free(text),
        else => {},
    }
}

/// libvaxis's event adapter calls this. Key strings are copied before its scratch cache can wrap;
/// paste bytes are already owned. Failure frees the unqueued event. Allocates per ordinary text key.
pub fn postEvent(self: *Input, event: Event) !void {
    var owned = event;
    if (owned == .key_press) {
        if (owned.key_press.text) |text| owned.key_press.text = try self.allocator.dupe(u8, text);
    }
    errdefer self.release(owned);
    try self.loop.postEvent(owned);
}

fn run(self: *Input) void {
    self.read() catch |err| {
        if (self.stopping.load(.acquire)) return;
        self.postEvent(.{ .failure = @errorName(err) }) catch |post_error| {
            if (!self.stopping.load(.acquire)) {
                std.log.scoped(.input).err("reporting input failure: {s}", .{@errorName(post_error)});
            }
        };
    };
}

fn read(self: *Input) !void {
    var decoder = Decoder.init(self.allocator);
    defer decoder.deinit();
    var cache: vaxis.GraphemeCache = .{};
    var buffer: [4096]u8 = undefined;
    var retained: usize = 0;
    while (true) {
        if (retained == buffer.len) return error.TerminalSequenceTooLong;
        const count = try self.loop.tty.read(buffer[retained..]);
        if (count == 0) return error.EndOfStream;
        const length = retained + count;
        var offset: usize = 0;
        while (offset < length) {
            const pending = buffer[offset..length];
            var lone_escape = false;
            if (!decoder.active and pending.len == 1 and pending[0] == 0x1b) {
                // A brief ambiguity window distinguishes Escape from a fragmented Meta/CSI prefix.
                var descriptors = [1]std.posix.pollfd{.{
                    .fd = self.loop.tty.fd.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                _ = try std.posix.poll(&descriptors, escape_wait_ms);
                // macOS can report POLLNVAL for /dev/tty; match libvaxis's lone-Escape fallback.
                lone_escape = descriptors[0].revents & std.posix.POLL.IN == 0;
            }
            const result = try decoder.parse(pending, .{ .lone_escape = lone_escape });
            if (result.n == 0) break;
            offset += result.n;
            if (result.event) |event| {
                try vaxis.loop.handleEventGeneric(self, self.loop.vaxis, &cache, Event, event, null);
            }
        }
        retained = length - offset;
        std.mem.copyForwards(u8, buffer[0..retained], buffer[offset..length]);
    }
}
