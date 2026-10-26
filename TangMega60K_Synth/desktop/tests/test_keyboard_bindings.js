"use strict";
const assert = require("node:assert/strict");
const B = require("../web/keyboard-bindings.js");
const model = new B.KeyboardBindings();
assert.equal(model.index("KeyZ"), 0);
assert.equal(model.index("KeyI"), 24);
assert.equal(model.isDefault(), true);
const changed = B.assign(model.snapshot(), 0, "KeyA");
assert.equal(model.index("KeyA"), -1, "draft must not alter live playing");
model.apply(changed);
assert.equal(model.index("KeyA"), 0);
assert.equal(model.index("KeyZ"), -1);
assert.equal(model.isDefault(), false);
assert.throws(() => B.assign(changed, 1, "KeyA"), /已分配/);
for (const code of [
    "Escape",
    "Space",
    "Enter",
    "ControlLeft",
    "F1",
    "",
    undefined,
    {},
    "KeyAB",
])
    assert.throws(() => B.assign(changed, 0, code));
assert.throws(() => B.validate(new Array(25)), /不支持/);
assert.throws(() => B.validate(new Array(24).fill(null)), /25/);
assert.throws(() => B.assign(changed, -1, "KeyA"));
assert.equal(B.assign(changed, 0, null)[0], null);
for (const code of ["Digit0", "Numpad0", "Slash", "Backquote", "NumpadAdd"])
    assert.equal(B.assign(changed, 0, code)[0], code);
const copy = model.snapshot();
copy[0] = null;
assert.equal(model.index("KeyA"), 0, "caller cannot mutate saved model");
model.apply(B.defaults);
assert.equal(model.isDefault(), true);
console.log(
    "KEYBOARD BINDINGS PASS defaults, drafts, unique keys, reserved keys, clearing, labels and immutable snapshots",
);
