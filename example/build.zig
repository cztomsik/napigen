const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addSharedLibrary(.{
        .name = "example",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Use weak-linkage
    lib.linker_allow_shlib_undefined = true;

    // Add napigen
    const napigen = b.dependency("napigen", .{});
    lib.root_module.addImport("napigen", napigen.module("napigen"));

    // Build the lib
    b.installArtifact(lib);

    // Copy the result to a *.node file so we can require() it
    const copy_node_step = b.addInstallLibFile(lib.getEmittedBin(), "example.node");
    b.getInstallStep().dependOn(&copy_node_step.step);
}
