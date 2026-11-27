%builtins range_check

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.squash_dict import squash_dict

// Increase N to measure access-index consumption for a frequently updated key.
const N = 32768;
const BIG_KEY = 2 ** 130;

func fill(dst: DictAccess*, n: felt) {
    if (n == 0) {
        return ();
    }
    assert dst[0] = DictAccess(key=BIG_KEY, prev_value=n, new_value=n - 1);
    return fill(dst + DictAccess.SIZE, n - 1);
}

func main{range_check_ptr}() {
    alloc_locals;
    let (local accesses: DictAccess*) = alloc();
    assert accesses[0] = DictAccess(key=BIG_KEY, prev_value=N + 1, new_value=N);
    assert accesses[1] = DictAccess(key=2, prev_value=0, new_value=17);
    fill(accesses + 2 * DictAccess.SIZE, N);
    let (local result: DictAccess*) = alloc();
    let (end) = squash_dict(accesses, accesses + (N + 2) * DictAccess.SIZE, result);
    assert end = result + 2 * DictAccess.SIZE;
    assert result[0] = DictAccess(key=2, prev_value=0, new_value=17);
    assert result[1] = DictAccess(key=BIG_KEY, prev_value=N + 1, new_value=0);
    return ();
}
