(* Hint code strings for the secp/EC/bigint/uint384/uint512/vrf/field-arithmetic
   families, byte-exact copies of cairo-vm v3.2.0 hint_code.rs (indoc applied).
   Generated; the cairo0_* codes come from secp/cairo0_hints.rs and are only
   dispatched by Rust with the `cairo-0-secp-hints` feature. *)

let verify_zero_v1 = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP_P, pack

q, r = divmod(pack(ids.val, PRIME), SECP_P)
assert r == 0, f"verify_zero: Invalid input {ids.val.d0, ids.val.d1, ids.val.d2}."
ids.q = q % PRIME|x}
let verify_zero_v2 = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP_P
q, r = divmod(pack(ids.val, PRIME), SECP_P)
assert r == 0, f"verify_zero: Invalid input {ids.val.d0, ids.val.d1, ids.val.d2}."
ids.q = q % PRIME|x}
let verify_zero_v3 = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack
SECP_P = 2**255-19
to_assert = pack(ids.val, PRIME)
q, r = divmod(pack(ids.val, PRIME), SECP_P)
assert r == 0, f"verify_zero: Invalid input {ids.val.d0, ids.val.d1, ids.val.d2}."
ids.q = q % PRIME|x}
let verify_zero_external_secp = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack

q, r = divmod(pack(ids.val, PRIME), SECP_P)
assert r == 0, f"verify_zero: Invalid input {ids.val.d0, ids.val.d1, ids.val.d2}."
ids.q = q % PRIME|x}
let reduce_v1 = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP_P, pack

value = pack(ids.x, PRIME) % SECP_P|x}
let reduce_v2 = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack
value = pack(ids.x, PRIME) % SECP_P|x}
let reduce_ed25519 = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack
SECP_P=2**255-19

value = pack(ids.x, PRIME) % SECP_P|x}
let is_zero_pack_v1 = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP_P, pack

x = pack(ids.x, PRIME) % SECP_P|x}
let is_zero_pack_v2 = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP_P, pack
x = pack(ids.x, PRIME) % SECP_P|x}
let is_zero_pack_external_secp_v1 = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack

x = pack(ids.x, PRIME) % SECP_P|x}
let is_zero_pack_external_secp_v2 = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack
x = pack(ids.x, PRIME) % SECP_P|x}
let is_zero_pack_ed25519 = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack
SECP_P=2**255-19

x = pack(ids.x, PRIME) % SECP_P|x}
let is_zero_nondet = {x|memory[ap] = to_felt_or_relocatable(x == 0)|x}
let is_zero_int = {x|memory[ap] = int(x == 0)|x}
let is_zero_assign_scope_vars = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP_P
from starkware.python.math_utils import div_mod

value = x_inv = div_mod(1, x, SECP_P)|x}
let is_zero_assign_scope_vars_external_secp = {x|from starkware.python.math_utils import div_mod

value = x_inv = div_mod(1, x, SECP_P)|x}
let is_zero_assign_scope_vars_ed25519 = {x|SECP_P=2**255-19
from starkware.python.math_utils import div_mod

value = x_inv = div_mod(1, x, SECP_P)|x}
let nondet_bigint3_v1 = {x|from starkware.cairo.common.cairo_secp.secp_utils import split

segments.write_arg(ids.res.address_, split(value))|x}
let nondet_bigint3_v2 = {x|from starkware.cairo.common.cairo_secp.secp_utils import split
segments.write_arg(ids.res.address_, split(value))|x}
let hi_max_bitlen = {x|ids.len_hi = max(ids.scalar_u.d2.bit_length(), ids.scalar_v.d2.bit_length())-1|x}
let ec_negate = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP_P, pack

y = pack(ids.point.y, PRIME) % SECP_P
# The modulo operation in python always returns a nonnegative number.
value = (-y) % SECP_P|x}
let ec_negate_embedded_secp = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack
SECP_P = 2**255-19

y = pack(ids.point.y, PRIME) % SECP_P
# The modulo operation in python always returns a nonnegative number.
value = (-y) % SECP_P|x}
let ec_double_slope_v1 = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP_P, pack
from starkware.python.math_utils import ec_double_slope

# Compute the slope.
x = pack(ids.point.x, PRIME)
y = pack(ids.point.y, PRIME)
value = slope = ec_double_slope(point=(x, y), alpha=0, p=SECP_P)|x}
let ec_double_slope_v2 = {x|from starkware.python.math_utils import ec_double_slope
from starkware.cairo.common.cairo_secp.secp_utils import pack
SECP_P = 2**255-19

# Compute the slope.
x = pack(ids.point.x, PRIME)
y = pack(ids.point.y, PRIME)
value = slope = ec_double_slope(point=(x, y), alpha=42204101795669822316448953119945047945709099015225996174933988943478124189485, p=SECP_P)|x}
let ec_double_slope_v3 = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP_P, pack
from starkware.python.math_utils import div_mod

