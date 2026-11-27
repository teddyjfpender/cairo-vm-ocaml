(* Hint code strings, byte-exact copies of cairo-vm v3.2.0 hint_code.rs (generated). *)
let assert_le_felt_v_0_6 = {rs|from starkware.cairo.common.math_utils import assert_integer
assert_integer(ids.a)
assert_integer(ids.b)
assert (ids.a % PRIME) <= (ids.b % PRIME), \
    f'a = {ids.a % PRIME} is not less than or equal to b = {ids.b % PRIME}.'|rs}
let assert_le_felt_v_0_8 = {rs|from starkware.cairo.common.math_utils import assert_integer
assert_integer(ids.a)
assert_integer(ids.b)
a = ids.a % PRIME
b = ids.b % PRIME
assert a <= b, f'a = {a} is not less than or equal to b = {b}.'

ids.small_inputs = int(
    a < range_check_builtin.bound and (b - a) < range_check_builtin.bound)|rs}
let is_250_bits = {rs|ids.is_250 = 1 if ids.addr < 2**250 else 0|rs}
let is_addr_bounded = {rs|# Verify the assumptions on the relationship between 2**250, ADDR_BOUND and PRIME.
ADDR_BOUND = ids.ADDR_BOUND % PRIME
assert (2**250 < ADDR_BOUND <= 2**251) and (2 * 2**250 < PRIME) and (
        ADDR_BOUND * 2 > PRIME), \
    'normalize_address() cannot be used with the current constants.'
ids.is_small = 1 if ids.addr < ADDR_BOUND else 0|rs}
let sqrt = {rs|from starkware.python.math_utils import isqrt
value = ids.value % PRIME
assert value < 2 ** 250, f"value={value} is outside of the range [0, 2**250)."
assert 2 ** 250 < PRIME
ids.root = isqrt(value)|rs}
let a_b_bitand_1 = {rs|ids.a_lsb = ids.a & 1
ids.b_lsb = ids.b & 1|rs}
let nondet_n_greater_than_10 = {rs|memory[ap] = to_felt_or_relocatable(ids.n >= 10)|rs}
let nondet_n_greater_than_2 = {rs|memory[ap] = to_felt_or_relocatable(ids.n >= 2)|rs}
let uint256_add_low = {rs|sum_low = ids.a.low + ids.b.low
ids.carry_low = 1 if sum_low >= ids.SHIFT else 0|rs}
let uint128_add = {rs|res = ids.a + ids.b
ids.carry = 1 if res >= ids.SHIFT else 0|rs}
let uint256_sub = {rs|def split(num: int, num_bits_shift: int = 128, length: int = 2):
    a = []
    for _ in range(length):
        a.append( num & ((1 << num_bits_shift) - 1) )
        num = num >> num_bits_shift
    return tuple(a)

def pack(z, num_bits_shift: int = 128) -> int:
    limbs = (z.low, z.high)
    return sum(limb << (num_bits_shift * i) for i, limb in enumerate(limbs))

a = pack(ids.a)
b = pack(ids.b)
res = (a - b)%2**256
res_split = split(res)
ids.res.low = res_split[0]
ids.res.high = res_split[1]|rs}
let uint256_sqrt_felt = {rs|from starkware.python.math_utils import isqrt
n = (ids.n.high << 128) + ids.n.low
root = isqrt(n)
assert 0 <= root < 2 ** 128
ids.root = root|rs}
let uint256_expanded_unsigned_div_rem = {rs|a = (ids.a.high << 128) + ids.a.low
div = (ids.div.b23 << 128) + ids.div.b01
quotient, remainder = divmod(a, div)

ids.quotient.low = quotient & ((1 << 128) - 1)
ids.quotient.high = quotient >> 128
ids.remainder.low = remainder & ((1 << 128) - 1)
ids.remainder.high = remainder >> 128|rs}
let blake2s_finalize_v2 = {rs|# Add dummy pairs of input and output.
from starkware.cairo.common.cairo_blake2s.blake2s_utils import IV, blake2s_compress

_n_packed_instances = int(ids.N_PACKED_INSTANCES)
assert 0 <= _n_packed_instances < 20
_blake2s_input_chunk_size_felts = int(ids.BLAKE2S_INPUT_CHUNK_SIZE_FELTS)
assert 0 <= _blake2s_input_chunk_size_felts < 100

message = [0] * _blake2s_input_chunk_size_felts
modified_iv = [IV[0] ^ 0x01010020] + IV[1:]
output = blake2s_compress(
    message=message,
    h=modified_iv,
    t0=0,
    t1=0,
    f0=0xffffffff,
    f1=0,
)
padding = (modified_iv + message + [0, 0xffffffff] + output) * (_n_packed_instances - 1)
segments.write_arg(ids.blake2s_ptr_end, padding)|rs}
let blake2s_finalize_v3 = {rs|# Add dummy pairs of input and output.
from starkware.cairo.common.cairo_blake2s.blake2s_utils import IV, blake2s_compress

_n_packed_instances = int(ids.N_PACKED_INSTANCES)
assert 0 <= _n_packed_instances < 20
_blake2s_input_chunk_size_felts = int(ids.BLAKE2S_INPUT_CHUNK_SIZE_FELTS)
assert 0 <= _blake2s_input_chunk_size_felts < 100

message = [0] * _blake2s_input_chunk_size_felts
modified_iv = [IV[0] ^ 0x01010020] + IV[1:]
output = blake2s_compress(
    message=message,
    h=modified_iv,
    t0=0,
    t1=0,
    f0=0xffffffff,
    f1=0,
)
padding = (message + modified_iv + [0, 0xffffffff] + output) * (_n_packed_instances - 1)
segments.write_arg(ids.blake2s_ptr_end, padding)|rs}
let is_less_than_63_bits_and_not_end = {rs|memory[ap] = to_felt_or_relocatable((ids.end != ids.packed_values) and (memory[ids.packed_values] < 2**63))|rs}
let blake2s_unpack_felts = {rs|offset = 0
for i in range(ids.packed_values_len):
    val = (memory[ids.packed_values + i] % PRIME)
    val_len = 2 if val < 2**63 else 8
    if val_len == 8:
        val += 2**255
    for i in range(val_len - 1, -1, -1):
        val, memory[ids.unpacked_u32s + offset + i] = divmod(val, 2**32)
    assert val == 0
    offset += val_len|rs}
