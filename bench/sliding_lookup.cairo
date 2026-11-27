%builtins range_check

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.find_element import find_element

const N = 262144;
const QUERIES = 65536;

func fill(data: felt*, n: felt) {
    if (n == 0) {
        return ();
    }
    assert [data] = N - n;
    return fill(data + 1, n - 1);
}

func query{range_check_ptr}(data: felt*, remaining: felt) {
    if (remaining == 0) {
        return ();
    }
    let key = N - QUERIES + remaining - 1;
    let start = QUERIES - remaining;
    let (p) = find_element(data + start, 1, N - start, key);
    assert p = data + key;
    return query(data, remaining - 1);
}

func main{range_check_ptr}() {
    alloc_locals;
    let (local data: felt*) = alloc();
    fill(data, N);
    query(data, QUERIES);
    return ();
}
