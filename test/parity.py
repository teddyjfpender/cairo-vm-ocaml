#!/usr/bin/env python3
"""Differential parity check against cairo-vm-cli (Rust) over a corpus.

usage: test/parity.py RUST_CLI OCAML_CLI DIR [--proof] [-j N] [--filter SUBSTR] [--layout L] [--layout_params FILE] [--pie] [--from_pie] [--verbose]

For each compiled program in DIR, both CLIs run with identical flags. A program
PASSES when both succeed with byte-identical stdout, trace, memory (and AIR
public/private inputs in proof mode), or when both fail. --from_pie first has
the Rust CLI write each program's Cairo PIE, then runs both CLIs with
--run_from_cairo_pie on it and compares their outputs and output PIEs
(programs whose PIE cannot be produced count as NO_PIE). Delegation to Rust is
disabled for the OCaml binary (CAIRO_VM_RUST_CLI is removed from its env)."""
import os, sys, subprocess, tempfile, glob, json, zipfile, concurrent.futures as cf

argv = sys.argv[1:]
proof = '--proof' in argv
from_pie = '--from_pie' in argv
pie = '--pie' in argv or from_pie
verbose = '--verbose' in argv
jobs = int(argv[argv.index('-j') + 1]) if '-j' in argv else os.cpu_count() // 2
filt = argv[argv.index('--filter') + 1] if '--filter' in argv else None
layout_arg = argv[argv.index('--layout') + 1] if '--layout' in argv else None
params_arg = argv[argv.index('--layout_params') + 1] if '--layout_params' in argv else None
pos = [a for i, a in enumerate(argv) if not a.startswith('-') and (i == 0 or argv[i - 1] not in ('-j', '--filter', '--layout', '--layout_params'))]
rust, ocaml, corpus = pos[0], pos[1], pos[2]
tmp = tempfile.mkdtemp()
env_o = {k: v for k, v in os.environ.items() if k not in ('CAIRO_VM_RUST_CLI', 'CAIRO_VM_DELEGATED')}

def run(binary, prog, tag, env=None):
    base = f'{tmp}/{os.path.basename(prog)}.{tag}'
    layout = layout_arg or ('starknet_with_keccak' if proof else 'all_cairo')
    cmd = [binary, prog] + (['--run_from_cairo_pie'] if from_pie else []) + ['--layout', layout, '--print_output',
           '--trace_file', base + '.trace', '--memory_file', base + '.mem']
    outs = [base + '.trace', base + '.mem']
    if params_arg:
        cmd += ['--cairo_layout_params_file', params_arg]
    if proof:
        cmd += ['--proof_mode', '--air_public_input', base + '.pub', '--air_private_input', base + '.priv',
                '--fill-holes', 'false']
        outs += [base + '.pub', base + '.priv']
    if pie:
        cmd += ['--cairo_pie_output', base + '.pie.zip']
        outs += [base + '.pie.zip']
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=300, env=env)
    except subprocess.TimeoutExpired:
        return None, b'', 'timeout', outs
    return r.returncode, r.stdout, r.stderr.decode(errors='replace'), outs

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

def equal_streams(left, right):
    while True:
        chunk = left.read(1024 * 1024)
        if chunk != right.read(1024 * 1024):
            return False
        if not chunk:
            return True

def equal_artifacts(left, right):
    try:
        if left.endswith('.pie.zip'):
            with zipfile.ZipFile(left) as lhs, zipfile.ZipFile(right) as rhs:
                if sorted(lhs.namelist()) != sorted(rhs.namelist()):
                    return False
                for name in lhs.namelist():
                    with lhs.open(name) as a, rhs.open(name) as b:
                        if not equal_streams(a, b):
                            return False
                return True
        with open(left, 'rb') as a, open(right, 'rb') as b:
            if left.endswith('.priv'):
                return norm_priv(a.read()) == norm_priv(b.read())
            if left.endswith('.pub'):
                return norm_pub(a.read()) == norm_pub(b.read())
            return equal_streams(a, b)
    except (OSError, zipfile.BadZipFile):
        return False

def make_pie(prog):
    path = f'{tmp}/{os.path.basename(prog)}.input.pie.zip'
    cmd = [rust, prog, '--layout', layout_arg or 'all_cairo', '--cairo_pie_output', path]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=300)
    except subprocess.TimeoutExpired:
        return None
    return path if r.returncode == 0 else None

def check(prog):
    name = os.path.basename(prog)
    if from_pie:
        prog = make_pie(prog)
        if prog is None:
            return name, 'NO_PIE', ''
    rc_r, out_r, err_r, files_r = run(rust, prog, 'r')
    rc_o, out_o, err_o, files_o = run(ocaml, prog, 'o', env_o)
    if rc_r is None or rc_o is None:
        return name, 'TIMEOUT', 'VM exceeded the time limit'
    if rc_r != 0 and rc_o != 0:
        return name, 'BOTH_FAIL', err_r.strip().splitlines()[-1:] if err_r else ''
    if rc_r != 0:
        return name, 'RUST_ONLY_FAIL', (err_r.strip().splitlines() or [''])[-1][:200]
    if rc_o != 0:
        return name, 'OCAML_FAIL', (err_o.strip().splitlines() or [''])[-1][:200]
    if out_r != out_o:
        return name, 'MISMATCH', 'stdout'
    for fr, fo in zip(files_r, files_o):
        if not equal_artifacts(fr, fo):
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
        if verbose or status not in ('PASS', 'BOTH_FAIL', 'NO_PIE'):
            print(f'{status:15} {name:60} {detail}', flush=True)
counts = {}
for _, s, _ in results:
    counts[s] = counts.get(s, 0) + 1
print('SUMMARY', ' '.join(f'{k}={v}' for k, v in sorted(counts.items())), f'total={len(results)}')
sys.exit(0 if counts.get('PASS', 0) and set(counts) <= {'PASS', 'BOTH_FAIL', 'NO_PIE'} else 1)
