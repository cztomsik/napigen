const std = @import("std");
const napigen = @import("napigen.zig");

fn hello(name: []const u8) void {
    std.debug.print("Hello {s}\n", .{name});
}

fn add(a: i32, b: i32) i32 {
    return a + b;
}

export fn napi_register_module_v1(env: napigen.napi_env, _: napigen.napi_value) napigen.napi_value {
    return napigen.wrap(env, .{
        .it_works = true,
        .hello = napigen.wrapFn(&hello),
        .add = napigen.wrapFn(&add),
    });
}
