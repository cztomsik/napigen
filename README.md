# zig-napigen
Automatic N-API bindings for your Zig project.

**Disclaimer:** I did this as a PoC when I was in hospital/recovering
and it's still a **work-in-progress**, but I think it might be already useful
for somebody.

## Features
- [x] primitives (`void`, `bool`, `u8/u16/u32`, `i8/i16/i32`, `i64`, `f16/f32/f64`)
- [x] strings (valid for the function scope)
- [x] tuples, structs (value types), optionals
- [x] struct ptrs, function ptrs (see below)
- [ ] easy to customize

## Limited scope
The API is intentionally both simple & thin and only the basic types are supported. The reason is
that it's often hard to guess how a certain thing should be mapped and it's much better if
there's an easy way to override these default mappings or even use napi directly.

Classes are also left out, at least for now.

## Struct pointers (*T)
You can both accept and return pointers to struct types (or return structs with pointers) and
you will always get the same JS object unless it has been already collected. Note that we don't
call `deinit()` automatically and it is your responsibility to do this using `FinalizationRegistry`.

Pointers are, of course, totally unsafe and you should be careful.

## Function pointers (*const F)
You can simply return &fun pointers from anywhere (including exports)
and the JS function will again be the same, unless it has been already collected.

If you return an error from a function call, an exception will be thrown in JS.

## Usage

First, you need to create a new library:

```
mkdir hello-napi
cd hello-napi
zig init-lib
```

Then change your `build.zig` to something like this:

```
...
const lib = b.addSharedLibrary("hello-napi", "src/main.zig", .unversioned);

// weak-linkage
lib.linker_allow_shlib_undefined = true;

// add correct path to this lib
lib.addPackagePath("napigen", "libs/napigen/napigen.zig");

lib.setBuildMode(mode);
lib.install();
...
```

Then we can define some functions and the napi module itself in `src/main.zig`

```
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

Then we need to build the lib (and copy the result as `.node` file):

```
zig build
mv ./zig-out/lib/*hello-napi.* ./hello-napi.node
node hello.js
```

and then finally, in your `hello.js`, you can use it as expected:

```
const lib = require('./hello-napi.node')

// prints true
console.log(lib.it_works)

// prints "Hello world" fom zig
lib.hello("world")

// prints 3
console.log(lib.add(1, 2))
```

## License
MIT
