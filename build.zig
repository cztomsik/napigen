const std = @import("std");

pub fn build(b: *std.Build) !void {
    const lib = b.addModule("napigen", .{
        .root_source_file = b.path("src/napigen.zig"),
    });
    lib.link_libc = true;
}
