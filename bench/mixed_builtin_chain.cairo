%builtins output pedersen range_check bitwise ec_op poseidon

from starkware.cairo.common.cairo_builtins import HashBuiltin, BitwiseBuiltin, EcOpBuiltin, PoseidonBuiltin
from starkware.cairo.common.builtin_poseidon.poseidon import poseidon_hash
from starkware.cairo.common.ec_point import EcPoint
from starkware.cairo.common.hash import hash2
from starkware.cairo.common.math import split_felt
from starkware.cairo.common.uint256 import split_64
from starkware.cairo.common.bitwise import bitwise_xor

func chain{output_ptr: felt*, hash_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*, ec_op_ptr: EcOpBuiltin*, poseidon_ptr: PoseidonBuiltin*}(x: felt, y: felt, d: felt, n: felt) {
    if (n == 0) {
        assert [output_ptr] = x;
        assert [output_ptr + 1] = y;
        let output_ptr = output_ptr + 2;
        return ();
    }
    let (a) = hash2(2 ** 189 + 31, x);
    let (b) = poseidon_hash(a, y);
    let (high, low) = split_felt(b);
    let (word, carry) = split_64(low);
    let (m) = bitwise_xor(word, carry);
    assert ec_op_ptr.p = EcPoint(
        0x49ee3eba8c1600700ee1b87eb599f16716b0b1022947733551fde4050ca6804,
        0x3ca0cfe4b3bc6ddf346d49d06ea0ed34e621062c0e056c1d0405d266e10268a,
    );
    assert ec_op_ptr.q = EcPoint(
        0x4ba4cc166be8dec764910f75b45f74b40c690c74709e90f3aa372f0bd2d6997,
        0x40301cf5c1751f4b971e46c4ede85fcac5c59a5ce5ae7c48151f27b24b219c,
    );
    assert ec_op_ptr.m = m;
    tempvar qx = ec_op_ptr.r.x;
    let ec_op_ptr = ec_op_ptr + EcOpBuiltin.SIZE;
    return chain((x * y + b) / d, qx + a + high, d, n - 1);
}

func main{output_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*, ec_op_ptr: EcOpBuiltin*, poseidon_ptr: PoseidonBuiltin*}() {
    chain{hash_ptr=pedersen_ptr}(-1, 2 ** 250 + 19, 2 ** 131 + 37, 2048);
    return ();
}
