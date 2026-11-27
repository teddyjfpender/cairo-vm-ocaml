# Learn

These chapters explain how a Cairo VM works and how this one is built. Each builds on the one
before, and each ends with exercises and worked solutions.

| Chapter | You will learn |
| --- | --- |
| [1. The Cairo machine](cairo-machine.md) | field elements, write-once memory, the three registers, the step |
| [2. Values and the `Felt.t` type](values.md) | how every value fits in one OCaml int, and why the type is private |
| [3. Memory and segments](memory.md) | segments, relocatables, off-heap storage, temporary segments |
| [4. Instructions and the CPU](instructions.md) | instruction encoding, operand deduction, the fast path and the C kernel |
| [5. Builtins and hints](builtins-and-hints.md) | builtin segments, auto-deduction, and how Python hints run in OCaml |
| [6. Runs, relocation and proofs](runs-and-proofs.md) | the runner's phases, the output files, proof mode and AIR inputs |

Prerequisites: some OCaml or another ML-family language, and basic modular arithmetic. No prior
Cairo knowledge is assumed.
