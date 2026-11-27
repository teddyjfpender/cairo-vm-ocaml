%builtins bitwise

from starkware.cairo.common.cairo_builtins import BitwiseBuiltin

func bit_words{bitwise_ptr: BitwiseBuiltin*}(n: felt) {
    if (n == 0) {
        return ();
    }
    assert bitwise_ptr.x = 2 ** 51 + n;
    assert bitwise_ptr.y = 2 ** 42 + n * 7;
    tempvar xored = bitwise_ptr.x_xor_y;
    let bitwise_ptr = bitwise_ptr + BitwiseBuiltin.SIZE;
    return bit_words(n - 1);
}

func main{bitwise_ptr: BitwiseBuiltin*}() {
    bit_words(262144);
    return ();
}
