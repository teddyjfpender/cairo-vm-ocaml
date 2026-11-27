%builtins range_check

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.set import set_add

func insert{range_check_ptr, set_end_ptr: felt*}(base: felt*, row: felt*, n: felt) {
    if (n == 0) {
        return ();
    }
    assert [row] = 7;
    assert [row + 1] = n;
    set_add(base, 2, row);
    return insert(base, row + 2, n - 1);
}

func main{range_check_ptr}() {
    alloc_locals;
    let (local base: felt*) = alloc();
    let (local rows: felt*) = alloc();
    let set_end_ptr = base;
    with set_end_ptr {
        insert(base, rows, 65536);
        assert set_end_ptr = base + 2 * 65536;
    }
    return ();
}
