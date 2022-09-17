# zig-napigen

Automatic N-API bindings for any Zig project.

**Disclaimer:** I did this as a PoC when I was in hospital/recovering
and it's still a **work-in-progress**, but I think it might be already useful
for somebody.

## Features
- [x] primitives (`void`, `bool`, `u32`, `i32`, `i64`, `f64`)
- [x] functions
- [x] strings (TODO: works but it leaks memory ATM)
- [ ] callbacks to JS (TODO)
- [ ] classes (TODO)
- [ ] struct ptrs (TODO)
- [ ] hooks for customization (TODO)

## Usage

First, you need to create a new library:

```
mkdir hello-napi
cd hello-napi
zig init-lib
```

Then change your `build.zig` to something like this in `hello-napi` directory:

```
...
const lib = b.addSharedLibrary("hello-napi", "src/main.zig", .unversioned);

// add weak-linkage for macos
lib.linker_allow_shlib_undefined = true;

// add correct path to this lib
lib.addPackage(.{ .name = "napigen", .path = "libs/napigen/napigen.zig" });

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
    return napigen.wrap(env, .{
        .it_works = true,
        .hello = napigen.wrapFn(&hello),
        .add = napigen.wrapFn(&add),
    });
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
