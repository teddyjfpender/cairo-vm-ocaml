# Follow a three-instruction Cairo program

This program puts 7 on the stack, adds 5, and leaves 12 in execution memory. It takes three VM steps. By the end you can locate the result by its address and explain why the program counter visits offsets 0, 2 and 4.

## The machine before the first step

A Cairo memory address is a pair of a segment number and an offset, written here as `segment:offset`. Each cell can hold a field element (an integer modulo the Cairo prime) or a relocatable pointer to another cell. Once a cell has a value, every later assertion about that cell must agree.

For this program the runner loads the instruction words into segment 0 and uses segment 1 as the execution stack. Three registers identify the current instruction (`pc`), the current allocation position (`ap`), and the base of the current call frame (`fp`). The runner puts two return pointers in the first two stack cells before entering `main`. Both `ap` and `fp` start at `1:2`.

## Create the compiled program

Use a source checkout of OxCairo v0.3.0 and its [OxCaml build environment](getting-started.md#build-from-source). Run the shell blocks from the repository root. The example contains the complete compiled CairoZero program, so you only need Dune and the repository's dependencies.

```sh
mkdir -p walkthrough
cat > walkthrough/add.json <<'JSON'
{
  "prime": "0x800000000000011000000000000000000000000000000000000000000000001",
  "data": [
    "0x480680017fff8000", "0x7",
    "0x482480017fff8000", "0x5",
    "0x208b7fff7fff7ffe"
  ],
  "builtins": [],
  "hints": {},
  "reference_manager": {"references": []},
  "identifiers": {"__main__.main": {"type": "function", "pc": 0}}
}
JSON
```

| Program address | Instruction | Effect |
| --- | --- | --- |
| `0:0` | `[ap] = 7; ap++` | Assert that the cell at `ap` holds 7. The empty cell acquires that value. Advance `ap` by one. |
| `0:2` | `[ap] = [ap - 1] + 5; ap++` | Read 7 from the preceding stack cell. Write the sum into the empty cell at `ap` and advance `ap`. |
| `0:4` | `ret` | Read the saved frame and return pointers. Returning to the runner's end address terminates execution. |

Each of the first two instructions occupies two program cells. The second cell holds its immediate operand, 7 or 5. The return instruction occupies one cell. The result lives in stack memory, so this program needs no output builtin.

## Run it through the typed OCaml API

Define a small Dune executable linked against the repository's public `cairo-vm-ocaml` library.

```sh
cat > walkthrough/dune <<'DUNE'
(executable
 (name inspect)
 (libraries cairo-vm-ocaml))
DUNE

cat > walkthrough/inspect.ml <<'OCAML'
open Cairovm

let () =
  let program : Program.t = Program.load_file Sys.argv.(1) in
  let config = { Cairo_run.default_config with trace = true } in
  let run : Runner.t = Cairo_run.run ~config program in
  let vm = run.vm in

  let rec print_steps step cursor =
    if cursor < vm.tlen then begin
      let next, segment, pc, ap, fp = Resources.trace_entry vm.trace cursor in
      Printf.printf "step %d   pc=%d:%d   ap=1:%d   fp=1:%d\n"
        step segment pc ap fp;
      print_steps (step + 1) next
    end
  in
  print_steps 0 0;

  for offset = 0 to vm.ap - 1 do
    let cell = Vm.read vm 1 offset in
    let value =
      if cell = Felt.empty then "empty"
      else if Felt.is_reloc cell then
        Printf.sprintf "%d:%d" (Felt.rseg cell) (Felt.roff cell)
      else Z.to_string (Felt.to_z cell)
    in
    Printf.printf "memory[1:%d] = %s\n" offset value
  done;
  Printf.printf "%d steps\n" vm.steps
OCAML

dune exec --profile release walkthrough/inspect.exe -- walkthrough/add.json
```

## Read the trace and memory together

The example produces this output on the v0.3.0 tag (`541cfe3`).

```text
step 0   pc=0:0   ap=1:2   fp=1:2
step 1   pc=0:2   ap=1:3   fp=1:2
step 2   pc=0:4   ap=1:4   fp=1:2
memory[1:0] = 2:0
memory[1:1] = 3:0
memory[1:2] = 7
memory[1:3] = 12
3 steps
```

A trace row records the registers **before** its instruction executes. At step 1 the allocation pointer has moved to `1:3`, so `[ap - 1]` reads `memory[1:2]`. At step 2 the sum already occupies `1:3` and `ap` points one cell beyond it. The trace ends with the `ret` instruction. The saved return address `3:0` is the runner's stop address and produces no further instruction row.

`Resources.trace_entry` returns the cursor for the next packed record. Use that cursor to walk the trace and `vm.steps` to count instructions. `Vm.read` returns a typed `Felt.t`. The first two stack values are relocatable pointers, while the last two are field elements that can be converted with `Felt.to_z`.

To experiment, change the immediate word `"0x5"` to `"0x6"` in `walkthrough/add.json` and rerun the Dune command. The result becomes 13. The register trace stays the same because the instruction sizes and register updates are the same.

For the instruction encoding and the rules used to deduce an empty cell, see [Instructions and the CPU](learn/instructions.md). For how trace and memory addresses are converted for export, see [Memory](learn/memory.md).
