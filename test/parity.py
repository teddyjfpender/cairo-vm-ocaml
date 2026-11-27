#!/usr/bin/env python3
"""Differential parity check against cairo-vm-cli (Rust) over a corpus.

usage: test/parity.py RUST_CLI OCAML_CLI DIR [--proof] [-j N] [--filter SUBSTR] [--verbose]

For each compiled program in DIR, both CLIs run with identical flags. A program
PASSES when both succeed with byte-identical stdout, trace, memory (and AIR
public/private inputs in proof mode), or when both fail. Delegation to Rust is
disabled for the OCaml binary (CAIRO_VM_RUST_CLI is removed from its env)."""
import os, sys, subprocess, tempfile, glob, json, concurrent.futures as cf

argv = sys.argv[1:]
proof = '--proof' in argv
verbose = '--verbose' in argv
jobs = int(argv[argv.index('-j') + 1]) if '-j' in argv else os.cpu_count() // 2
filt = argv[argv.index('--filter') + 1] if '--filter' in argv else None
pos = [a for i, a in enumerate(argv) if not a.startswith('-') and (i == 0 or argv[i - 1] not in ('-j', '--filter'))]
rust, ocaml, corpus = pos[0], pos[1], pos[2]
tmp = tempfile.mkdtemp()
env_o = {k: v for k, v in os.environ.items() if k not in ('CAIRO_VM_RUST_CLI', 'CAIRO_VM_DELEGATED')}

def run(binary, prog, tag, env=None):
    base = f'{tmp}/{os.path.basename(prog)}.{tag}'
    layout = 'starknet_with_keccak' if proof else 'all_cairo'
    cmd = [binary, prog, '--layout', layout, '--print_output',
           '--trace_file', base + '.trace', '--memory_file', base + '.mem']
    outs = [base + '.trace', base + '.mem']
    if proof:
        cmd += ['--proof_mode', '--air_public_input', base + '.pub', '--air_private_input', base + '.priv',
                '--fill-holes', 'false']
        outs += [base + '.pub', base + '.priv']
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=300, env=env)
    except subprocess.TimeoutExpired:
        return None, b'', 'timeout', outs
    return r.returncode, r.stdout, r.stderr.decode(errors='replace'), outs

def read(p):
    try:
        with open(p, 'rb') as f:
            return f.read()
    except OSError:
        return None

def norm_priv(b):
    # AIR private input embeds absolute trace/memory paths; compare the rest
    if b is None:
        return None
    try:
        j = json.loads(b)
        j.pop('trace_path', None); j.pop('memory_path', None)
        return json.dumps(j, sort_keys=True).encode()
    except Exception:
        return b

def norm_pub(b):
    # cairo-vm serializes memory_segments from a HashMap, so its key order is
    # random per process. Compare that object as a map and everything else
    # byte-for-byte.
    if b is None:
        return None
    try:
        t = b.decode()
        i = t.index('  "memory_segments": {')
        j = t.index('\n  },\n', i) + len('\n  },\n')
        segs = json.loads('{' + t[i:j].rstrip().rstrip(',') + '}')
        return (t[:i] + t[j:]).encode() + json.dumps(segs, sort_keys=True).encode()
    except Exception:
        return b

def check(prog):
    rc_r, out_r, err_r, files_r = run(rust, prog, 'r')
    rc_o, out_o, err_o, files_o = run(ocaml, prog, 'o', env_o)
    name = os.path.basename(prog)
    if rc_r != 0 and rc_o != 0:
        return name, 'BOTH_FAIL', err_r.strip().splitlines()[-1:] if err_r else ''
    if rc_r != 0:
        return name, 'RUST_ONLY_FAIL', (err_r.strip().splitlines() or [''])[-1][:200]
    if rc_o != 0:
        return name, 'OCAML_FAIL', (err_o.strip().splitlines() or [''])[-1][:200]
    if out_r != out_o:
        return name, 'MISMATCH', 'stdout'
    for fr, fo in zip(files_r, files_o):
        a, b = read(fr), read(fo)
        if fr.endswith('.priv'):
            a, b = norm_priv(a), norm_priv(b)
        if fr.endswith('.pub'):
            a, b = norm_pub(a), norm_pub(b)
        if a != b:
            return name, 'MISMATCH', os.path.splitext(fr)[1]
    for f in files_r + files_o:
        try: os.remove(f)
        except OSError: pass
    return name, 'PASS', ''

progs = sorted(glob.glob(os.path.join(corpus, '*.json')))
if filt:
    progs = [p for p in progs if filt in p]
results = []
with cf.ThreadPoolExecutor(jobs) as ex:
    for name, status, detail in ex.map(check, progs):
        results.append((name, status, detail))
        if verbose or status not in ('PASS', 'BOTH_FAIL'):
            print(f'{status:15} {name:60} {detail}', flush=True)
counts = {}
for _, s, _ in results:
    counts[s] = counts.get(s, 0) + 1
print('SUMMARY', ' '.join(f'{k}={v}' for k, v in sorted(counts.items())), f'total={len(results)}')
sys.exit(0 if set(counts) <= {'PASS', 'BOTH_FAIL'} else 1)
