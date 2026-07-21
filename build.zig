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
}

pub fn setup(lib: *std.Build.Step.Compile) void {
    const b = lib.step.owner;
    const napigen = b.dependencyFromBuildZig(@This(), .{});
    const node_api = napigen.builder.dependency("node_api", .{});

    lib.root_module.addImport("napigen", napigen.module("napigen"));

    if (lib.root_module.resolved_target.?.result.os.tag == .windows) {
        const node_lib = b.addSystemCommand(&.{ b.graph.zig_exe, "dlltool", "-m", "i386:x86-64", "-D", "node.exe", "-l" });
        const node_lib_path = node_lib.addOutputFileArg("node.lib");
        node_lib.addArg("-d");
        node_lib.addFileArg(node_api.path("def/node_api.def"));
        lib.step.dependOn(&node_lib.step);

        lib.root_module.addLibraryPath(node_lib_path.dirname());
        lib.root_module.linkSystemLibrary("node", .{});
    } else {
        // Use weak-linkage
        lib.linker_allow_shlib_undefined = true;
    }
}
