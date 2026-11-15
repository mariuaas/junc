//! Native host, terminal frontend and pinned dependency build steps.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tree_sitter = b.option(bool, "tree-sitter", "Enable Litura syntax highlighting") orelse true;
    // Litura owns documents and optional syntax providers; vaxis stays at the terminal boundary.
    const litura = b.dependency("litura", .{
        .target = target,
        .optimize = optimize,
        .@"tree-sitter" = tree_sitter,
    });
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const lua = b.dependency("luajit", .{});
    // LuaJIT has a native make build; its static archive stays in the Zig build cache.
    const make = b.addSystemCommand(&.{
        "sh",
        "-c",
        "set -eu; cp -R \"$1\"/. \"$2\"; cd \"$2\"; " ++
            "make -j2 BUILDMODE=static MACOSX_DEPLOYMENT_TARGET=11.0 " ++
            "XCFLAGS=-DLUAJIT_NO_UNWIND >build.log 2>&1 || { cat build.log >&2; exit 1; }",
        "build-luajit",
    });
    make.addDirectoryArg(lua.path(""));
    const output = make.addOutputDirectoryArg("luajit");
    // lua.h alone excludes auxiliary state/loading helpers.
    const headers = b.addWriteFiles();
    const header = headers.add("junc_lua.h", "#include <lua.h>\n#include <lauxlib.h>\n#include <lualib.h>\n");
    const c = b.addTranslateC(.{
        .root_source_file = header,
        .target = target,
        .optimize = optimize,
    });
    c.addIncludePath(lua.path("src"));
    const host_header = headers.add("junc_host.h", "#define _GNU_SOURCE 1\n" ++
        "#include <sys/types.h>\n#include <sys/socket.h>\n#include <sys/un.h>\n" ++
        "#include <sys/stat.h>\n#include <sys/file.h>\n#include <poll.h>\n" ++
        "#include <sys/wait.h>\n#include <unistd.h>\n#include <fcntl.h>\n" ++
        "#include <signal.h>\n#include <errno.h>\n#include <stdlib.h>\n#include <time.h>\n");
    const host = b.addTranslateC(.{
        .root_source_file = host_header,
        .target = target,
        .optimize = optimize,
    });
    const module = b.addModule("junc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("litura", litura.module("litura"));
    module.addImport("lua", c.createModule());
    module.addImport("host_c", host.createModule());
    module.addObjectFile(output.path(b, "src/libluajit.a"));
    const surface = b.createModule(.{
        .root_source_file = b.path("src/Surface.zig"),
        .target = target,
        .optimize = optimize,
    });
    surface.addImport("junc", module);
    surface.addImport("vaxis", vaxis.module("vaxis"));
    const terminal_input = b.createModule(.{
        .root_source_file = b.path("src/TerminalInput.zig"),
        .target = target,
        .optimize = optimize,
    });
    terminal_input.addImport("vaxis", vaxis.module("vaxis"));
    const exe = b.addExecutable(.{
        .name = "junc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("surface", surface);
    exe.root_module.addImport("terminal_input", terminal_input);
    exe.root_module.addImport("junc", module);
    exe.root_module.addImport("vaxis", vaxis.module("vaxis"));
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the editor").dependOn(&run.step);
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("surface", surface);
    tests.root_module.addImport("terminal_input", terminal_input);
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
