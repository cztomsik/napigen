# zig-napigen
Comptime N-API bindings for Zig.

## Features
- primitives, tuples, structs (value types), optionals
- strings (valid for the function scope)
- struct ptrs (see below)
- functions (no classes, see below)
- \+ whole N-API, so you can do pretty much anything

## Limited scope
The API is intentionally simple/thin and only basic types are supported. The reason is
that it's often hard to guess how a certain thing should be mapped and it's much better if
there's an easy way to hook into the mapping process and/or use the N-API directly.

Specifically, there is no support for classes but it's possible to provide a JS constructor
which will be called when a struct pointer is to be returned (see below).

## Structs/tuples (value types)
If you return a struct by value, it will be mapped to an anonymous object/array
with all of the properties/elements mapped recursively. Similarly, if you accept a struct/tuple
by value, it will be mapped back from JS to a respective native type.

In both cases, you always get a copy, no changes are reflected to the other side.

## Struct pointers (*T)
On the other hand, if you return a pointer, you will only get an empty object with that pointer
being wrapped inside. Then, if you pass this JS object to a function which accepts a pointer,
it will be unwrapped back. It's a bit like if pointers were some kind of opaque object by default.

You will get the same JS object for the same pointer, unless it has been already collected so whatever
you store in it, will stay there and you can access it later.


Pointers are, of course, totally unsafe and you should be careful.

## Functions
You can create JS function with `ctx.createFunction(&zig_fn)` and then you can export them
just like any other value.

If you return an error from a function call, an exception will be thrown in JS.

---

## Example usage

First, you need to create a new library:

```bash
mkdir hello-napi
cd hello-napi
zig init-lib
```

Then change your `build.zig` to something like this:

```zig
...
const lib = b.addSharedLibrary("hello-napi", "src/main.zig", .unversioned);

// weak-linkage
lib.linker_allow_shlib_undefined = true;

// add correct path to this lib
lib.addPackagePath("napigen", "libs/napigen/napigen.zig");

// copy to a *.node file so we can require() it
b.installLibFile(b.pathJoin(&.{ "zig-out/lib", lib.out_lib_filename }), "hello-napi.node");

lib.setBuildMode(mode);
lib.install();
...
```

Then we can define some functions and the napi module itself in `src/main.zig`

```zig
const std = @import("std");
const napigen = @import("napigen.zig");

fn hello(name: []const u8) void {
    std.debug.print("Hello {s}\n", .{name});
}

fn add(a: i32, b: i32) i32 {
    return a + b;
}

export fn napi_register_module_v1(env: napigen.napi_env, _: napigen.napi_value) napigen.napi_value {
    var cx = napigen.Context{ .env = env };

    const exports = .{
        // export any value
        .it_works = true,

        // or fn ptr(s)
        .hello = &hello,
        .add = &add,
    };

    // recursively map value(s) and return the resulting napi_value which will be then used for module.exports
    return napigen.write(exports) catch |e| return cx.throw(e);
}
```

In your `hello.js`, you can use it as expected:

```javascript
const lib = require('./zig-out/lib/hello-napi.node')

// prints true
console.log(lib.it_works)

// prints "Hello world" fom zig
lib.hello("world")

// prints 3
console.log(lib.add(1, 2))
```

To build the lib and run the script:
```bash
zig build
node hello.js
```

## License
MIT
