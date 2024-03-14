const std = @import("std");
const napigen = @import("napigen");

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

comptime {
    napigen.defineModule(initModule);
}

fn initModule(js: *napigen.JsContext, exports: napigen.napi_value) anyerror!napigen.napi_value {
    try js.setNamedProperty(exports, "add", try js.createFunction(add));

    return exports;
}
