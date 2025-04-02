const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addModule("napigen", .{
        .root_source_file = b.path("src/napigen.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.link_libc = true;

    const node_api = b.dependency("node_api", .{});
    lib.addIncludePath(node_api.path("include"));

    if (target.result.os.tag == .windows) {
        var node_api_lib = b.addSystemCommand(&.{ b.graph.zig_exe, "dlltool", "-m", "x86-64", "-D", "node.exe", "-l", "node.lib", "-d" });
        node_api_lib.addFileArg(node_api.path("def/node_api.def"));
        node_api_lib.cwd = b.path(".");
        b.default_step.dependOn(&node_api_lib.step);
        lib.linkSystemLibrary("node", .{});
    }
}