let example_blake2s_compress = {rs|from starkware.cairo.common.cairo_blake2s.blake2s_utils import IV, blake2s_compress

_blake2s_input_chunk_size_felts = int(ids.BLAKE2S_INPUT_CHUNK_SIZE_FELTS)
assert 0 <= _blake2s_input_chunk_size_felts < 100

new_state = blake2s_compress(
    message=memory.get_range(ids.blake2s_start, _blake2s_input_chunk_size_felts),
    h=[IV[0] ^ 0x01010020] + IV[1:],
    t0=ids.n_bytes,
    t1=0,
    f0=0xffffffff,
    f1=0,
)

segments.write_arg(ids.output, new_state)|rs}
let sha256_input = {rs|ids.full_word = int(ids.n_bytes >= 4)|rs}
let sha256_main_constant_input_length = {rs|from starkware.cairo.common.cairo_sha256.sha256_utils import (
    IV, compute_message_schedule, sha2_compress_function)

_sha256_input_chunk_size_felts = int(ids.SHA256_INPUT_CHUNK_SIZE_FELTS)
assert 0 <= _sha256_input_chunk_size_felts < 100

w = compute_message_schedule(memory.get_range(
    ids.sha256_start, _sha256_input_chunk_size_felts))
new_state = sha2_compress_function(IV, w)
segments.write_arg(ids.output, new_state)|rs}
let sha256_main_arbitrary_input_length = {rs|from starkware.cairo.common.cairo_sha256.sha256_utils import (
    compute_message_schedule, sha2_compress_function)

_sha256_input_chunk_size_felts = int(ids.SHA256_INPUT_CHUNK_SIZE_FELTS)
assert 0 <= _sha256_input_chunk_size_felts < 100
_sha256_state_size_felts = int(ids.SHA256_STATE_SIZE_FELTS)
assert 0 <= _sha256_state_size_felts < 100
w = compute_message_schedule(memory.get_range(
    ids.sha256_start, _sha256_input_chunk_size_felts))
new_state = sha2_compress_function(memory.get_range(ids.state, _sha256_state_size_felts), w)
segments.write_arg(ids.output, new_state)|rs}
let sha256_finalize = {rs|# Add dummy pairs of input and output.
from starkware.cairo.common.cairo_sha256.sha256_utils import (
    IV, compute_message_schedule, sha2_compress_function)

_block_size = int(ids.BLOCK_SIZE)
assert 0 <= _block_size < 20
_sha256_input_chunk_size_felts = int(ids.SHA256_INPUT_CHUNK_SIZE_FELTS)
assert 0 <= _sha256_input_chunk_size_felts < 100

message = [0] * _sha256_input_chunk_size_felts
w = compute_message_schedule(message)
output = sha2_compress_function(IV, w)
padding = (message + IV + output) * (_block_size - 1)
segments.write_arg(ids.sha256_ptr_end, padding)|rs}
let block_permutation_whitelist_v1 = {rs|from starkware.cairo.common.cairo_keccak.keccak_utils import keccak_func
_keccak_state_size_felts = int(ids.KECCAK_STATE_SIZE_FELTS)
assert 0 <= _keccak_state_size_felts < 100

output_values = keccak_func(memory.get_range(
    ids.keccak_ptr - _keccak_state_size_felts, _keccak_state_size_felts))
segments.write_arg(ids.keccak_ptr, output_values)|rs}
let block_permutation_whitelist_v2 = {rs|from starkware.cairo.common.cairo_keccak.keccak_utils import keccak_func
_keccak_state_size_felts = int(ids.KECCAK_STATE_SIZE_FELTS)
assert 0 <= _keccak_state_size_felts < 100
output_values = keccak_func(memory.get_range(
    ids.keccak_ptr_start, _keccak_state_size_felts))
segments.write_arg(ids.output, output_values)|rs}
let cairo_keccak_input_is_full_word = {rs|ids.full_word = int(ids.n_bytes >= 8)|rs}
let cairo_keccak_finalize_v2 = {rs|# Add dummy pairs of input and output.
_keccak_state_size_felts = int(ids.KECCAK_STATE_SIZE_FELTS)
_block_size = int(ids.BLOCK_SIZE)
assert 0 <= _keccak_state_size_felts < 100
assert 0 <= _block_size < 1000
inp = [0] * _keccak_state_size_felts
padding = (inp + keccak_func(inp)) * _block_size
segments.write_arg(ids.keccak_ptr_end, padding)|rs}
let split_output_0 = {rs|ids.output0_low = ids.output0 & ((1 << 128) - 1)
ids.output0_high = ids.output0 >> 128|rs}
let split_output_1 = {rs|ids.output1_low = ids.output1 & ((1 << 128) - 1)
ids.output1_high = ids.output1 >> 128|rs}
let split_input_3 = {rs|ids.high3, ids.low3 = divmod(memory[ids.inputs + 3], 256)|rs}
let split_input_6 = {rs|ids.high6, ids.low6 = divmod(memory[ids.inputs + 6], 256 ** 2)|rs}
let split_input_9 = {rs|ids.high9, ids.low9 = divmod(memory[ids.inputs + 9], 256 ** 3)|rs}
let split_input_12 = {rs|ids.high12, ids.low12 = divmod(memory[ids.inputs + 12], 256 ** 4)|rs}
let split_input_15 = {rs|ids.high15, ids.low15 = divmod(memory[ids.inputs + 15], 256 ** 5)|rs}
let split_n_bytes = {rs|ids.n_words_to_copy, ids.n_bytes_left = divmod(ids.n_bytes, ids.BYTES_IN_WORD)|rs}
let split_output_mid_low_high = {rs|tmp, ids.output1_low = divmod(ids.output1, 256 ** 7)
ids.output1_high, ids.output1_mid = divmod(tmp, 2 ** 128)|rs}
let relocate_segment = {rs|memory.add_relocation_rule(src_ptr=ids.src_ptr, dest_ptr=ids.dest_ptr)|rs}
let temporary_array = {rs|ids.temporary_array = segments.add_temp_segment()|rs}
