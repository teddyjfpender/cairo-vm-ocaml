# Single-step execution probe

Build with `dune build --profile release test/execution_contract/probe.exe`. The test executable reads one JSON object from standard input and writes one JSON observation to standard output. Each process starts with fresh state. Protocol version 1 supports a bare VM with permanent segments and an optional Pedersen builtin.

```json
{"schema":1,"segments":3,"trace":true,"registers":{"pc":[2,0],"ap":1,"fp":1},"memory":[[[2,0],{"felt":"5198420613823168512"}],[[2,1],{"felt":"7"}],[[1,0],{"felt":"3"}]],"actions":[{"step":1}]}
```

The sample executes one addition and writes 10 at address `[1,1]`. Segments are numbered from zero. Registers AP and FP address segment 1. A memory entry carries its address and either a canonical unsigned decimal felt or a pointer such as `{"ptr":[2,1]}`. Omitted cells are holes. Set `pedersen_segment` to install a Pedersen builtin on a numbered segment of 2 or greater.

Actions execute in order. `step` attempts the requested number of instructions. `pc` sets the program counter and `fp` sets the frame offset. `skip:true` decodes and advances past the instruction while preserving the trace and successful step count. `replace_unaccessed` takes an address and new value, and requires an initialized, unaccessed cell. Replacing an instruction invalidates its decode cache.

The response includes PC, AP and FP as address pairs, successful steps, every initialized memory cell with its typed value and access flag, and every requested relocated trace triple in PC/AP/FP order. Trace relocation starts at 1 and uses the final segment high-water marks. The probe also returns extended BLAKE resource counts and each Pedersen builtin's verified output addresses and AIR private inputs. A VM error reports its zero-based attempted step and original diagnostic alongside the surviving state. Later actions are skipped. Invalid probe requests exit with status 2.

This executable is a tests-only differential interface. Its trace collection and inspection overhead is included when it is run. Native OS service throughput is measured with the OS host.