# Compute the slope.
x = pack(ids.pt.x, PRIME)
y = pack(ids.pt.y, PRIME)
value = slope = div_mod(3 * x ** 2, 2 * y, SECP_P)|x}
let ec_double_slope_v4 = {x|from starkware.cairo.common.cairo_secp.secp256r1_utils import SECP256R1_ALPHA, SECP256R1_P
from starkware.cairo.common.cairo_secp.secp_utils import pack
from starkware.python.math_utils import ec_double_slope

# Compute the slope.
x = pack(ids.point.x, SECP256R1_P)
y = pack(ids.point.y, SECP256R1_P)
value = slope = ec_double_slope(point=(x, y), alpha=SECP256R1_ALPHA, p=SECP256R1_P)|x}
let ec_double_slope_v5 = {x|from starkware.cairo.common.cairo_secp.secp256r1_utils import SECP256R1_ALPHA, SECP256R1_P
from starkware.cairo.common.cairo_secp.secp_utils import pack
from starkware.python.math_utils import ec_double_slope

# Compute the slope.
x = pack(ids.point.x, PRIME)
y = pack(ids.point.y, PRIME)
value = slope = ec_double_slope(point=(x, y), alpha=SECP256R1_ALPHA, p=SECP256R1_P)|x}
let ec_double_slope_external_consts = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack
from starkware.python.math_utils import ec_double_slope

# Compute the slope.
x = pack(ids.point.x, PRIME)
y = pack(ids.point.y, PRIME)
value = slope = ec_double_slope(point=(x, y), alpha=ALPHA, p=SECP_P)|x}
let compute_slope_v1 = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP_P, pack
from starkware.python.math_utils import line_slope

# Compute the slope.
x0 = pack(ids.point0.x, PRIME)
y0 = pack(ids.point0.y, PRIME)
x1 = pack(ids.point1.x, PRIME)
y1 = pack(ids.point1.y, PRIME)
value = slope = line_slope(point1=(x0, y0), point2=(x1, y1), p=SECP_P)|x}
let compute_slope_v2 = {x|from starkware.python.math_utils import line_slope
from starkware.cairo.common.cairo_secp.secp_utils import pack
SECP_P = 2**255-19
# Compute the slope.
x0 = pack(ids.point0.x, PRIME)
y0 = pack(ids.point0.y, PRIME)
x1 = pack(ids.point1.x, PRIME)
y1 = pack(ids.point1.y, PRIME)
value = slope = line_slope(point1=(x0, y0), point2=(x1, y1), p=SECP_P)|x}
let compute_slope_secp256r1_v1 = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack
from starkware.python.math_utils import line_slope

# Compute the slope.
x0 = pack(ids.point0.x, PRIME)
y0 = pack(ids.point0.y, PRIME)
x1 = pack(ids.point1.x, PRIME)
y1 = pack(ids.point1.y, PRIME)
value = slope = line_slope(point1=(x0, y0), point2=(x1, y1), p=SECP_P)|x}
let compute_slope_secp256r1_v2 = {x|from starkware.cairo.common.cairo_secp.secp256r1_utils import SECP256R1_P
from starkware.cairo.common.cairo_secp.secp_utils import pack
from starkware.python.math_utils import line_slope

# Compute the slope.
x0 = pack(ids.point0.x, PRIME)
y0 = pack(ids.point0.y, PRIME)
x1 = pack(ids.point1.x, PRIME)
y1 = pack(ids.point1.y, PRIME)
value = slope = line_slope(point1=(x0, y0), point2=(x1, y1), p=SECP256R1_P)|x}
let compute_slope_whitelist = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP_P, pack
from starkware.python.math_utils import div_mod

# Compute the slope.
x0 = pack(ids.pt0.x, PRIME)
y0 = pack(ids.pt0.y, PRIME)
x1 = pack(ids.pt1.x, PRIME)
y1 = pack(ids.pt1.y, PRIME)
value = slope = div_mod(y0 - y1, x0 - x1, SECP_P)|x}
let import_secp256r1_p = {x|from starkware.cairo.common.cairo_secp.secp256r1_utils import SECP256R1_P as SECP_P|x}
let import_secp256r1_alpha = {x|from starkware.cairo.common.cairo_secp.secp256r1_utils import SECP256R1_ALPHA as ALPHA|x}
let import_secp256r1_n = {x|from starkware.cairo.common.cairo_secp.secp256r1_utils import SECP256R1_N as N|x}
let square_slope_x_mod_p = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack

