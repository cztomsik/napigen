const std = @import("std");
const napigen = @import("napigen");

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

const Person = struct {
    name: []const u8,
    age: ?u32,
};

fn incrementAge(person: Person) Person {
    return .{
        .name = person.name,
        .age = if (person.age) |age| age + 1 else null,
    };
}

fn updatePersonWrapper(js: *napigen.JsContext, person: napigen.napi_value) !napigen.napi_value {
    // Read Person from JS object
    const p = try js.readObject(Person, person);

    // Apply our function
    const result = incrementAge(p);

    // Write result back to JS
    return js.createObjectFrom(result);
}

comptime {
    napigen.defineModule(initModule);
}

fn initModule(js: *napigen.JsContext, exports: napigen.napi_value) !napigen.napi_value {
    try js.setNamedProperty(exports, "add", try js.createFunction(add));
    try js.setNamedProperty(exports, "updatePerson", try js.createFunction(updatePersonWrapper));

    return exports;
}
