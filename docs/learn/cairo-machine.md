# 1. The Cairo machine

Cairo is a CPU designed to be proven: every run produces a trace that a STARK prover can turn
into a short proof that the run happened. That goal shapes the machine. Its design choices make
the run easy to describe as polynomial constraints, even where they would be unusual on an
ordinary CPU.

## Field elements

Cairo's only data type is the **field element** (felt): an integer modulo the prime

```
p = 2^251 + 17·2^192 + 1
```

Addition and multiplication wrap modulo `p`, and every nonzero felt has an inverse, so division
is always defined except by zero. There is no separate integer type. Programs that need "real"
integers range-check felts to keep them small.

## Memory is write-once

Memory maps addresses to felts, and **each cell can be written only once**. An instruction that
looks like an assignment, such as

```
[ap] = [ap - 1] + 5
```

is really an **assertion**: "the cell at `ap` equals the cell at `ap - 1` plus 5". If the cell at
`ap` is still empty, the VM fills it in so the assertion holds. This is **deduction**. If the cell
already holds a different value, the run fails. Write-once memory is what lets a prover check
memory with a single permutation argument.

## Three registers

| Register | Meaning |
| --- | --- |
| `pc` | program counter: address of the current instruction |
| `ap` | allocation pointer: next free cell; most instructions write at `ap` and bump it |
| `fp` | frame pointer: base of the current function's frame; arguments sit below it |

A function call pushes the caller's `fp` and the return address at `ap`, then sets `fp` to the
new top. `ret` restores both. Locals and arguments are addressed relative to `fp`; temporaries
relative to `ap`.

## One step

Every step executes the instruction at `pc`:

1. **Fetch and decode** the instruction word at `pc`.
2. **Compute three addresses**: `dst`, `op0` and `op1`, each a register plus a 16-bit signed
   offset (`op1` may instead be an immediate or `[op0 + off]`).
3. **Compute `res`** from the operands: `op1`, `op0 + op1` or `op0 * op1`.
4. **Deduce** any missing operand so the instruction's equation holds, and write it.
5. **Check** the opcode's condition (`assert_eq` requires `res = dst`, for example).
6. **Update** `pc`, `ap` and `fp`.

The run ends when `pc` reaches a designated end address. Everything else in this VM, including
builtins, hints and proof mode, is built around this loop.

## Exercises

1. Is `[ap] = [ap - 1] * [ap - 1]` a valid way to square a value? What happens when it runs
   twice without changing `ap`?
2. In the field, what is `-1`? Is it a small or a large integer?
3. The instructions `[ap] = 3; ap++` then `[ap] = [ap - 1] * [ap - 1]; ap++` run with `ap = 10`
   and memory cells 10 and 11 empty. What is in memory afterwards, and what is `ap`?
4. Why can't Cairo simply let programs overwrite memory?

<details markdown>
<summary>Solutions</summary>

1. Yes. The first time, `[ap]` is empty and is deduced as the square. Run again with the same
   `ap`, the cell is already set, so the instruction only checks that the cell still equals the
   square. It passes, because nothing changed.
2. `-1` is `p - 1`, a 252-bit integer. Its representative is huge, but in the next chapter you'll
   see that this VM stores it as a small negative number.
3. Cell 10 = 3, cell 11 = 9, `ap = 12`. Neither instruction writes anything explicitly: both
   values are deduced.
4. The proof checks memory consistency as "every read of address `a` returns the same value".
   Overwrites would need a much more expensive memory argument. Write-once memory keeps the
   prover cheap and forces programs into a functional style.

</details>
