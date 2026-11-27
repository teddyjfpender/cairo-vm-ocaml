# 3. Memory and segments

## Segments

Cairo memory is not one flat array. It is a set of **segments**, each a growable array that
starts at offset 0:

| Segment | Holds |
| --- | --- |
| 0 | the program's bytecode |
| 1 | the execution stack: `ap` and `fp` point here |
| 2, 3, ... | one per builtin (output, range_check, pedersen, ...) |
| later | segments created at run time, e.g. by `alloc()` or dictionaries |

A pointer is a **relocatable** `segment:offset`. Pointer arithmetic changes only the offset, and
subtracting two pointers into the same segment gives a felt. Segments let a program allocate new
arrays without knowing in advance where they will end up.

## Where memory lives

Each segment is a `Segment.seg`: a Bigarray of OCaml ints allocated with `calloc`. Three
properties make it fast:

- **The GC never scans it.** Bigarray data lives outside the OCaml heap, and every cell is an
  immediate word, so nothing inside needs tracing.
- **No write barrier.** Storing into a Bigarray doesn't involve the GC.
- **Unused capacity is free.** The execution segment reserves room for 2^27 cells up front. The
  OS hands out zeroed pages lazily, and zero is the empty-cell word, so a fresh segment is
  already "all empty" without touching memory.

`Segment.sget`/`sset` read and write typed `Felt.t` values. The trace reuses the same storage for
packed register words through `raw_get`/`raw_set`.

## Writing

`Vm.write vm seg off v` implements write-once memory:

1. Grow the segment if `off` is past its capacity.
2. If the cell is empty, store `v`, update the segment's high-water mark (used size), and run
   the segment's validation rule (range-check segments reject values of 2^128 or more, for
   example).
3. If the cell is set, compare. Equal is fine; different raises
   `Inconsistent memory assignment`.

## Temporary segments and relocation rules

Some hints build data before they know where it belongs. They allocate a **temporary segment**
(negative index, `-1, -2, ...`) and later add a **relocation rule** mapping it into a real
segment. While rules exist, reads translate temporary pointers on the fly. At the end of the run,
`Vm.relocate_temp_memory` rewrites every temporary pointer and copies the temporary cells into
place, with the usual write-once checks.

## Relocation at the end of a run

The prover wants one flat address space. After the run, every segment gets a base address:

```
base(0) = 1
base(s + 1) = base(s) + size(s)
```

so `seg:off` becomes `base(seg) + off`. Relocation never changes felt values, only pointers.

## Exercises

1. A run ends with segment sizes `[5, 10, 0, 3]`. Write out the relocation table, then relocate
   `3:2` and `1:4`.
2. Why does the relocation table start at 1 instead of 0?
3. A program writes `7` to `1:20` and later `7` to `1:20` again. Does it fail? And if the second
   write is `8`?
4. Why can a fresh 2^27-cell execution segment cost no time and no memory?

<details markdown>
<summary>Solutions</summary>

1. The bases are `[1, 6, 16, 16, 19]`. Segment 2 is empty, so segments 2 and 3 share base 16.
   `3:2` becomes `16 + 2 = 18`, and `1:4` becomes `6 + 4 = 10`.
2. It's the convention of cairo-lang and the Rust VM, and the output files must match theirs
   byte for byte, so this VM follows it.
3. Writing the same value is an equality check and passes. Writing `8` fails with
   `Inconsistent memory assignment at address 1:20. 7 != 8`.
4. `calloc` of a large block maps zero pages lazily: memory is only committed when first
   touched. Because the empty-cell word is 0, untouched cells already read as empty.

</details>
