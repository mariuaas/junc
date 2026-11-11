//! Borrowed editing targets: a local Litura input/test document or one authoritative server buffer.
const std = @import("std");
const litura = @import("litura");
const Local = @import("local_document.zig");
const Remote = @import("Remote.zig");
const protocol = @import("protocol.zig");
const submission = @import("submission.zig");
const Syntax = @import("SyntaxCache.zig");

/// Borrows its engine/connection. Positions are Litura graphemes; strings expire with their
/// owner/view.
pub const Target = union(enum) {
    local: Local.Target,
    remote: struct { client: *Remote, buffer: u32 },

    pub fn position(self: Target) !u32 {
        return switch (self) {
            .local => |value| value.position(),
            .remote => |value| (try remoteState(value)).cursor,
        };
    }

    pub fn mark(self: Target) !?u32 {
        return switch (self) {
            .local => |value| value.mark(),
            .remote => |value| (try remoteState(value)).mark,
        };
    }

    fn remoteState(value: @FieldType(Target, "remote")) !protocol.Snapshot {
        const state = value.client.current();
        if (state.buffer != value.buffer) return error.BufferChanged;
        return state;
    }

    pub fn isMain(self: Target, document: ?*litura.BufferEngine) bool {
        return switch (self) {
            .remote => true,
            .local => |value| value.document == document,
        };
    }

    pub fn revision(self: Target) u32 {
        return switch (self) {
            .local => |value| value.document.revision,
            .remote => |value| value.client.current().revision,
        };
    }

    pub fn interactionRevision(self: Target) !u32 {
        return switch (self) {
            .local => |value| value.document.interactionRevision(value.session),
            .remote => |value| (try remoteState(value)).interaction_revision,
        };
    }

    /// Selection is owned through allocator; all other strings borrow the engine or current
    /// response.
    pub fn snapshot(self: Target, allocator: std.mem.Allocator) !protocol.Snapshot {
        switch (self) {
            .local => |value| return Local.snapshot(allocator, value, .{
                .id = 0,
                .name = if (value.document.path) |file_path| std.fs.path.basename(file_path) else "[scratch]",
                .path = value.document.path,
                .revision = value.document.revision,
                .dirty = value.document.dirty(),
            }),
            .remote => |value| {
                var state = try remoteState(value);
                state.selection = try allocator.dupe(u8, state.selection);
                return state;
            },
        }
    }

    /// Returns an owning summary allocated through allocator, for either host; release with
    /// Result.deinit.
    pub fn submit(
        self: Target,
        allocator: std.mem.Allocator,
        edit: protocol.Edit,
    ) !submission.Result {
        switch (self) {
            .local => |value| {
                var result = try Local.submit(value, edit);
                defer result.deinit(value.document.allocator);
                return submission.copy(allocator, Local.event(result));
            },
            .remote => |value| return value.client.submit(allocator, value.buffer, edit),
        }
    }

    pub fn path(self: Target) ?[]const u8 {
        return switch (self) {
            .local => |value| value.document.path,
            .remote => |value| value.client.current().path,
        };
    }

    pub fn name(self: Target) []const u8 {
        return switch (self) {
            .local => |value| if (value.document.path) |path_value|
                std.fs.path.basename(path_value)
            else
                "[scratch]",
            .remote => |value| value.client.current().name,
        };
    }

    pub fn bufferId(self: Target) u32 {
        return switch (self) {
            .local => 0,
            .remote => |value| value.buffer,
        };
    }

    pub fn dirty(self: Target) bool {
        return switch (self) {
            .local => |value| value.document.dirty(),
            .remote => |value| value.client.current().dirty,
        };
    }

    pub fn lineCount(self: Target) u32 {
        return switch (self) {
            .local => |value| value.document.lineCount(),
            .remote => |value| value.client.current().lines,
        };
    }

    pub fn graphemeCount(self: Target) u32 {
        return switch (self) {
            .local => |value| value.document.graphemeCount(),
            .remote => |value| value.client.current().count,
        };
    }

    pub fn positionToLineCol(self: Target, position_value: u32) !litura.piece_table.LineCol {
        switch (self) {
            .local => |value| return value.document.positionToLineCol(position_value),
            .remote => |value| {
                const state = try remoteState(value);
                if (state.cursor != position_value) return error.PositionNotObserved;
                return .{ .line = state.line, .col = state.col };
            },
        }
    }

    /// Called after clearing frontend cells, once per visible line range, never for each cell.
    /// Remote queries allocate/perform I/O; subsequent cell reads borrow the prepared view.
    pub fn prepareLines(self: Target, first_line: u32, line_count: u16) !void {
        switch (self) {
            .local => {},
            .remote => |value| try value.client.prepareView(value.buffer, first_line, line_count),
        }
    }

    pub fn observedLineEnd(self: Target) u32 {
        return switch (self) {
            .local => self.lineCount(),
            .remote => |value| if (value.client.view_frame) |frame|
                frame.value.view.?.first_line + @as(u32, @intCast(frame.value.view.?.lines.len))
            else
                0,
        };
    }

    fn viewLine(value: @FieldType(Target, "remote"), line: u32) !protocol.Line {
        const frame = value.client.view_frame orelse return error.ViewNotPrepared;
        const view = frame.value.view.?;
        if (view.buffer != value.buffer or view.revision != value.client.current().revision or
            line < view.first_line or line - view.first_line >= view.lines.len)
        {
            return error.LineNotObserved;
        }
        return view.lines[line - view.first_line];
    }

    pub fn lineStart(self: Target, line: u32) !u32 {
        return switch (self) {
            .local => |value| value.document.lineStart(line),
            .remote => |value| (try viewLine(value, line)).start,
        };
    }

    pub fn lineEnd(self: Target, line: u32, newline: bool) !u32 {
        return switch (self) {
            .local => |value| value.document.lineEnd(line, newline),
            .remote => |value| if (newline)
                (try viewLine(value, line)).end_with_newline
            else
                (try viewLine(value, line)).end,
        };
    }

    pub fn graphemeCursor(self: Target, position_value: u32) !Cursor {
        return switch (self) {
            .local => |value| .{
                .position = position_value,
                .backing = .{
                    .local = try value.document.graphemeCursor(position_value),
                },
            },
            .remote => |value| result: {
                const frame = value.client.view_frame orelse return error.ViewNotPrepared;
                const view = &frame.value.view.?;
                if (view.buffer != value.buffer or view.revision != value.client.current().revision) {
                    return error.ViewNotPrepared;
                }
                if (position_value < view.start or position_value > view.end) {
                    return error.PositionNotObserved;
                }
                // Store the stable Remote pointer, not a pointer into a temporary copy of Parsed.
                break :result .{
                    .position = position_value,
                    .backing = .{
                        .remote = value.client,
                    },
                };
            },
        };
    }

    pub fn updateSyntax(self: Target, syntax: *Syntax, range: litura.types.Range) !void {
        switch (self) {
            .local => |value| try syntax.update(value.document, range),
            .remote => |value| {
                const view = value.client.view_frame.?.value.view.?;
                if (syntax.revision == view.revision and syntax.start == view.start and
                    syntax.end == view.end)
                {
                    return;
                }
                const spans = try syntax.allocator.dupe(Syntax.Span, view.tokens);
                syntax.allocator.free(syntax.spans);
                syntax.spans = spans;
                syntax.revision = view.revision;
                syntax.start = view.start;
                syntax.end = view.end;
                syntax.state = view.syntax_state;
            },
        }
    }
};

/// Borrows the local piece table or the prepared immutable view until its next replacement.
pub const Cursor = struct {
    position: u32,
    backing: union(enum) { local: litura.piece_table.GraphemeCursor, remote: *Remote },

    pub fn current(self: *const Cursor) ![]const u8 {
        switch (self.backing) {
            .local => |*value| return value.current(),
            .remote => |value| {
                const view = value.view_frame.?.value.view.?;
                if (self.position < view.start or self.position >= view.end) return error.OutOfRange;
                const index = self.position - view.start;
                return view.text[view.boundaries[index]..view.boundaries[index + 1]];
            },
        }
    }

    pub fn advance(self: *Cursor) bool {
        switch (self.backing) {
            .local => |*value| {
                const valid = value.advance();
                self.position = value.position;
                return valid;
            },
            .remote => |value| {
                const end = value.view_frame.?.value.view.?.end;
                if (self.position >= end) return false;
                self.position += 1;
                return self.position < end;
            },
        }
    }
};
