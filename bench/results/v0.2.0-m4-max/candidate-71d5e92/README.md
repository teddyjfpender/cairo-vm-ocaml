# Intermediate execution-loop release build

Runtime `71d5e92` is the combined loader and checked builtin-loop build preceding `86fd938`. Five cold stock-sequencer pairs per scenario gave 3.12× median and 11.95× summed time over 70 cases. Across 22 scaled native workloads, the median was 11.56× and the summed-time ratio was 12.44×, with 20/22 reaching 10×. The later release used additional compiler changes. Paired changes and reruns under different concurrent host loads have separate receipts.

The manifest records the PGO binary hashes, package identity, distributions and raw CSV names by workload. The proof input, production archive and generic parity checks are alongside the timing data.
