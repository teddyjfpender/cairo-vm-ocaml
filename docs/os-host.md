# Generate a PIE from an OS witness

Run `oxcairo-os-host v1` from the release package, with Python 3.9 or newer on PATH. Write one UTF-8 JSON document to standard input, close it and read one JSON document from standard output. The host starts a fresh native VM for each request. Use separate processes and output paths for parallel blocks. Worker count is controlled by the caller.

```json
{
  "schema": 1,
  "revision": "1860b9850b5c51858c50c0f5038933e49f932eef",
  "program": "/srv/os/compiled-os.json",
  "witness": "/srv/jobs/block-input.json",
  "output": "/srv/results/block.zip",
  "limits": {"steps": 50000000, "memory_bytes": 2147483648, "wall_ms": 60000}
}
```

The default publication profile `os-host-standard` matches the serial Rust service writer using standard deflate and merged extra segments. Select `"publication":"rust-3.2"` to preserve separate extra segments, corresponding to `CairoPie::write_zip_file(path, false)`. The service's concurrent compression, level-one and platform-native writers produce different archive encodings. The selected serial profile is part of the comparison and workload configuration.

A consumer that applies its own final compression policy can request `"publication":"stored"`. The host emits an uncompressed ZIP with the five `rust-3.2` members in the same order and preserves separate extra segments. This avoids compressing an intermediate archive before the consumer validates and repackages it. Budget the output limit and temporary disk space for the uncompressed members, including 40 bytes per initialized memory cell and the ZIP headers. The response digest covers the complete stored archive.

The default operation is `generate`. For secure replay, send `{"schema":1,"operation":"replay","pie":"/srv/in.zip","output":"/srv/replayed.zip"}`. Replay accepts the same limits and checks the declared step count before VM initialization. A truncated archive is an `invalid_input` refusal.

The deterministic host requires empty or absent encryption recipients for generation. A nonempty `os_hints_config.public_keys` receives exit 6 before VM stepping. The general native CLI supports encrypted generation with fresh randomness. Secure replay accepts an already produced archive.

The program is the compiled main OS for the named revision. The sequencer OS hint processor accepts JSON and versioned OXW1 binary witnesses. [Native witness format](witness-wire.md) Preparing that witness from RPC, compiling contract classes and validating a block's state root require upstream components. Choose regular files owned by the service, keep input paths stable for the job, and give the service a private output directory on a local filesystem. These path fields are an interface for a trusted host application. A network service accepting untrusted requests must assign paths itself.

OxCairo recognizes the full and compact compiler JSON digests for Apollo revision `1860b9850b5c51858c50c0f5038933e49f932eef` and revision `ffdf1f9e1485753ccc35b860b24dfdc68fe8bf45`. For an independently qualified build, set the **operator environment** variable `OXCAIRO_OS_PROFILE` to a trusted JSON file with `revision` (40 lowercase hex digits) and `program_sha256` (64 lowercase hex digits). Record the compiler, source, program hash and qualification receipts with that profile. The worker hashes its private compiler snapshot before execution. Adding a digest authorizes those bytes for execution and carries no parity certification.

A successful response has schema 1, status `ok`, the absolute published output path, byte length and SHA-256 of the entire archive. Exit status is zero. The worker validates execution in secure mode and publishes with `--pie_profile rust-3.2`, including the stock ZIP headers and compressed bytes. The static archive dependency is used only for container encoding. The supervisor flushes the completed archive, atomically replaces the destination and syncs the output directory. A killed process can leave the previous or the complete new file, depending on whether publication occurred. Retry the same request to recover. The next job reclaims the previous staging files under the output lock. Linux binds the worker lifetime to its supervisor. On macOS a guardian observes supervisor exit and terminates its own native child before releasing the lock. The lock file is persistent. Removing it while jobs are running would bypass serialization.

Every refusal has schema 1, status `rejected`, a stable `code` and a human-readable `detail`. Match on the code and process exit status. Diagnostic wording may change.

| Exit | Code | Meaning |
| --- | --- | --- |
| 2 | invalid_request | Invalid version, field, syntax, size or output alias |
| 3 | unknown_revision | No operator or built-in pin for the revision |
| 4 | program_mismatch | Compiler snapshot differs from an allowed digest or exceeds 128 MiB |
| 5 | invalid_input | Invalid witness or VM rejection |
| 6 | unsupported_randomized_encryption | The generation witness requests state-diff encryption with fresh private randomness |
| 20 | step_limit | A further VM step was needed |
| 21 | memory_limit | Memory budget exhausted or below the worker minimum |
| 22 | wall_limit | Worker or publication deadline reached |
| 23 | output_limit | Archive exceeds the file size cap |
| 24 | file_limit | Descriptor limit reached or below the worker minimum |
| 25 | storage_limit | Filesystem capacity or quota exhausted |
| 26 | busy | Another worker has the output lock |
| 27 | io_error | Host filesystem error |
| 28 | interrupted | Worker lost its supervisor during startup |
| 70 | internal_fault | Unexpected worker failure |

| Limit | Default ceiling | Scope |
| --- | ---: | --- |
| steps | 100000000 | Executed Cairo instructions |
| memory_bytes | 4294967296 | Worker virtual address space on Linux, sampled resident bytes on macOS |
| wall_ms | 120000 | Time from request acceptance through the pre-publication check |
| output_bytes | 1073741824 | Maximum archive file size |
| open_files | 128 | Worker descriptor ceiling |

