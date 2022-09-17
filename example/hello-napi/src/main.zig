const std = @import("std");
const assert = std.debug.assert;
const c = @import("napi.zig");
const translate = @import("napigen.zig");

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) c.napi_value {
    translate.register_function(env, exports, "greet", greet) catch return null;
    return exports;
}

fn greet(env: c.napi_env, _: c.napi_callback_info) callconv(.C) c.napi_value {
    return translate.create_string(env, "world") catch return null;
}
