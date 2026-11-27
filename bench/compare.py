#!/usr/bin/env python3
"""End-to-end wall-clock comparison against cairo-vm-cli (Rust).

usage: bench/compare.py RUST_CLI OCAML_CLI PROGRAM.json... [--trace] [--runs N]
Both binaries get identical flags (--layout all_cairo, optional trace/memory
files). Outputs are checked byte-for-byte before timing is reported."""
import subprocess, sys, time, os, tempfile, filecmp, statistics

args = [a for a in sys.argv[1:] if not a.startswith('--')]
runs = int(sys.argv[sys.argv.index('--runs') + 1]) if '--runs' in sys.argv else 5
if '--runs' in sys.argv: args.remove(str(runs))
trace = '--trace' in sys.argv
rust, ocaml, progs = args[0], args[1], args[2:]
tmp = tempfile.mkdtemp()

def run(binary, prog, tag):
    cmd = [binary, prog, '--layout', 'all_cairo', '--print_output']
    if trace:
        cmd += ['--trace_file', f'{tmp}/{tag}.trace', '--memory_file', f'{tmp}/{tag}.mem']
    best = []
    out = None
    for _ in range(runs):
        t = time.perf_counter()
        r = subprocess.run(cmd, capture_output=True)
        best.append(time.perf_counter() - t)
        if r.returncode != 0:
            raise SystemExit(f'{binary} failed on {prog}: {r.stderr.decode()[:300]}')
        out = r.stdout
    return min(best), out

print(f"{'program':45} {'rust s':>8} {'ocaml s':>8} {'speedup':>8}  identical")
tr = to = 0.0
for p in progs:
    name = os.path.basename(p)[:-5]
    rt, ro = run(rust, p, 'r')
    ot, oo = run(ocaml, p, 'o')
    same = ro == oo
    if trace:
        same = same and filecmp.cmp(f'{tmp}/r.trace', f'{tmp}/o.trace', False) and filecmp.cmp(f'{tmp}/r.mem', f'{tmp}/o.mem', False)
    tr += rt; to += ot
    print(f'{name:45} {rt:8.3f} {ot:8.3f} {rt/ot:7.2f}x  {"yes" if same else "NO"}')
print(f"{'TOTAL':45} {tr:8.3f} {to:8.3f} {tr/to:7.2f}x")
