%builtins range_check

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.find_element import search_sorted_lower

// A batch of increasing lookups into the upper range of a sorted array.
const N = 262144;
const QUERIES = 16384;

func fill(data: felt*, n: felt) {
    if (n == 0) {
        return ();
    }
    assert [data] = N - n;
    return fill(data + 1, n - 1);
}

func query{range_check_ptr}(data: felt*, key: felt) {
    if (key == N) {
        return ();
    }
    let (p) = search_sorted_lower(data, 1, N, key);
    assert p = data + key;
    return query(data, key + 1);
}

func main{range_check_ptr}() {
    alloc_locals;
    let (local data: felt*) = alloc();
    fill(data, N);
    query(data, N - QUERIES);
    return ();
}
