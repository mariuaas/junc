//! Public syntax integration and real libvaxis cells, without a terminal process.
const std = @import("std");
const junc = @import("junc");
const Fixture = @import("Fixture.zig");
const vaxis = @import("vaxis");
const Surface = @import("surface");
const allocator = std.testing.allocator;
const keyword_index = @intFromEnum(junc.syntax.Category.keyword);

fn command(editor: *junc.Editor, key: []const u8, text: []const u8) !void {
    if (try editor.dispatch(key, text)) |value| {
        var result = value;
        defer result.deinit(allocator);
        try std.testing.expect(result != .validation_report);
    }
}

// Queries the hosted buffer's token cache over the whole document, as a full-height view would.
fn update(fixture: *Fixture) !void {
    const range: junc.litura.types.Range = .{ .start = 0, .end = fixture.document().graphemeCount() };
    try fixture.buffer().syntax.update(fixture.document(), range);
    _ = try fixture.host.maintain(.unlimited);
    _ = try fixture.connection.pollInvalidations();
    try fixture.buffer().syntax.update(fixture.document(), range);
}

fn window(screen: *vaxis.Screen) vaxis.Window {
    return .{
        .screen = screen,
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
    };
}

test "explicit language registry attaches Litura token providers for Zig and Lua" {
    try std.testing.expectEqual(junc.Syntax.Language.zig, junc.Syntax.detect("src/main.zig").?);
    try std.testing.expectEqual(junc.Syntax.Language.lua, junc.Syntax.detect("style.lua").?);
    try std.testing.expect(junc.Syntax.detect(null) == null);
    try std.testing.expect(junc.Syntax.detect("notes.txt") == null);
    if (comptime !junc.litura.tree_sitter_enabled) return error.SkipZigTest;
    const samples = [_][2][]const u8{
        .{ "sample.zig", "const value = \"界é\"; // comment\n" },
        .{ "sample.lua", "local value = \"界é\" -- comment\n" },
    };
    for (samples) |sample| {
        const fixture = try Fixture.create(allocator, sample[1], sample[0]);
        defer fixture.destroy();
        // The host attaches providers lazily, on the first observation; attaching does not parse.
        const cache = &fixture.buffer().syntax;
        try cache.attach(fixture.document());
        try std.testing.expect(fixture.document().hasViewProvider("tokens"));
        try std.testing.expect(!fixture.document().hasViewProvider("syntax"));
        try std.testing.expectEqual(junc.litura.views.ViewStateKind.stale, fixture.document().queryViewState("tokens").kind);
        try update(fixture);
        try std.testing.expect(cache.spans.len > 0);
        var found_string = false;
        for (cache.spans) |span| {
            if (span.category != .string) continue;
            const text = try fixture.document().getTextRange(span.start, span.end);
            defer allocator.free(text);
            if (std.mem.indexOf(u8, text, "界é") != null) found_string = true;
        }
        try std.testing.expect(found_string);
        try std.testing.expectEqual(@as(u32, 0), fixture.document().revision);
    }
}

test "visible token cache refreshes after edit undo redo but not scrolling or color reload" {
    if (comptime !junc.litura.tree_sitter_enabled) return error.SkipZigTest;
    const fixture = try Fixture.create(allocator, "local x = 1\nreturn x\n", "test.lua");
    defer fixture.destroy();
    const editor = &fixture.editor;
    const cache = &fixture.buffer().syntax;
    try update(fixture);
    try std.testing.expectEqual(junc.syntax.Category.keyword, cache.categoryAt(0).?);
    const refreshes = cache.refresh_count;
    try update(fixture);
    try std.testing.expectEqual(@as(usize, 1), cache.query_count);
    try cache.update(fixture.document(), .{
        .start = 12,
        .end = fixture.document().graphemeCount(),
    });
    try std.testing.expectEqual(refreshes, cache.refresh_count);
    try command(editor, "text", "-- ");
    try update(fixture);
    try std.testing.expectEqual(junc.syntax.Category.comment, cache.categoryAt(0).?);
    try command(editor, "ctrl-z", "");
    try update(fixture);
    try std.testing.expectEqual(junc.syntax.Category.keyword, cache.categoryAt(0).?);
    try command(editor, "ctrl-y", "");
    try update(fixture);
    try std.testing.expectEqual(junc.syntax.Category.comment, cache.categoryAt(0).?);
    try std.testing.expectEqual(refreshes + 3, cache.refresh_count);
    const revision = fixture.document().revision;
    const interaction = try fixture.document().interactionRevision(fixture.session());
    const queries = cache.query_count;
    const source = try std.mem.concat(allocator, u8, &.{
        "local p=(function()\n",                                                         junc.presentation.default_source,
        "\nend)(); p.presets.classic.syntax.keyword={fg='#010203',bold=true}; return p",
    });
    defer allocator.free(source);
    try editor.reloadSources(null, source);
    try update(fixture);
    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, editor.presentation.syntax[keyword_index].fg.?.rgb);
    try std.testing.expectEqual(queries, cache.query_count);
    try std.testing.expectEqual(refreshes + 3, cache.refresh_count);
    try std.testing.expectEqual(revision, fixture.document().revision);
    try std.testing.expectEqual(interaction, try fixture.document().interactionRevision(fixture.session()));
    const before = editor.presentation;
    const bad = try std.mem.concat(allocator, u8, &.{
        "local p=(function()\n",                                                    junc.presentation.default_source,
        "\nend)(); p.presets.minimal.syntax={keyword={underline='yes'}}; return p",
    });
    defer allocator.free(bad);
    try std.testing.expectError(error.InvalidPresentation, editor.reloadSources(null, bad));
    try std.testing.expectEqualDeep(before, editor.presentation);
}

