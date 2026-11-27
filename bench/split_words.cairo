%builtins range_check

from starkware.cairo.common.uint256 import split_64

func split_words{range_check_ptr}(x: felt, n: felt) {
    if (n == 0) {
        return ();
    }
    let (low, high) = split_64(x + n);
    return split_words(x, n - 1);
}

func main{range_check_ptr}() {
    split_words(2 ** 119 + 2 ** 63, 131072);
    return ();
}
