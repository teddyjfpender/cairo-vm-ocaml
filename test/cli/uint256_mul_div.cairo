%builtins range_check

from starkware.cairo.common.uint256 import Uint256, uint256_mul_div_mod

func check{range_check_ptr}(n: felt) {
    if (n == 0) {
        return ();
    }
    const MAX_LIMB = 2 ** 128 - 1;
    let (low, high, rem) = uint256_mul_div_mod(
        Uint256(MAX_LIMB, MAX_LIMB), Uint256(MAX_LIMB, MAX_LIMB), Uint256(1, 0)
    );
    assert low = Uint256(1, 0);
    assert high = Uint256(MAX_LIMB - 1, MAX_LIMB);
    assert rem = Uint256(0, 0);
    return check(n - 1);
}

func main{range_check_ptr}() {
    check(1024);
    return ();
}

func zero_divisor{range_check_ptr}() {
    let (low, high, rem) = uint256_mul_div_mod(Uint256(1, 0), Uint256(1, 0), Uint256(0, 0));
    return ();
}