test "unknown languages and missing providers remain editable" {
    const unknown_fixture = try Fixture.create(allocator, "text", "notes.txt");
    defer unknown_fixture.destroy();
    const unknown = &unknown_fixture.editor;
    try update(unknown_fixture);
    try std.testing.expect(!unknown_fixture.document().hasViewProvider("tokens"));
    if (comptime !junc.litura.tree_sitter_enabled) {
        const missing_fixture = try Fixture.create(allocator, "local x=1", "sample.lua");
        defer missing_fixture.destroy();
        const missing = &missing_fixture.editor;
        try update(missing_fixture);
        try command(missing, "text", "a");
        try std.testing.expectEqual(junc.Syntax.State.plain, missing_fixture.buffer().syntax.state);
    }
    try command(unknown, "text", "a");
}

test "Unicode tokens map to cells through grapheme positions with horizontal clipping and precedence" {
    if (comptime !junc.litura.tree_sitter_enabled) return error.SkipZigTest;
    const fixture = try Fixture.create(allocator, "local s = \"界é\"\n", "sample.lua");
    defer fixture.destroy();
    const editor = &fixture.editor;
    try editor.setPreset("minimal");
    try command(editor, "end", "");
    try update(fixture);
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 24,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);
    const win = window(&screen);
    var surface: Surface = .{};
    defer surface.deinit(allocator);
    editor.viewport.left = 11;
    try surface.draw(editor, win);
    const wide = win.readCell(0, 0).?;
    try std.testing.expectEqualStrings("界", wide.char.grapheme);
    try std.testing.expectEqual(@as(u8, 2), wide.char.width);
    try std.testing.expectEqualStrings("é", win.readCell(2, 0).?.char.grapheme);
    try std.testing.expect(vaxis.Color.eql(wide.style.fg, .{ .rgb = .{ 184, 206, 154 } }));
    // Clipping through a wide grapheme leaves a blank cell, never half a glyph.
    editor.viewport.left = 12;
    try surface.draw(editor, win);
    try std.testing.expectEqualStrings(" ", win.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("é", win.readCell(1, 0).?.char.grapheme);
    try command(editor, "home", "");
    editor.viewport.left = 0;
    try command(editor, "shift-right", "");
    try surface.draw(editor, win);
    const selection = win.readCell(0, 0).?.style;
    try std.testing.expect(vaxis.Color.eql(selection.bg, .{ .rgb = .{ 184, 206, 154 } }));
    try std.testing.expect(!selection.bold);
    try std.testing.expect(!selection.italic);
    const cursor = win.readCell(1, 0).?.style;
    try std.testing.expect(vaxis.Color.eql(cursor.bg, .{ .rgb = .{ 237, 207, 142 } }));
    try std.testing.expect(!cursor.bold);
    try std.testing.expectEqual(vaxis.Style.Underline.off, cursor.ul_style);
    // An unselected keyword keeps its syntax attributes.
    try std.testing.expect(win.readCell(2, 0).?.style.bold);
    surface.monochrome = true;
    try surface.draw(editor, win);
    try std.testing.expect(win.readCell(2, 0).?.style.bold);
    try std.testing.expect(win.readCell(0, 0).?.style.reverse);
}