slope = pack(ids.slope, PRIME)
x0 = pack(ids.point0.x, PRIME)
x1 = pack(ids.point1.x, PRIME)
y0 = pack(ids.point0.y, PRIME)

value = new_x = (pow(slope, 2, SECP_P) - x0 - x1) % SECP_P|x}
let ec_double_assign_new_x_v1 = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP_P, pack

slope = pack(ids.slope, PRIME)
x = pack(ids.point.x, PRIME)
y = pack(ids.point.y, PRIME)

value = new_x = (pow(slope, 2, SECP_P) - 2 * x) % SECP_P|x}
let ec_double_assign_new_x_v2 = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack

slope = pack(ids.slope, PRIME)
x = pack(ids.point.x, PRIME)
y = pack(ids.point.y, PRIME)

value = new_x = (pow(slope, 2, SECP_P) - 2 * x) % SECP_P|x}
let ec_double_assign_new_x_v3 = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack
SECP_P = 2**255-19

slope = pack(ids.slope, PRIME)
x = pack(ids.point.x, PRIME)
y = pack(ids.point.y, PRIME)

value = new_x = (pow(slope, 2, SECP_P) - 2 * x) % SECP_P|x}
let ec_double_assign_new_x_v4 = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP_P, pack

slope = pack(ids.slope, PRIME)
x = pack(ids.pt.x, PRIME)
y = pack(ids.pt.y, PRIME)

value = new_x = (pow(slope, 2, SECP_P) - 2 * x) % SECP_P|x}
let ec_double_assign_new_y = {x|value = new_y = (slope * (x - new_x) - y) % SECP_P|x}
let fast_ec_add_assign_new_x = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP_P, pack

slope = pack(ids.slope, PRIME)
x0 = pack(ids.point0.x, PRIME)
x1 = pack(ids.point1.x, PRIME)
y0 = pack(ids.point0.y, PRIME)

value = new_x = (pow(slope, 2, SECP_P) - x0 - x1) % SECP_P|x}
let fast_ec_add_assign_new_x_v2 = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack
SECP_P = 2**255-19

slope = pack(ids.slope, PRIME)
x0 = pack(ids.point0.x, PRIME)
x1 = pack(ids.point1.x, PRIME)
y0 = pack(ids.point0.y, PRIME)

value = new_x = (pow(slope, 2, SECP_P) - x0 - x1) % SECP_P|x}
let fast_ec_add_assign_new_x_v3 = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP_P, pack

slope = pack(ids.slope, PRIME)
x0 = pack(ids.pt0.x, PRIME)
x1 = pack(ids.pt1.x, PRIME)
y0 = pack(ids.pt0.y, PRIME)

value = new_x = (pow(slope, 2, SECP_P) - x0 - x1) % SECP_P|x}
let fast_ec_add_assign_new_y = {x|value = new_y = (slope * (x0 - new_x) - y0) % SECP_P|x}
let quad_bit = {x|ids.quad_bit = (
    8 * ((ids.scalar_v >> ids.m) & 1)
    + 4 * ((ids.scalar_u >> ids.m) & 1)
    + 2 * ((ids.scalar_v >> (ids.m - 1)) & 1)
    + ((ids.scalar_u >> (ids.m - 1)) & 1)
)|x}
let di_bit = {x|ids.dibit = ((ids.scalar_u >> ids.m) & 1) + 2 * ((ids.scalar_v >> ids.m) & 1)|x}
let div_mod_n_packed_divmod_v1 = {x|from starkware.cairo.common.cairo_secp.secp_utils import N, pack
from starkware.python.math_utils import div_mod, safe_div

a = pack(ids.a, PRIME)
b = pack(ids.b, PRIME)
value = res = div_mod(a, b, N)|x}
let div_mod_n_packed_divmod_external_n = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack
from starkware.python.math_utils import div_mod, safe_div

a = pack(ids.a, PRIME)
b = pack(ids.b, PRIME)
value = res = div_mod(a, b, N)|x}
let div_mod_n_safe_div = {x|value = k = safe_div(res * b - a, N)|x}
let div_mod_n_safe_div_plus_one = {x|value = k_plus_one = safe_div(res * b - a, N) + 1|x}
let xs_safe_div = {x|value = k = safe_div(res * s - x, N)|x}
let get_point_from_x = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP_P, pack

x_cube_int = pack(ids.x_cube, PRIME) % SECP_P
y_square_int = (x_cube_int + ids.BETA) % SECP_P
y = pow(y_square_int, (SECP_P + 1) // 4, SECP_P)

# We need to decide whether to take y or SECP_P - y.
if ids.v % 2 == y % 2:
    value = y
else:
    value = (-y) % SECP_P|x}
