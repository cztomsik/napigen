const lib = require('./hello-napi.node');

// prints true
console.log(lib.it_works)

// prints "Hello world" fom zig
lib.hello("world")

// prints 3
console.log(lib.add(1, 2))
