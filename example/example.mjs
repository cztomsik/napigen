// run with:
// zig build && node example.mjs

import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const native = require('./zig-out/lib/example.node')

console.log('1 + 2 =', native.add(1, 2))

// Test our struct-based function
const person = {
    name: 'John Doe',
}

console.log('Original person:', person)
const updatedPerson = native.updatePerson(person)
console.log('Updated person:', updatedPerson)
