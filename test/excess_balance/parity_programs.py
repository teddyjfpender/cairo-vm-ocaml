"""Writes and compiles CairoZero programs that run the dex EXCESS_BALANCE hint,
for byte-for-byte comparison with cairo-vm-cli via test/parity.py. Includes the
inputs of the upstream excess_balance.rs unit tests.

usage: parity_programs.py OUT_DIR CAIRO_COMPILE CAIRO_PATH"""
import os, subprocess, sys
out, cc, cp = sys.argv[1:4]
os.makedirs(out, exist_ok=True)
HINT = '''from excess_balance import excess_balance_func

res = excess_balance_func(ids, memory, __dict_manager)

ids.check_account_value = res["account_value"]
ids.check_excess_balance = res["excess_balance"]
ids.check_margin_requirement_d = res["margin_requirement"]
ids.check_unrealized_pnl_d = res["unrealized_pnl"]'''
BTC, ETH, AVAX, SOL, DOGE = 20527877651862571847371805264, 21456356293159021401772216912, 5176525270854594879110454268496, 25783120691025710696626475600, 6044027408028715819619898970704
USDC = 6148332971604923204
MKTS = [BTC, ETH, AVAX, SOL, DOGE]
STD = (5000000, 20000, 50000000, 20000000000000)

def program(t, assets, account, prices, indices, perps, fees, balances):
    w = []
    def dwrite(d, k, v): w.append(f'    dict_write{{dict_ptr={d}}}({k}, {v});')
    for k, v in prices.items(): dwrite('prices', k, v)
    for k, v in indices.items(): dwrite('indices', k, v)
    for i, (k, (b, f, m, s)) in enumerate(perps.items()):
        w.append(f'    let (pp{i}: felt*) = alloc();')
        w.append(f'    assert pp{i}[0] = {k};')
        for j, x in zip(range(4, 8), (b, f, m, s)): w.append(f'    assert pp{i}[{j}] = {x};')
        dwrite('perps', k, f'cast(pp{i}, felt)')
    for k, v in fees.items(): dwrite('fees', k, v)
    for i, (k, (a, c, f)) in enumerate(balances.items()):
        w.append(f'    let (pb{i}: felt*) = alloc();')
        for j, x in enumerate((k, a, c, f)): w.append(f'    assert pb{i}[{j}] = {x};')
        dwrite('balances', k, f'cast(pb{i}, felt)')
    hint = '\n'.join('    ' + l if l else '' for l in HINT.split('\n'))
    return f'''%builtins output
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.default_dict import default_dict_new
from starkware.cairo.common.dict import dict_write
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.serialize import serialize_word

const MARGIN_CHECK_INITIAL = 1;

func check{{output_ptr: felt*}}(
    margin_check_type: felt, token_assets_value_d: felt, account: felt,
    prices_cache_ptr: DictAccess*, indices_cache_ptr: DictAccess*, perps_cache_ptr: DictAccess*,
    fees_cache_ptr: DictAccess*, perps_balances_cache_ptr: DictAccess*,
) {{
    alloc_locals;
    local check_account_value;
    local check_excess_balance;
    local check_margin_requirement_d;
    local check_unrealized_pnl_d;
    %{{
{hint}
    %}}
    serialize_word(check_account_value);
    serialize_word(check_excess_balance);
    serialize_word(check_margin_requirement_d);
    serialize_word(check_unrealized_pnl_d);
    return ();
}}

func main{{output_ptr: felt*}}() {{
    alloc_locals;
    let (prices) = default_dict_new(0);
    let (indices) = default_dict_new(0);
    let (perps) = default_dict_new(0);
    let (fees) = default_dict_new(0);
    let (balances) = default_dict_new(0);
{chr(10).join(w)}
    check({t}, {assets}, {account}, prices, indices, perps, fees, balances);
    return ();
}}
'''

def std_case(t, assets, account, bal):
    return dict(t=t, assets=assets, account=account,
                prices={**{m: 5100000000000 for m in MKTS}, USDC: 100000000},
                indices={m: 0 for m in MKTS}, perps={m: STD for m in MKTS},
                fees={100: 10000, 200: 10000}, balances=bal)

