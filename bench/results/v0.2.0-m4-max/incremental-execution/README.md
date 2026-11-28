# Incremental OCaml VM execution measurements

These paired Apple M4 Max measurements compare ordinary release builds of the OCaml VM. The first three files isolate the prepared-runner Pedersen cache, from `e559436` to `5ad5da4`. The last three compare the cache and parallel loader at `fc1ba53` with the integrated runtime at `43598c9`. The integrated cold CLI also includes protected speculative legacy bytecode hashing. [Build and input hashes](manifest.json)

| Raw paired wall times | Scenarios | Pairs per scenario | Median scenario speedup | Suite time speedup |
| --- | ---: | ---: | ---: | ---: |
| [pedersen-cache-warm-70.csv](pedersen-cache-warm-70.csv) | 70 | 5 | 1.025× | 1.141× |
| [pedersen-cache-cold-70.csv](pedersen-cache-cold-70.csv) | 70 | 3 | 0.993× | 0.995× |
| [pedersen-cache-large.csv](pedersen-cache-large.csv) | 4 | 3 | 0.986× | 0.989× |
| [integrated-cold-middle.csv](integrated-cold-middle.csv) | 2 | 25 | 1.124× | 1.116× |
| [integrated-cold-70.csv](integrated-cold-70.csv) | 70 | 5 | 1.001× | 1.028× |
| [integrated-large.csv](integrated-large.csv) | 4 | 5 | 0.997× | 1.003× |

The median scenario speedup is the median across scenarios of the median paired `base_s / after_s`. Suite time speedup divides the sum of each scenario’s median baseline time by the corresponding sum after the change. Both include public-output formatting. The ordinary CLI launches a new process, reads the program and witness, runs, securely finalizes, prints and exits. The prepared worker loads one program image per binary before timing, then reads a witness, creates a fresh VM, runs, securely finalizes and writes its response for each command. Operating-system file caches were shared. Other local work continued during the measurements.

The 70-case runs shuffle all distinct witnesses once per round with Python’s `Random(1212)`, starting from the sequencer corpus order. The binaries run consecutively for each witness. The candidate runs first when the zero-based round plus scenario position is even. Every paired public response had to match byte for byte. The two middle cases use the same trivial-diff configuration with Cairo 0 and Cairo 1 contracts. The four large rows cover 8,192 storage writes, 8,192 ERC20 transfers, 9,216 mixed transactions (6,144 reverted) and 4,096 scattered storage updates.

A second check at `43598c9` compared all 70 fresh-process outputs and all 70 shuffled prepared-worker outputs against saved digests from the pinned Rust runner. Each digest covers the public words reduced modulo the Cairo prime and concatenated as 32-byte big-endian values. [Witness and output hashes](public-output-digests.csv)

The integrated binary passed `dune runtest --profile release` and matched every expected upstream PIE member on all 25 native OS fixtures. The first native sweep reached its process-group memory cap after 23 fixtures. The remaining two ERC20 fixtures passed in a separate invocation. The generic differential suite matched 150/150 execution, 150/150 proof, 146 successful replay plus four programs that failed in both implementations, and 2/2 Stwo-exclusive cases. With the OCaml runtime capped at three domains, the lifecycle check tested eight abandoned initializations, eight program-load errors and eight runner-initialization errors. After each return all spare domains were immediately available. Occupying both spare domains forced the preparation fallback. A witness with three legacy and two CASM classes produced the same 45 output lines on that path. Flipping one legacy bytecode word caused both the prior and integrated binaries to reject the declared class hash. Cache mode was restored after the failure.
