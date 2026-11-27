%builtins range_check

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.usort import usort

const N = 32768;

func fill(dst: felt*, n: felt) {
    if (n == 0) {
        return ();
    }
    assert [dst] = 2 ** 100 + n;
    assert [dst + 1] = 2 ** 100 + N - n + 1;
    return fill(dst + 2, n - 1);
}

func main{range_check_ptr}() {
    alloc_locals;
    let (local input: felt*) = alloc();
    fill(input, N / 2);
    let (length, sorted, counts) = usort(input_len=N, input=input);
    assert length = N;
    return ();
}
