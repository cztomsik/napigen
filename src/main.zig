const std = @import("std");
const napigen = @import("napigen.zig");

fn hello(name: []const u8) void {
    std.debug.print("Hello {s}\n", .{name});
}

fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn helloStruct(opts: struct { name: []const u8, num: u32, foo: ?u32 }) void {
    std.debug.print("{}\n", .{opts});
}

fn callMeBack(env: napigen.napi_env, cb: napigen.napi_value) void {
    const res = napigen.call(i32, env, cb, .{ 1, 2 }) catch |e| return napigen.throw(env, e);

    std.debug.print("1 + 2 = {d}\n", .{res});
}

export fn napi_register_module_v1(env: napigen.napi_env, _: napigen.napi_value) napigen.napi_value {
    const exports = .{
        .it_works = .{
            true,
            1,
            1.2,
            "hello",
            [_]u32{ 1, 2 },
            &[_]u32{ 1, 2 },
        },
        .hello = napigen.wrapFn(&hello),
        .add = napigen.wrapFn(&add),
        .helloStruct = napigen.wrapFn(&helloStruct),
        .callMeBack = napigen.wrapFn(&callMeBack),
    };

    return napigen.wrap(env, exports) catch @panic("err");
}
