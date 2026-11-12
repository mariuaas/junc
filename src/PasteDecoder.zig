//! libvaxis decodes terminal events; bracketed payload bytes remain literal until their end marker.
const std = @import("std");
const vaxis = @import("vaxis");
const Decoder = @This();

allocator: std.mem.Allocator,
parser: vaxis.Parser = .{},
active: bool = false,
bytes: std.ArrayListUnmanaged(u8) = .empty,
matched: usize = 0,

const terminator = "\x1b[201~";

/// Owns an incomplete paste. Completed paste events transfer their bytes to the caller.
pub fn init(allocator: std.mem.Allocator) Decoder {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Decoder) void {
    self.bytes.deinit(self.allocator);
    self.* = undefined;
}

/// Consumes a chunk or reports incomplete input with n=0. Ordinary events borrow input/parser storage;
/// paste events own bytes allocated through allocator. Dispose the decoder after an error.
pub fn parse(self: *Decoder, input: []const u8, options: struct {
    lone_escape: bool = false,
}) !vaxis.Parser.Result {
    std.debug.assert(input.len > 0);
    if (!self.active) {
        // Leave escape timing to the reader and incomplete UTF-8 to the next read.
        if (input.len == 1 and input[0] == 0x1b and !options.lone_escape) {
            return .{ .event = null, .n = 0 };
        }
        if (input[0] >= 0x80) {
            const length = std.unicode.utf8ByteSequenceLength(input[0]) catch
                return error.InvalidUTF8;
            if (input.len < length) return .{ .event = null, .n = 0 };
        }
        const result = try self.parser.parse(input, null);
        if (result.event) |event| if (event == .paste_start) {
            self.active = true;
            return .{ .event = null, .n = result.n };
        };
        return result;
    }
    // A mismatched prefix is literal payload. The delimiter has no overlapping proper prefixes.
    for (input, 0..) |byte, index| {
        if (byte != terminator[self.matched]) {
            try self.bytes.appendSlice(self.allocator, terminator[0..self.matched]);
            self.matched = 0;
        }
        if (byte == terminator[self.matched]) {
            self.matched += 1;
            if (self.matched == terminator.len) {
                const text = try self.bytes.toOwnedSlice(self.allocator);
                self.matched = 0;
                self.active = false;
                return .{ .event = .{ .paste = text }, .n = index + 1 };
            }
        } else try self.bytes.append(self.allocator, byte);
    }
    return .{ .event = null, .n = input.len };
}