ok_bal = {m: (1000000000, 20000, 0) for m in MKTS[1:]}
ok_bal[BTC] = (900000000, 18000, 0)
fail_bal = {m: (0, 0, 0) for m in MKTS[1:]}
fail_bal[BTC] = (-100000000, -5150000000000, 0)
big = 70000000000000000000  # 7e11 units: products overflow 96 bits at scale 16
cases = {
    'eb_rust_success': std_case(1, 1005149999998000, 200, ok_bal),
    'eb_rust_failure': std_case(1, 0, 100, fail_bal),
    'eb_maintenance': std_case(0, 1005149999998000, 200, ok_bal),
    'eb_with_settlement': std_case(0, 7, 100, {**ok_bal, USDC: (5, 5, 5)}),
    'eb_rounding': dict(t=0, assets=-123456789012345, account=7,
        prices={USDC: 99999937, BTC: 9876543210987}, indices={BTC: -31415926535}, perps={BTC: (3333333, 77777, 33333333, 1)},
        fees={7: 12345}, balances={BTC: (123456789012345, -98765432109, 27182818284)}),
    'eb_rounding_imf': dict(t=1, assets=1, account=7,
        prices={USDC: 100000003, BTC: 9876543210987}, indices={BTC: 3}, perps={BTC: (1, 1, 1, 0)},
        fees={7: 99999999}, balances={BTC: (-big, big, -7)}),
    'eb_overflow_96': dict(t=1, assets=1, account=7,
        prices={USDC: 100000000, BTC: 2**95}, indices={BTC: 0}, perps={BTC: STD},
        fees={7: 1}, balances={BTC: (2**95, 0, 0)}),
    'eb_felt_too_big': dict(t=1, assets=1, account=7,
        prices={USDC: 100000000, BTC: 2**96}, indices={BTC: 0}, perps={BTC: STD},
        fees={7: 1}, balances={BTC: (1, 0, 0)}),
    'eb_felt_max_ok': dict(t=1, assets=2**96 - 1, account=7,
        prices={USDC: 1, BTC: 2**96 - 1}, indices={BTC: 0}, perps={BTC: STD},
        fees={7: 1}, balances={BTC: (-1, 0, 0)}),
    'eb_rounding_many': dict(t=0, assets=31, account=7,
        prices={USDC: 100000007, BTC: 3, ETH: 5}, indices={BTC: 7, ETH: -11}, perps={BTC: (1, 3, 99999999, 0), ETH: (1, 7, 77777777, 0)},
        fees={7: 13}, balances={BTC: (2**60 + 12345, -(2**59) - 7, 2**40 + 3), ETH: (-(2**57) - 1, 2**56 + 9, -(2**41))}),
    'eb_shift_boundary': dict(t=1, assets=0, account=7,
        prices={USDC: 100000000, BTC: 99999999}, indices={BTC: 0}, perps={BTC: (1, 1, 1, 1)},
        fees={7: 1}, balances={BTC: (1, 0, 0)}),
    'eb_exact_zero': dict(t=1, assets=0, account=7,
        prices={USDC: 100000000, BTC: 100000000}, indices={BTC: 0}, perps={BTC: (1, 1, 1, 1)},
        fees={7: 1}, balances={BTC: (1, 0, 0)}),
    'eb_missing_index': dict(t=1, assets=0, account=7,
        prices={USDC: 100000000, BTC: 1}, indices={ETH: 0}, perps={BTC: STD}, fees={7: 1}, balances={BTC: (1, 0, 0)}),
    'eb_missing_fee': dict(t=1, assets=0, account=8,
        prices={USDC: 100000000, BTC: 1}, indices={BTC: 0}, perps={BTC: STD}, fees={7: 1}, balances={BTC: (1, 0, 0)}),
    'eb_bad_utf8': dict(t=1, assets=0, account=7,
        prices={USDC: 100000000, BTC: 1, 0xff: 1}, indices={BTC: 0}, perps={BTC: STD}, fees={7: 1}, balances={BTC: (1, 0, 0)}),
}
for name, c in cases.items():
    src = f'{out}/{name}.cairo'
    open(src, 'w').write(program(**c))
    subprocess.run([cc, '--cairo_path', cp, src, '--output', f'{out}/{name}.json'], check=True)
