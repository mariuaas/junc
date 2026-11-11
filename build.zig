const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tree_sitter = b.option(bool, "tree-sitter", "Enable Litura syntax highlighting") orelse true;
    const litura = b.dependency("litura", .{
        .target = target,
        .optimize = optimize,
        .@"tree-sitter" = tree_sitter,
    });
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const lua = b.dependency("luajit", .{});
    const make = b.addSystemCommand(&.{ "sh", "-c", "set -eu; cp -R \"$1\"/. \"$2\"; cd \"$2\"; make -j2 BUILDMODE=static MACOSX_DEPLOYMENT_TARGET=11.0 XCFLAGS=-DLUAJIT_NO_UNWIND >build.log 2>&1 || { cat build.log >&2; exit 1; }", "build-luajit" });
    make.addDirectoryArg(lua.path(""));
    const output = make.addOutputDirectoryArg("luajit");
    // lua.h alone excludes auxiliary state/loading helpers.
    const headers = b.addWriteFiles();
    const header = headers.add("junc_lua.h", "#include <lua.h>\n#include <lauxlib.h>\n#include <lualib.h>\n");
    const c = b.addTranslateC(.{ .root_source_file = header, .target = target, .optimize = optimize });
    c.addIncludePath(lua.path("src"));
    const options = b.addOptions();
    const syntax_max_bytes = b.option(usize, "syntax-max-bytes", "Maximum bytes for synchronous highlighting; 0 removes the limit") orelse 128 * 1024;
    options.addOption(usize, "syntax_max_bytes", syntax_max_bytes);
    const module = b.addModule("junc", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    module.addOptions("build_options", options);
    module.addImport("litura", litura.module("litura"));
    module.addImport("lua", c.createModule());
    module.addObjectFile(output.path(b, "src/libluajit.a"));
    const surface = b.createModule(.{
        .root_source_file = b.path("src/Surface.zig"),
        .target = target,
        .optimize = optimize,
    });
    surface.addImport("junc", module);
    surface.addImport("vaxis", vaxis.module("vaxis"));
    const exe = b.addExecutable(.{ .name = "junc", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }) });
    exe.root_module.addImport("surface", surface);
    exe.root_module.addImport("junc", module);
    exe.root_module.addImport("vaxis", vaxis.module("vaxis"));
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the editor").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/root.zig"), .target = target, .optimize = optimize }) });
    tests.root_module.addImport("surface", surface);
    tests.root_module.addImport("vaxis", vaxis.module("vaxis"));
    tests.root_module.addImport("junc", module);
    b.step("test", "Run bridge and editing tests").dependOn(&b.addRunArtifact(tests).step);
    const benchmark = b.addExecutable(.{
        .name = "syntax-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/syntax_benchmark.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    benchmark.root_module.addImport("litura", litura.module("litura"));
    b.step("bench-syntax", "Measure Litura full refresh and cached visible queries")
        .dependOn(&b.addRunArtifact(benchmark).step);
    const check = b.step("check", "Compile editor and tests");
    check.dependOn(&exe.step);
    check.dependOn(&tests.step);
}
