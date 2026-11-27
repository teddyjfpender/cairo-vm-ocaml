# 2. Values and the `Felt.t` type

A memory cell holds either a felt or a **relocatable**: a pointer written as `segment:offset`
(see [chapter 3](memory.md)). Most felts in real programs are small: loop counters, offsets,
booleans, small constants. Big ones appear in hashes and cryptography. The representation is
chosen around that skew.

## One OCaml int per value

Every value, including the "empty cell" marker, is a single 63-bit OCaml `int`. The two low bits
are a tag:

| Tag | Meaning | Encoding |
| --- | --- | --- |
| `00` | empty cell | the integer `0` |
| `01` | small felt `v`, with `-2^59 < v < 2^59` | `(v lsl 2) lor 1` |
| `10` | relocatable `seg:off` | `(seg lsl 42) lor (off lsl 2) lor 2` |
| `11` | big felt | `(i lsl 2) lor 3`, where `i` indexes a pool of 4×64-bit limbs |

Some consequences:

- **No allocation for common values.** Small felts and pointers are immediates, so the GC never
  sees them, and arrays of them are plain machine words.
- **Negative numbers are small.** A felt like `p - 1` is stored as the small value `-1`, which
  keeps "subtract one" cheap.
- **Equality is mostly `==` on ints.** Big felts are stored canonically and never overlap with
  small ones, so two values are equal when their words are equal. The only exception is two big
  felts with different pool indexes, which compare limbs.
- **Fast arithmetic.** Adding two small felts is an integer add plus a range check. Only
  overflow, or a big operand, calls into the C field kernel.

## Why the type is private

In `src/core/felt.mli` the type is declared as

```ocaml
type t = private int
```

Outside `Felt`, you can read a `Felt.t` as an int (`(v :> int)`), but you can't build one from an
int. That rules out a whole class of bugs at no runtime cost:

```ocaml
let is_empty v = v = 0            (* type error: v is Felt.t, 0 is int *)
let is_empty v = v = Felt.empty   (* fine *)
```

Offsets, counts and segment numbers stay plain `int`s, so the compiler keeps them apart from
values. When the types were introduced they exposed a real bug: one helper popped from either
a list of values or a list of indices and returned the same untyped int for both.

The few places that must cross the boundary, such as words read from raw memory or results from
C, use `Felt.unsafe_of_int` (in) and `(v :> int)` (out). Both are visible in the source.

## The pool

Big felts live in one fixed reservation of lazily committed memory (`Felt.capacity` slots), 32
bytes per slot, as four little-endian 64-bit limbs. It never moves or grows, so allocating a
slot never copies the pool; running out raises `Out_of_memory`. C kernels (Pedersen, Poseidon,
field multiplication) read their inputs from slots and write their results to fresh ones. The
field arithmetic they share with the native CPU kernel is in `src/native/field.h`. `Felt.of_z` and `Felt.to_z` convert to and from Zarith integers for
hint code, which needs arbitrary-precision arithmetic.

## Exercises

1. Encode the small felt `5`, the small felt `-3` and the relocatable `1:7`.
2. Decode the word `4398046511134`.
3. Why is the small-felt bound `2^59` and not `2^61`, given that 61 bits remain after the tag?
4. Write `is_reloc : Felt.t -> bool` without using any `Felt` function.
5. Is `576460752303423487` (`2^59 - 1`) stored small or big? What about `2^59`?

<details markdown>
<summary>Solutions</summary>

1. `5` becomes `(5 lsl 2) lor 1 = 21`; `-3` becomes `(-3 lsl 2) lor 1 = -11`; `1:7` becomes
   `(1 lsl 42) lor (7 lsl 2) lor 2 = 4398046511134`.
2. The tag is `10`, so it's a relocatable: segment `4398046511134 asr 42 = 1` and offset
   `(4398046511134 lsr 2) land (2^40 - 1) = 7`. That's `1:7`, as in exercise 1.
3. Headroom. The sum of two small felts is below `2^60` in absolute value, so it can be computed
   with a plain machine add and checked against the bound afterwards, without overflowing the
   payload bits.
4. `let is_reloc (v : Felt.t) = (v :> int) land 3 = 2`. You can read a private type, just not
   build one.
5. `2^59 - 1` is small (the bound is strict). `2^59` is big and goes to the pool.

</details>
