%builtins range_check

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.math import assert_le_felt, assert_nn, unsigned_div_rem
from starkware.cairo.common.math_cmp import is_nn
from starkware.cairo.common.memcpy import memcpy
from starkware.cairo.common.memset import memset

func main{range_check_ptr}() {
    alloc_locals;
    let (local source) = alloc();
    let (local dest) = alloc();
    memset(source, 37, 3);
    memcpy(dest, source, 3);
    let (q, r) = unsigned_div_rem([dest + 2], 5);
    assert q = 7;
    assert r = 2;
    assert_nn(r);
    let negative = is_nn(-3);
    assert negative = 0;
    assert_le_felt(2, 37);
    return ();
}