An operator can lower or raise these ceilings for a deployment by setting `OXCAIRO_HOST_LIMITS` to a JSON object with the same limit keys. Each request defaults to the lower of the built-in default and the operator ceiling. To run a larger block, raise its operator ceiling and request the larger budget explicitly. Limits are positive integers. Receiving a request has its own deadline, the lower of 120 seconds and the operator wall ceiling. A sender that leaves the pipe open receives a wall-limit refusal. The request is limited to 64 KiB, compiler staging to 128 MiB, and the worker requires at least 32 MiB and eight descriptors. On Linux the kernel enforces address space, file size and descriptor limits. Before starting OxCaml the host sizes the GC nursery for the requested budget and caps the runtime at four domains, including the main domain. On macOS a short resident-memory peak can fall between samples. Reserve disk for the compiler snapshot, archive, previous output and filesystem metadata. Final filesystem sync latency can extend past the deadline.

The C replay library owns its OCaml runtime and requires one calling OS thread for its process lifetime. The process interface avoids imposing that embedding constraint on callers.

## Use a packed program

A service that runs the same compiled OS repeatedly can pack its parser metadata once. This example uses the [Apollo compact OS pin](https://github.com/teddyjfpender/cairo-vm-ocaml/blob/4f40b032f0bc19b89ba221cebc57c814b6346ec7/test/fixtures/programs/apollo-0.20.0-rc.1/manifest.json) and the CLI from the same release as the host. Run the setup in an operator-owned directory containing the decompressed compact JSON. Only the operator should have write access to that directory and the profile. Never take the profile path or digest from a job request.

```sh
set -eu
cd /srv/os
revision=1860b9850b5c51858c50c0f5038933e49f932eef
json_sha=794c90c23d0beda4f34bd061e34c726ddff95bf1eebb441ee2ea9af1951f3c67
printf '%s  %s\n' "$json_sha" compiled-os.json | shasum -a 256 -c -
cairo-vm-cli compiled-os.json --pack_program compiled-os.packed
packed_sha=$(shasum -a 256 compiled-os.packed | awk '{print $1}')
jq -n --arg revision "$revision" --arg digest "$packed_sha" \
  '{revision: $revision, program_sha256: $digest}' > apollo-packed-profile.json
```

Distribute this exact packed file with its profile to each host. Changing the input bytes or the encoder version can change the packed digest. Set the profile in the service environment. Starting from the generation request above, change only the program path. The witness and output fields still name the service-assigned files.

```sh
export OXCAIRO_OS_PROFILE=/srv/os/apollo-packed-profile.json
jq '.program = "/srv/os/compiled-os.packed"' /srv/jobs/request.json | oxcairo-os-host v1
```

Regenerate the packed file and its profile from the verified JSON when upgrading OxCairo or changing the compiled OS. Confirm the complete archive against the expected Rust digest for a known witness before switching production requests.

## Generate multiple PIEs in a resident worker

The native `oxcairo-os-host worker-v1` interface accepts a stream of generation
jobs. Start one worker per serial queue. At startup the worker verifies the
SHA-256 of the exact program bytes it will parse, prepares the OS program image,
and emits a JSON line with `status: "ready"` and `program_sha256`. Use a digest
from the operator's qualified revision manifest. For a packed program, pin the
digest produced by the trusted packing procedure above. The operator selects
the program and digest on the command line. Requests cannot change either.
The installed host directly executes its sibling `oxcairo-os-worker pie-v1`
for this protocol. The warm path requires no Python interpreter.

```sh
oxcairo-os-host worker-v1 /srv/os/compiled-os.json \
  --sha256 794c90c23d0beda4f34bd061e34c726ddff95bf1eebb441ee2ea9af1951f3c67
```

Send one UTF-8 JSON object per line, terminated by a newline, and read one reply
per line in the same order. The worker accepts absolute, service-assigned paths
in a private local directory.

```json
{"schema":1,"witness":"/srv/jobs/block-input.json","output":"/srv/results/block.zip","publication":"stored","limits":{"steps":50000000,"wall_ms":60000}}
```

Each job inherits the prepared image and initialized runtime in a fresh
copy-on-write process. Mutable VM state, class-cache insertions, descriptors
opened by the job, and resource limits have job lifetime. A request incurs one
fork and zero program parses or executable launches. The parent retains the
same program across successful jobs and typed refusals. Parallel callers can
run multiple workers, with the same per-output lock as the one-shot interface.

Limits use the same keys, defaults, operator ceilings and rejection names as
the one-shot interface. The wall clock covers the job through the pre-rename
check. The worker hashes and syncs its completed file before publication, then
syncs the destination directory. Memory accounting includes the inherited
runtime and program. Linux applies an address-space cap, and macOS samples
resident memory. Set the memory budget for both the template and the job.
`publication` supports `stored`, `rust-3.2`, and the default
`os-host-standard`, as described above.
The worker also accepts `fast-1` for level-one deflate with separate extra
segments. Its uncompressed contents match the stored profile. Record the
chosen codec and linked compression library when comparing archive digests.

Success includes `status: "ok"`, `output`, `bytes`, and `sha256`. A rejected
job returns `status: "rejected"`, `code`, and `detail`. Submit another job on
the same stream after a rejection. EOF at a record boundary exits successfully.
A malformed complete job receives a refusal. A record exceeding 64 KiB, EOF in
a partial record, or a stalled partial record terminates the stream after its
refusal. Between records the worker can remain idle indefinitely.

On worker loss, restart it with the same pin and retry the in-flight request.
The operating system terminates its private job process when the supervisor
exits. Only the supervisor publishes to the destination. After interruption,
the next request for that output cleans its own stale stage under the output
lock. If the destination was already renamed, retrying the same deterministic
job republishes the complete result. The SHA-256 receipt identifies the archive
for the selected profile.
