const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const lib = b.addSharedLibrary("example", "src/main.zig", .unversioned);
    lib.setBuildMode(mode);

    // weak-linkage
    lib.linker_allow_shlib_undefined = true;

    // add correct path to this lib
    lib.addPackagePath("napigen", "../napigen.zig");

    // build the lib
    lib.install();

    // copy the result to a *.node file so we can require() it
    b.installLibFile(b.pathJoin(&.{ "zig-out/lib", lib.out_lib_filename }), "example.node");
}
