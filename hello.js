const lib = require('./hello-napi.node')

// prints true
console.log(lib)

// prints "Hello world" fom zig
lib.hello("world")

// prints 3
console.log(lib.add(1, 2))

console.log(lib.helloStruct({ name: 'bar', num: 12, foo: null }))

console.log(lib.callMeBack((a, b) => a + b))