test "an unavailable provider falls back without repeated refresh attempts in the same revision" {
    var document = try junc.litura.BufferEngine.initFromText(allocator, "local x=1", null);
    defer document.deinit();
    var provider: junc.litura.views.StaticTokenProvider = .{ .spans = &.{}, .stale = true };
    var table = provider.provider().vtable.*;
    const Failing = struct {
        fn state(ptr: *anyopaque, _: []const u8, revision: u32) junc.litura.views.ViewState {
            const static: *junc.litura.views.StaticTokenProvider = @ptrCast(@alignCast(ptr));
            return .{ .view = "tokens", .revision = revision, .kind = if (static.stale) .stale else .unavailable };
        }
        fn refresh(
            ptr: *anyopaque,
            _: *anyopaque,
            _: junc.litura.views.RefreshBudget,
        ) junc.litura.views.ViewState {
            const static: *junc.litura.views.StaticTokenProvider = @ptrCast(@alignCast(ptr));
            static.stale = false;
            return .{ .view = "tokens", .revision = null, .kind = .unavailable };
        }
    };
    table.stateForFn = Failing.state;
    table.refreshFn = Failing.refresh;
    try document.registerViewProvider(.{ .ptr = &provider, .vtable = &table });
    var cache = junc.Syntax.init(allocator, "sample.lua");
    defer cache.deinit();
    const range: junc.litura.types.Range = .{ .start = 0, .end = document.graphemeCount() };
    try cache.update(&document, range);
    _ = try cache.maintain(&document, .unlimited);
    try cache.update(&document, range);
    try std.testing.expectEqual(junc.Syntax.State.unavailable, cache.state);
    try std.testing.expectEqual(@as(usize, 1), cache.refresh_count);
    try std.testing.expectEqual(@as(usize, 0), cache.spans.len);
    try std.testing.expectEqual(@as(usize, 0), cache.query_count);
    try std.testing.expectError(error.ViewUnavailable, document.queryTokenSpans(0, 1, document.revision));
    var edit = try document.submit(.{ .id = .{ .value = 1 }, .origin = document.revision, .payload = .{ .buffer_mutation = .{
        .ops = &.{.{ .insert = .{ .pos = 0, .text = " " } }},
    } } });
    defer edit.deinit(allocator);
    try cache.update(&document, range);
    _ = try cache.maintain(&document, .unlimited);
    try cache.update(&document, range);
    try std.testing.expectEqual(@as(usize, 2), cache.refresh_count);
}

test "interaction and lifecycle blocks leave the current syntax tree fresh" {
    if (comptime !junc.litura.tree_sitter_enabled) return error.SkipZigTest;
    const fixture = try Fixture.create(allocator, "local value = 1", "navigation.lua");
    defer fixture.destroy();
    try update(fixture);
    const cache = &fixture.buffer().syntax;
    const refreshes = cache.refresh_count;
    try command(&fixture.editor, "shift-right", "");
    try update(fixture);
    var peer: junc.Registry.Attachment = .{ .allocator = allocator };
    _ = try peer.select(&fixture.host.registry, fixture.buffer().id);
    peer.deinit(&fixture.host.registry);
    try update(fixture);
    try std.testing.expectEqual(junc.Syntax.State.ready, cache.state);
    try std.testing.expectEqual(refreshes, cache.refresh_count);
    try std.testing.expectEqual(@as(u32, 0), fixture.document().revision);
}

test "queries stay stale until the host refreshes and a halted parse resumes through the cache" {
    if (comptime !junc.litura.tree_sitter_enabled) return error.SkipZigTest;
    const fixture = try Fixture.create(allocator, "local function f(a) return a * 2 end\n" ** 400, "budget.lua");
    defer fixture.destroy();
    const document = fixture.document();
    const cache = &fixture.buffer().syntax;
    try cache.attach(document);
    const before = try document.interactionRevision(fixture.session());
    try std.testing.expectError(error.ViewStale, document.queryTokenSpans(0, 10, document.revision));
    try std.testing.expectEqual(junc.litura.views.ViewStateKind.stale, document.queryViewState("tokens").kind);
    const Spent = struct {
        fn exhausted(_: ?*anyopaque) bool {
            return true;
        }
    };
    try std.testing.expectEqual(
        junc.litura.views.ViewStateKind.stale,
        document.refreshView("tokens", .{ .exhausted = Spent.exhausted }).kind,
    );
    try std.testing.expectError(error.ViewStale, document.queryTokenSpans(0, 10, document.revision));
    try update(fixture);
    try std.testing.expectEqual(junc.Syntax.State.ready, cache.state);
    try std.testing.expect(cache.spans.len > 0);
    try std.testing.expectEqual(@as(usize, 1), cache.refresh_count);
    try std.testing.expectEqual(@as(u32, 0), document.revision);
    try std.testing.expectEqual(before, try document.interactionRevision(fixture.session()));
}

