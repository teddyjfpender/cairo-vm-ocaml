# Native OS witness input (OXW1)

A host can send the sequencer's prepared OS witness as binary data. CLI and worker callers pass the file through the existing witness path. OxCaml callers can build the witness tree from their own values and pass it directly to `Witness_wire.write`. A host that already owns compiled classes and execution results can encode its native values while assembling the witness.

To convert an existing fixture, run:

```sh
cairo-vm-cli --pack_os_witness prepared.oxw prepared.json
cairo-vm-cli --os_hints prepared.oxw --layout all_cairo --cairo_pie_output block.zip program.json
```

The frame begins with the four ASCII bytes `OXW1`, a four-byte unsigned **big-endian** payload length, and exactly that many bytes of definite-length CBOR. The top-level value is the sequencer witness map. Unknown frame versions, trailing bytes, duplicate keys, non-text map keys, invalid UTF-8 and invalid packed words are refused. Each frame owns its full input. Cached entries can always be rebuilt from the frame.

## Types and limits

Preserve object member order, array order, field names, nulls, booleans and the sequencer's distinction between a numeric value and a felt string. For example, encode a missing optional call as CBOR null (`f6`) and an empty list as an empty CBOR array (`80`). The decoder accepts major types 0 and 1 integers, UTF-8 text, arrays, maps, true, false, null, finite binary32/64 numbers, and standard tags 2/3 with at most 32 magnitude bytes. Definite lengths may use any legal width. The numeric fields consumed by the OS retain their usual field-specific checks.

The payload limit is 256 MiB. The structural limit is 4,194,304 items, including map keys and packed words, with a maximum depth of 256. A regular file's length is checked against its header before the payload allocation. Per-job process memory, wall, step and output limits still apply.

Two optional encodings reduce the cost of repeated class input:

* An entry in `os_input.compiled_classes` or `os_input.deprecated_compiled_classes` can use CBOR tag 24 containing a byte string. Its bytes must be exactly one encoded class map. A resident reader can reuse a previously decoded entry only after exact byte and class-kind equality. The cache holds at most 12 class entries, each at most 2 MiB and 150,000 structural items. Ordinary class maps work without the tag.
* A modern compiled class's `bytecode` may contain a byte string in place of the regular array. Its first four bytes give the word count (unsigned big-endian). Each word is a one-byte magnitude width from 0 to 32, followed by that many **little-endian** bytes. Width zero represents zero. A nonempty magnitude must have a nonzero most-significant byte and must be strictly below the Stark field prime. Word count and length must match exactly. For example, the word sequence 0, 256 is `00 00 00 02 00 02 00 01`.

The CLI conversion emits both encodings. The decoder accepts inline maps and ordinary bytecode arrays as well. If a host starts from JSON, account for conversion when measuring its service. If it already owns typed values, account for serialization during witness assembly.

See the [independent Rust producer and measurements](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/v0.3.0/bench/reference/witness-wire/README.md) and [CBOR specification](https://www.rfc-editor.org/rfc/rfc8949.html).