let pack_modn_div_modn = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack
from starkware.python.math_utils import div_mod, safe_div

N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141
x = pack(ids.x, PRIME) % N
s = pack(ids.s, PRIME) % N
value = res = div_mod(x, s, N)|x}
let bigint_pack_div_mod = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack
from starkware.cairo.common.math_utils import as_int
from starkware.python.math_utils import div_mod, safe_div

p = pack(ids.P, PRIME)
x = pack(ids.x, PRIME) + as_int(ids.x.d3, PRIME) * ids.BASE ** 3 + as_int(ids.x.d4, PRIME) * ids.BASE ** 4
y = pack(ids.y, PRIME)

value = res = div_mod(x, y, p)|x}
let bigint_safe_div = {x|k = safe_div(res * y - x, p)
value = k if k > 0 else 0 - k
ids.flag = 1 if k > 0 else 0|x}
let ec_recover_div_mod_n_packed = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack
from starkware.python.math_utils import div_mod, safe_div

N = pack(ids.n, PRIME)
x = pack(ids.x, PRIME) % N
s = pack(ids.s, PRIME) % N
value = res = div_mod(x, s, N)|x}
let ec_recover_sub_a_b = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack
from starkware.python.math_utils import div_mod, safe_div

a = pack(ids.a, PRIME)
b = pack(ids.b, PRIME)