test "syntax node references are revision values and splice points retain byte coordinates" {
    if (comptime !junc.litura.tree_sitter_enabled) return error.SkipZigTest;
    var document = try junc.litura.BufferEngine.initFromText(allocator, "  local value = '界é'\n", null);
    defer document.deinit();
    try std.testing.expect(try junc.litura.tree_sitter.TreeSitterTokenProvider.attachBuiltin(&document, "lua"));
    try std.testing.expectError(error.ViewStale, document.queryEnclosingSyntaxNode(8, document.revision));
    try std.testing.expectEqual(junc.litura.views.ViewStateKind.available, document.refreshView("syntax", .unlimited).kind);
    try std.testing.expect(try document.queryEnclosingSyntaxNode(0, document.revision) == null);
    const node = (try document.queryEnclosingSyntaxNode(8, document.revision)).?;
    const saved = node.ref;
    const resolved = try document.querySyntaxNodeInfo(saved);
    try std.testing.expectEqual(@as(u32, 8), resolved.start);
    try std.testing.expectEqual(@as(u32, 13), resolved.end);
    try std.testing.expectEqual(saved.id, resolved.ref.id);
    var result = try document.submit(.{
        .id = .{ .value = 77 },
        .origin = document.revision,
        .payload = .{ .buffer_mutation = .{ .ops = &.{.{ .insert = .{ .pos = 18, .text = "X\n" } }} } },
    });
    defer result.deinit(allocator);
    const splice = result.committed.transition.edit.?.splices[0];
    try std.testing.expectEqual(@as(u32, 20), splice.start_byte);
    try std.testing.expectEqual(@as(u32, 20), splice.start_point.column);
    try std.testing.expectEqual(@as(u32, 1), splice.new_end_point.row);
    try std.testing.expectEqual(@as(u32, 0), splice.new_end_point.column);
    try std.testing.expectError(error.InvalidArgument, document.querySyntaxNodeInfo(saved));
    try std.testing.expectError(error.ViewStale, document.queryTokenSpans(0, 10, document.revision));
    _ = document.refreshView("tokens", .unlimited);
    try std.testing.expectEqual(junc.litura.views.ViewStateKind.available, document.queryViewState("syntax").kind);
}

test "large views never parse in requests and scheduled completion invalidates cached observations" {
    if (comptime !junc.litura.tree_sitter_enabled) return error.SkipZigTest;
    const fixture = try Fixture.create(allocator, "local value = 1\n" ** 10000, "large.lua");
    defer fixture.destroy();
    const cache = &fixture.buffer().syntax;
    const document = fixture.document();
    try std.testing.expect(document.byteCount() > 128 * 1024);
    try fixture.connection.prepareView(0, 5);
    try std.testing.expectEqual(junc.Syntax.State.stale, fixture.connection.view().?.syntax_state);
    try std.testing.expectEqual(@as(usize, 0), fixture.connection.view().?.tokens.len);
    try std.testing.expectEqual(@as(usize, 0), cache.refresh_count);
    try std.testing.expect(!document.hasViewProvider("tokens"));
    const Spent = struct {
        fn exhausted(_: ?*anyopaque) bool {
            return true;
        }
    };
    try std.testing.expect(!try fixture.host.maintain(.{ .exhausted = Spent.exhausted }));
    try std.testing.expectEqual(@as(?u32, null), cache.failed_revision);
    try std.testing.expect(document.hasViewProvider("tokens"));
    try command(&fixture.editor, "text", "-- ");
    try fixture.connection.prepareView(0, 5);
    const stale = fixture.connection.view().?;
    try std.testing.expectEqual(@as(u32, 1), stale.revision);
    try std.testing.expectEqual(junc.Syntax.State.stale, stale.syntax_state);
    try std.testing.expectEqual(@as(usize, 0), stale.tokens.len);
    try std.testing.expectEqual(@as(usize, 1), cache.refresh_count);
    const interaction = try document.interactionRevision(fixture.session());
    try std.testing.expect(try fixture.host.maintain(.unlimited));
    try std.testing.expect(try fixture.connection.pollInvalidations());
    try fixture.connection.prepareView(0, 5);
    const ready = fixture.connection.view().?;
    try std.testing.expectEqual(junc.Syntax.State.ready, ready.syntax_state);
    try std.testing.expectEqual(@as(u32, 1), ready.revision);
    try std.testing.expectEqual(junc.syntax.Category.comment, ready.tokens[0].category);
    try std.testing.expectEqual(@as(u32, 1), document.revision);
    try std.testing.expectEqual(interaction, try document.interactionRevision(fixture.session()));
    try std.testing.expect(!try fixture.host.maintain(.unlimited));
    try command(&fixture.editor, "ctrl-z", "");
    try fixture.connection.prepareView(0, 5);
    try std.testing.expectEqual(junc.Syntax.State.stale, fixture.connection.view().?.syntax_state);
    try std.testing.expectEqual(@as(usize, 0), fixture.connection.view().?.tokens.len);
    try std.testing.expectEqual(@as(usize, 2), cache.refresh_count);
}
