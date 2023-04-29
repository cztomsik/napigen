const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addSharedLibrary(.{
        .name = "example",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // weak-linkage
    lib.linker_allow_shlib_undefined = true;

    // add correct path to this lib
    const napigen = b.createModule(.{ .source_file = .{ .path = "../napigen.zig" } });
    lib.addModule("napigen", napigen);

    // build the lib
    b.installArtifact(lib);

    // copy the result to a *.node file so we can require() it
    const copy_node_step = b.addInstallLibFile(lib.getOutputSource(), "example.node");
    b.getInstallStep().dependOn(&copy_node_step.step);
}
