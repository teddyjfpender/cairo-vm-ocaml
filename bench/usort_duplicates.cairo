%builtins range_check

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.usort import usort

// Increase N to measure position consumption for a value with high multiplicity.
const N = 32768;

func fill(dst: felt*, n: felt) {
    if (n == 0) {
        return ();
    }
    assert dst[0] = 7;
    return fill(dst + 1, n - 1);
}

func main{range_check_ptr}() {
    alloc_locals;
    let (local input: felt*) = alloc();
    assert input[0] = 7;
    assert input[1] = 2;
    fill(input + 2, N);
    let (n, sorted, counts) = usort(input_len=N + 2, input=input);
    assert n = 2;
    assert sorted[0] = 2;
    assert sorted[1] = 7;
    assert counts[0] = 1;
    assert counts[1] = N + 1;
    return ();
}
