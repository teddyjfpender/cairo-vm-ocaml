# 5. Builtins and hints

Cairo instructions only add, multiply and move felts. Two mechanisms extend the machine:
**builtins** give cheap access to fixed functions (hashes, range checks, bitwise operations),
and **hints** let the prover supply values that would be expensive to compute in Cairo.

## Builtins are memory

A builtin owns a segment and treats it as an array of fixed-size **instances**. A program
"calls" a builtin by writing inputs into the next instance and reading its outputs. There's no
special instruction.

| Builtin | Cells per instance | Layout |
| --- | ---: | --- |
| output | 1 | values the program publishes |
| range_check | 1 | a value, which must be below 2^128 |
| range_check96 | 1 | a value, which must be below 2^96 |
| pedersen | 3 | `x, y, hash(x, y)` |
| bitwise | 5 | `x, y, x & y, x ^ y, x \| y` |
| poseidon | 6 | three inputs, three permutation outputs |
| keccak | 16 | eight 200-bit inputs, eight outputs |
| ec_op | 7 | `p.x, p.y, q.x, q.y, m, r.x, r.y` with `r = p + m·q` |
| ecdsa | 2 | public key and message, checked against a registered signature |
| add_mod, mul_mod | 7 | descriptors of batched modular arithmetic |

Two rules connect builtins to the CPU:

- **Validation on write.** Writing into a range-check segment checks the bound immediately,
  and ecdsa cells check their signature.
- **Deduction on read.** When an instruction reads an empty output cell, `Deduce` computes it
  from the instance's inputs (for example `Felt.pedersen x y`) and caches it. That's the
  "ask the builtin first" step of [operand deduction](instructions.md#operand-deduction).

At the end of a run the runner checks each builtin's stop pointer: the program must return a
pointer to exactly the end of the instances it used. It also re-verifies any outputs the program
wrote itself.

## Hints are untrusted Python

A compiled program attaches hint code to some `pc`s. The code is Python strings from
cairo-lang, for example:

```python
memory[ap] = segments.add()
```

Neither this VM nor the Rust one runs Python. Each matches the **exact code string** against a
table of known hints and runs a native implementation instead. Here the table is
`src/hints/hint_codes.ml`, generated from Rust's source, with implementations in `src/hints/`.

A hint's job is to put values into memory: a quotient, a square root, a dictionary entry. It is
not trusted. Anything it writes goes through ordinary write-once memory, and the Cairo code that
follows must check it (range checks, `assert`s). A wrong hint can make a run fail, but it can't
make a false statement provable.

## `ids`: reaching Cairo variables from a hint

Inside a hint, `ids.x` refers to the Cairo variable `x`. The compiler records each variable as a
**reference expression** such as `[cast(fp + (-3), felt*)]`. When a hint is compiled, `Hintrt`
parses and pre-binds these expressions into closures, so a hint call never re-parses them.

References relative to `ap` need **ap tracking**. The compiler records how far `ap` had moved
(within a tracking group) when the reference was made and when the hint runs. The difference is
subtracted:

```
ap_used = ap_now - (hint_offset - reference_offset)
```

## Scopes

Hints share state across calls through **execution scopes**, a stack of name-to-value tables.
`vm_enter_scope` pushes a table and `vm_exit_scope` pops one. Dictionaries, `squash_dict`
progress and secp intermediate values (`value`, `x`, `slope`) all live there. A run must exit
every scope it enters.

## Exercises

1. A pedersen segment has base offset 0, and a program reads cell 5. What is deduced, and from
   which cells?
2. Which bitwise-instance cell holds `x ^ y` for the instance starting at offset 10?
3. A reference `[ap - 1]` was recorded with ap-tracking offset 3. The hint runs at offset 5 in
   the same group. Which address does `ids.x` read?
4. A malicious prover replaces the `unsigned_div_rem` hint with one that returns a wrong
   quotient. What happens?
5. Why match hints by exact string rather than parsing the Python?

<details markdown>
<summary>Solutions</summary>

1. Cell 5 is index 2 of the instance starting at 3 (`5 mod 3 = 2`), so it's the output. It is
   deduced as `pedersen(cell 3, cell 4)`. If either input is missing, nothing is deduced.
2. Instance cells are `x, y, and, xor, or` at offsets 10 to 14, so `x ^ y` is at offset 13.
3. `ap_used = ap - (5 - 3) = ap - 2`, so the address is `ap - 2 - 1 = ap - 3`.
4. The Cairo code after the hint checks `q * div + r = value` with range checks on `q` and `r`.
   A wrong quotient makes that assertion fail and the run aborts. Soundness doesn't depend on
   hints.
5. Matching is how cairo-vm defines which hints exist. Behaving like Rust requires accepting
   exactly the same strings, byte for byte. Interpreting arbitrary Python would also make every
   hint a source of nondeterminism and slowness.

</details>
