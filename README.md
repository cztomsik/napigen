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
it will be unwrapped back. It's a bit like if pointers were some kind of opaque objects in JS.

You will get the same JS object for the same pointer, unless it has been already collected.
This is useful if you need to attach some state to the JS counterpart and then access that data
later. Conceptually, it's like if you could attach JS data to a native object.

Changes to JS objects are not reflected into the native part but you can provide
getters/setters in JS and call some native functions yourself.

## Functions
You can create JS function with `ctx.createFunction(&zig_fn)` and then you can export them
just like any other value. Only comptime-known fns are supported.
If you return an error from a function call, an exception will be thrown in JS.

```zig
fn add(a: i32, b: i32) i32 {
    return a + b;
}

// somewhere where the JsContext is available
const js_fun: napigen.napi_value = try js.createFunction(&add);

// and then you probably want to make it acessible to JS somehow
try js.setNamedProperty("add", js_fun);
```

## defineModule(&init), exports
N-API modules need to export a function which will also init & return the `exports` object.
You could export `napi_register_module_v1` and call `JsContext.init()` yourself but there's
also a shorthand using `comptime` block which will allow you to use `try` anywhere inside:

```zig
comptime { napigen.defineModule(&initModule) }

fn initModule(js: *napigen.JsContext, exports: napigen.napi_value) !napigen.napi_value {
    try js.setNamedProperty(exports, ...);
    ...

    return exports;
}
```

---

## Complete example

First, you need to create a new library:

```bash
mkdir example
cd example
zig init-lib
```

Then change your `build.zig` to something like this:

```zig
...

const lib = b.addSharedLibrary("example", "src/main.zig", .unversioned);
lib.setBuildMode(mode);

// weak-linkage
lib.linker_allow_shlib_undefined = true;

// add correct path to this lib
lib.addPackagePath("napigen", "libs/napigen/napigen.zig");

// build the lib
lib.install();

// copy the result to a *.node file so we can require() it
b.installLibFile(b.pathJoin(&.{ "zig-out/lib", lib.out_lib_filename }), "example.node");

...
```

Then we can define some functions and the napi module itself in `src/main.zig`

```zig
const std = @import("std");
const napigen = @import("napigen");

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

comptime {
    napigen.defineModule(&initModule);
}

fn initModule(js: *napigen.JsContext, exports: napigen.napi_value) !napigen.napi_value {
    try js.setNamedProperty(exports, "add", try js.createFunction(&add));

    return exports;
}
```

And then you can use it from JS as expected:

```javascript
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const native = require('./zig-out/lib/example.node')

console.log('1 + 2 =', native.add(1, 2));
```

To build the lib and run the script:
```
> zig build && node example.js
1 + 2 = 3
```

## License
MIT