value = res = a - b|x}
let ec_recover_product_mod = {x|from starkware.cairo.common.cairo_secp.secp_utils import pack
from starkware.python.math_utils import div_mod, safe_div

a = pack(ids.a, PRIME)
b = pack(ids.b, PRIME)
product = a * b
m = pack(ids.m, PRIME)

value = res = product % m|x}
let ec_recover_product_div_m = {x|value = k = product // m|x}
let random_ec_point = {x|from starkware.crypto.signature.signature import ALPHA, BETA, FIELD_PRIME
from starkware.python.math_utils import random_ec_point
from starkware.python.utils import to_bytes

# Define a seed for random_ec_point that's dependent on all the input, so that:
#   (1) The added point s is deterministic.
#   (2) It's hard to choose inputs for which the builtin will fail.
seed = b"".join(map(to_bytes, [ids.p.x, ids.p.y, ids.m, ids.q.x, ids.q.y]))
ids.s.x, ids.s.y = random_ec_point(FIELD_PRIME, ALPHA, BETA, seed)|x}
let chained_ec_op_random_ec_point = {x|from starkware.crypto.signature.signature import ALPHA, BETA, FIELD_PRIME
from starkware.python.math_utils import random_ec_point
from starkware.python.utils import to_bytes

n_elms = ids.len
assert isinstance(n_elms, int) and n_elms >= 0, \
    f'Invalid value for len. Got: {n_elms}.'
if '__chained_ec_op_max_len' in globals():
    assert n_elms <= __chained_ec_op_max_len, \
        f'chained_ec_op() can only be used with len<={__chained_ec_op_max_len}. ' \
        f'Got: n_elms={n_elms}.'

# Define a seed for random_ec_point that's dependent on all the input, so that:
#   (1) The added point s is deterministic.
#   (2) It's hard to choose inputs for which the builtin will fail.
seed = b"".join(
    map(
        to_bytes,
        [
            ids.p.x,
            ids.p.y,
            *memory.get_range(ids.m, n_elms),
            *memory.get_range(ids.q.address_, 2 * n_elms),
        ],
    )
)
ids.s.x, ids.s.y = random_ec_point(FIELD_PRIME, ALPHA, BETA, seed)|x}
let recover_y = {x|from starkware.crypto.signature.signature import ALPHA, BETA, FIELD_PRIME
from starkware.python.math_utils import recover_y
ids.p.x = ids.x
# This raises an exception if `x` is not on the curve.
ids.p.y = recover_y(ids.x, ALPHA, BETA, FIELD_PRIME)|x}
let uint384_get_square_root = {x|from starkware.python.math_utils import is_quad_residue, sqrt

def split(num: int, num_bits_shift: int = 128, length: int = 3):
    a = []
    for _ in range(length):
        a.append( num & ((1 << num_bits_shift) - 1) )
        num = num >> num_bits_shift
    return tuple(a)

def pack(z, num_bits_shift: int = 128) -> int:
    limbs = (z.d0, z.d1, z.d2)
    return sum(limb << (num_bits_shift * i) for i, limb in enumerate(limbs))


generator = pack(ids.generator)
x = pack(ids.x)
p = pack(ids.p)

success_x = is_quad_residue(x, p)
root_x = sqrt(x, p) if success_x else None

success_gx = is_quad_residue(generator*x, p)
root_gx = sqrt(generator*x, p) if success_gx else None

# Check that one is 0 and the other is 1
if x != 0:
    assert success_x + success_gx ==1

# `None` means that no root was found, but we need to transform these into a felt no matter what
if root_x == None:
    root_x = 0
if root_gx == None:
    root_gx = 0
ids.success_x = int(success_x)
ids.success_gx = int(success_gx)
split_root_x = split(root_x)
split_root_gx = split(root_gx)
ids.sqrt_x.d0 = split_root_x[0]
ids.sqrt_x.d1 = split_root_x[1]
ids.sqrt_x.d2 = split_root_x[2]
ids.sqrt_gx.d0 = split_root_gx[0]
ids.sqrt_gx.d1 = split_root_gx[1]
ids.sqrt_gx.d2 = split_root_gx[2]|x}
let uint256_get_square_root = {x|from starkware.python.math_utils import is_quad_residue, sqrt

def split(a: int):
    return (a & ((1 << 128) - 1), a >> 128)

def pack(z) -> int:
    return z.low + (z.high << 128)

generator = pack(ids.generator)
x = pack(ids.x)
p = pack(ids.p)

success_x = is_quad_residue(x, p)
root_x = sqrt(x, p) if success_x else None
success_gx = is_quad_residue(generator*x, p)
root_gx = sqrt(generator*x, p) if success_gx else None

# Check that one is 0 and the other is 1
if x != 0:
    assert success_x + success_gx == 1

# `None` means that no root was found, but we need to transform these into a felt no matter what
if root_x == None:
    root_x = 0
if root_gx == None:
    root_gx = 0
ids.success_x = int(success_x)
ids.success_gx = int(success_gx)
split_root_x = split(root_x)
# print('split root x', split_root_x)
split_root_gx = split(root_gx)
ids.sqrt_x.low = split_root_x[0]
ids.sqrt_x.high = split_root_x[1]
ids.sqrt_gx.low = split_root_gx[0]
ids.sqrt_gx.high = split_root_gx[1]|x}
let uint384_div = {x|from starkware.python.math_utils import div_mod

def split(num: int, num_bits_shift: int, length: int):
    a = []
    for _ in range(length):
        a.append( num & ((1 << num_bits_shift) - 1) )
        num = num >> num_bits_shift
    return tuple(a)

def pack(z, num_bits_shift: int) -> int:
    limbs = (z.d0, z.d1, z.d2)
    return sum(limb << (num_bits_shift * i) for i, limb in enumerate(limbs))

a = pack(ids.a, num_bits_shift = 128)
b = pack(ids.b, num_bits_shift = 128)
p = pack(ids.p, num_bits_shift = 128)
# For python3.8 and above the modular inverse can be computed as follows:
# b_inverse_mod_p = pow(b, -1, p)
# Instead we use the python3.7-friendly function div_mod from starkware.python.math_utils
b_inverse_mod_p = div_mod(1, b, p)


b_inverse_mod_p_split = split(b_inverse_mod_p, num_bits_shift=128, length=3)

ids.b_inverse_mod_p.d0 = b_inverse_mod_p_split[0]
ids.b_inverse_mod_p.d1 = b_inverse_mod_p_split[1]
ids.b_inverse_mod_p.d2 = b_inverse_mod_p_split[2]|x}
let get_felt_bit_length = {x|x = ids.x
ids.bit_length = x.bit_length()|x}
let uint384_unsigned_div_rem = {x|def split(num: int, num_bits_shift: int, length: int):
    a = []
    for _ in range(length):
        a.append( num & ((1 << num_bits_shift) - 1) )
        num = num >> num_bits_shift
    return tuple(a)

def pack(z, num_bits_shift: int) -> int:
    limbs = (z.d0, z.d1, z.d2)
    return sum(limb << (num_bits_shift * i) for i, limb in enumerate(limbs))

a = pack(ids.a, num_bits_shift = 128)
div = pack(ids.div, num_bits_shift = 128)
quotient, remainder = divmod(a, div)

quotient_split = split(quotient, num_bits_shift=128, length=3)
assert len(quotient_split) == 3

ids.quotient.d0 = quotient_split[0]
ids.quotient.d1 = quotient_split[1]
ids.quotient.d2 = quotient_split[2]

remainder_split = split(remainder, num_bits_shift=128, length=3)
ids.remainder.d0 = remainder_split[0]
ids.remainder.d1 = remainder_split[1]
ids.remainder.d2 = remainder_split[2]|x}
let uint384_split_128 = {x|ids.low = ids.a & ((1<<128) - 1)
ids.high = ids.a >> 128|x}
let add_no_uint384_check = {x|sum_d0 = ids.a.d0 + ids.b.d0
ids.carry_d0 = 1 if sum_d0 >= ids.SHIFT else 0
sum_d1 = ids.a.d1 + ids.b.d1 + ids.carry_d0
ids.carry_d1 = 1 if sum_d1 >= ids.SHIFT else 0
sum_d2 = ids.a.d2 + ids.b.d2 + ids.carry_d1
ids.carry_d2 = 1 if sum_d2 >= ids.SHIFT else 0|x}
let uint384_sqrt = {x|from starkware.python.math_utils import isqrt

def split(num: int, num_bits_shift: int, length: int):
    a = []
    for _ in range(length):
        a.append( num & ((1 << num_bits_shift) - 1) )
        num = num >> num_bits_shift
    return tuple(a)

def pack(z, num_bits_shift: int) -> int:
    limbs = (z.d0, z.d1, z.d2)
    return sum(limb << (num_bits_shift * i) for i, limb in enumerate(limbs))

a = pack(ids.a, num_bits_shift=128)
root = isqrt(a)
assert 0 <= root < 2 ** 192
root_split = split(root, num_bits_shift=128, length=3)
ids.root.d0 = root_split[0]
ids.root.d1 = root_split[1]
ids.root.d2 = root_split[2]|x}
let sub_reduced_a_and_reduced_b = {x|def split(num: int, num_bits_shift: int, length: int):
    a = []
    for _ in range(length):
        a.append( num & ((1 << num_bits_shift) - 1) )
        num = num >> num_bits_shift
    return tuple(a)

def pack(z, num_bits_shift: int) -> int:
    limbs = (z.d0, z.d1, z.d2)
    return sum(limb << (num_bits_shift * i) for i, limb in enumerate(limbs))

a = pack(ids.a, num_bits_shift = 128)
b = pack(ids.b, num_bits_shift = 128)
p = pack(ids.p, num_bits_shift = 128)

res = (a - b) % p


res_split = split(res, num_bits_shift=128, length=3)

ids.res.d0 = res_split[0]
ids.res.d1 = res_split[1]
ids.res.d2 = res_split[2]|x}
let uint384_signed_nn = {x|memory[ap] = 1 if 0 <= (ids.a.d2 % PRIME) < 2 ** 127 else 0|x}
let unsigned_div_rem_uint768_by_uint384 = {x|def split(num: int, num_bits_shift: int, length: int):
    a = []
    for _ in range(length):
        a.append( num & ((1 << num_bits_shift) - 1) )
        num = num >> num_bits_shift 
    return tuple(a)

def pack(z, num_bits_shift: int) -> int:
    limbs = (z.d0, z.d1, z.d2)
    return sum(limb << (num_bits_shift * i) for i, limb in enumerate(limbs))
    
def pack_extended(z, num_bits_shift: int) -> int:
    limbs = (z.d0, z.d1, z.d2, z.d3, z.d4, z.d5)
    return sum(limb << (num_bits_shift * i) for i, limb in enumerate(limbs))

a = pack_extended(ids.a, num_bits_shift = 128)
div = pack(ids.div, num_bits_shift = 128)

quotient, remainder = divmod(a, div)

quotient_split = split(quotient, num_bits_shift=128, length=6)

ids.quotient.d0 = quotient_split[0]
ids.quotient.d1 = quotient_split[1]
ids.quotient.d2 = quotient_split[2]
ids.quotient.d3 = quotient_split[3]
ids.quotient.d4 = quotient_split[4]
ids.quotient.d5 = quotient_split[5]

remainder_split = split(remainder, num_bits_shift=128, length=3)
ids.remainder.d0 = remainder_split[0]
ids.remainder.d1 = remainder_split[1]
ids.remainder.d2 = remainder_split[2]|x}
let unsigned_div_rem_uint768_by_uint384_stripped = {x|def split(num: int, num_bits_shift: int, length: int):
    a = []
    for _ in range(length):
        a.append( num & ((1 << num_bits_shift) - 1) )
        num = num >> num_bits_shift
    return tuple(a)

def pack(z, num_bits_shift: int) -> int:
    limbs = (z.d0, z.d1, z.d2)
    return sum(limb << (num_bits_shift * i) for i, limb in enumerate(limbs))

def pack_extended(z, num_bits_shift: int) -> int:
    limbs = (z.d0, z.d1, z.d2, z.d3, z.d4, z.d5)
    return sum(limb << (num_bits_shift * i) for i, limb in enumerate(limbs))

a = pack_extended(ids.a, num_bits_shift = 128)
div = pack(ids.div, num_bits_shift = 128)

quotient, remainder = divmod(a, div)

quotient_split = split(quotient, num_bits_shift=128, length=6)

ids.quotient.d0 = quotient_split[0]
ids.quotient.d1 = quotient_split[1]
ids.quotient.d2 = quotient_split[2]
ids.quotient.d3 = quotient_split[3]
ids.quotient.d4 = quotient_split[4]
ids.quotient.d5 = quotient_split[5]

remainder_split = split(remainder, num_bits_shift=128, length=3)
ids.remainder.d0 = remainder_split[0]
ids.remainder.d1 = remainder_split[1]
ids.remainder.d2 = remainder_split[2]|x}
let uint512_unsigned_div_rem = {x|def split(num: int, num_bits_shift: int, length: int):
    a = []
    for _ in range(length):
        a.append( num & ((1 << num_bits_shift) - 1) )
        num = num >> num_bits_shift
    return tuple(a)

def pack(z, num_bits_shift: int) -> int:
    limbs = (z.low, z.high)
    return sum(limb << (num_bits_shift * i) for i, limb in enumerate(limbs))

def pack_extended(z, num_bits_shift: int) -> int:
    limbs = (z.d0, z.d1, z.d2, z.d3)
    return sum(limb << (num_bits_shift * i) for i, limb in enumerate(limbs))

x = pack_extended(ids.x, num_bits_shift = 128)
div = pack(ids.div, num_bits_shift = 128)

quotient, remainder = divmod(x, div)

quotient_split = split(quotient, num_bits_shift=128, length=4)

ids.quotient.d0 = quotient_split[0]
ids.quotient.d1 = quotient_split[1]
ids.quotient.d2 = quotient_split[2]
ids.quotient.d3 = quotient_split[3]

remainder_split = split(remainder, num_bits_shift=128, length=2)
ids.remainder.low = remainder_split[0]
ids.remainder.high = remainder_split[1]|x}
let inv_mod_p_uint256 = {x|from starkware.python.math_utils import div_mod

def split(a: int):
    return (a & ((1 << 128) - 1), a >> 128)

def pack(z, num_bits_shift: int) -> int:
    limbs = (z.low, z.high)
    return sum(limb << (num_bits_shift * i) for i, limb in enumerate(limbs))

a = pack(ids.a, 128)
b = pack(ids.b, 128)
p = pack(ids.p, 128)
# For python3.8 and above the modular inverse can be computed as follows:
# b_inverse_mod_p = pow(b, -1, p)
# Instead we use the python3.7-friendly function div_mod from starkware.python.math_utils
b_inverse_mod_p = div_mod(1, b, p)

b_inverse_mod_p_split = split(b_inverse_mod_p)

ids.b_inverse_mod_p.low = b_inverse_mod_p_split[0]
ids.b_inverse_mod_p.high = b_inverse_mod_p_split[1]|x}
let inv_mod_p_uint512 = {x|def pack_512(u, num_bits_shift: int) -> int:
    limbs = (u.d0, u.d1, u.d2, u.d3)
    return sum(limb << (num_bits_shift * i) for i, limb in enumerate(limbs))

x = pack_512(ids.x, num_bits_shift = 128)
p = ids.p.low + (ids.p.high << 128)
x_inverse_mod_p = pow(x,-1, p)

x_inverse_mod_p_split = (x_inverse_mod_p & ((1 << 128) - 1), x_inverse_mod_p >> 128)

ids.x_inverse_mod_p.low = x_inverse_mod_p_split[0]
ids.x_inverse_mod_p.high = x_inverse_mod_p_split[1]|x}
let is_quad_residue = {x|from starkware.crypto.signature.signature import FIELD_PRIME
from starkware.python.math_utils import div_mod, is_quad_residue, sqrt

x = ids.x
if is_quad_residue(x, FIELD_PRIME):
    ids.y = sqrt(x, FIELD_PRIME)
else:
    ids.y = sqrt(div_mod(x, 3, FIELD_PRIME), FIELD_PRIME)|x}
let split_xx = {x|PRIME = 2**255 - 19
II = pow(2, (PRIME - 1) // 4, PRIME)

xx = ids.xx.low + (ids.xx.high<<128)
x = pow(xx, (PRIME + 3) // 8, PRIME)
if (x * x - xx) % PRIME != 0:
    x = (x * II) % PRIME
if x % 2 != 0:
    x = PRIME - x
ids.x.low = x & ((1<<128)-1)
ids.x.high = x >> 128|x}
let cairo0_secp_reduce = {x|from starkware.cairo.common.cairo_secp.secp256r1_utils import SECP256R1_P
from starkware.cairo.common.cairo_secp.secp_utils import pack
value = pack(ids.x, PRIME) % SECP256R1_P|x}
let cairo0_secp_reduce_x = {x|from starkware.cairo.common.cairo_secp.secp256r1_utils import SECP256R1_P
from starkware.cairo.common.cairo_secp.secp_utils import pack

x = pack(ids.x, PRIME) % SECP256R1_P|x}
let cairo0_compute_q_mod_prime = {x|from starkware.cairo.common.cairo_secp.secp256r1_utils import SECP256R1_P
from starkware.cairo.common.cairo_secp.secp_utils import pack

q, r = divmod(pack(ids.val, PRIME), SECP256R1_P)
assert r == 0, f"verify_zero: Invalid input {ids.val.d0, ids.val.d1, ids.val.d2}."
ids.q = q % PRIME|x}
let cairo0_compute_ids_high_low = {x|from starkware.cairo.common.math_utils import as_int

# Correctness check.
value = as_int(ids.value, PRIME) % PRIME
assert value < ids.UPPER_BOUND, f'{value} is outside of the range [0, 2**165).'

# Calculation for the assertion.
ids.high, ids.low = divmod(ids.value, ids.SHIFT)|x}
let cairo0_secp_r1_get_point_from_x = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP256R1, pack
from starkware.python.math_utils import y_squared_from_x

y_square_int = y_squared_from_x(
    x=pack(ids.x, SECP256R1.prime),
    alpha=SECP256R1.alpha,
    beta=SECP256R1.beta,
    field_prime=SECP256R1.prime,
)

# Note that (y_square_int ** ((SECP256R1.prime + 1) / 4)) ** 2 =
#   = y_square_int ** ((SECP256R1.prime + 1) / 2) =
#   = y_square_int ** ((SECP256R1.prime - 1) / 2 + 1) =
#   = y_square_int * y_square_int ** ((SECP256R1.prime - 1) / 2) = y_square_int * {+/-}1.
y = pow(y_square_int, (SECP256R1.prime + 1) // 4, SECP256R1.prime)

# We need to decide whether to take y or prime - y.
if ids.v % 2 == y % 2:
    value = y
else:
    value = (-y) % SECP256R1.prime|x}
let cairo0_secp_r1_get_point_from_x_v2 = {x|from starkware.cairo.common.cairo_secp.secp_utils import SECP256R1, pack
from starkware.python.math_utils import y_squared_from_x

y_square_int = y_squared_from_x(
    x=pack(ids.x, PRIME),
    alpha=SECP256R1.alpha,
    beta=SECP256R1.beta,
    field_prime=SECP256R1.prime,
)

# Note that (y_square_int ** ((SECP256R1.prime + 1) / 4)) ** 2 =
#   = y_square_int ** ((SECP256R1.prime + 1) / 2) =
#   = y_square_int ** ((SECP256R1.prime - 1) / 2 + 1) =
#   = y_square_int * y_square_int ** ((SECP256R1.prime - 1) / 2) = y_square_int * {+/-}1.
y = pow(y_square_int, (SECP256R1.prime + 1) // 4, SECP256R1.prime)

# We need to decide whether to take y or prime - y.
if ids.v % 2 == y % 2:
    value = y
else:
    value = (-y) % SECP256R1.prime|x}
let cairo0_is_on_curve_2 = {x|ids.is_on_curve = (y * y) % SECP256R1.prime == y_square_int|x}
let cairo0_secp_double_assign_new_x = {x|from starkware.cairo.common.cairo_secp.secp256r1_utils import SECP256R1_P
from starkware.cairo.common.cairo_secp.secp_utils import pack

slope = pack(ids.slope, SECP256R1_P)
x = pack(ids.point.x, SECP256R1_P)
y = pack(ids.point.y, SECP256R1_P)

value = new_x = (pow(slope, 2, SECP256R1_P) - 2 * x) % SECP256R1_P|x}
let cairo0_secp_double_assign_new_x_v2 = {x|from starkware.cairo.common.cairo_secp.secp256r1_utils import SECP256R1_P
from starkware.cairo.common.cairo_secp.secp_utils import pack

slope = pack(ids.slope, PRIME)
x = pack(ids.point.x, PRIME)
y = pack(ids.point.y, PRIME)

value = new_x = (pow(slope, 2, SECP256R1_P) - 2 * x) % SECP256R1_P|x}
let cairo0_generate_nibbles = {x|num = (ids.scalar.high << 128) + ids.scalar.low
nibbles = [(num >> i) & 0xf for i in range(0, 256, 4)]
ids.first_nibble = nibbles.pop()
ids.last_nibble = nibbles[0]|x}
let cairo0_fast_secp_add_assign_new_y = {x|value = new_y = (slope * (x - new_x) - y) % SECP256R1_P|x}
let cairo0_write_nibbles_to_mem = {x|memory[fp + 0] = to_felt_or_relocatable(nibbles.pop())|x}
let cairo0_compute_value_div_mod = {x|from starkware.python.math_utils import div_mod

value = div_mod(1, x, SECP256R1_P)|x}
