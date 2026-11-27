%builtins output bitwise

from starkware.cairo.common.cairo_builtins import BitwiseBuiltin

func main{output_ptr: felt*, bitwise_ptr: BitwiseBuiltin*}() {
    assert bitwise_ptr.x = 7;
    assert bitwise_ptr.y = 3;
    assert [output_ptr] = bitwise_ptr.x_and_y;
    let output_ptr = output_ptr + 1;
    let bitwise_ptr = bitwise_ptr + BitwiseBuiltin.SIZE;
    return ();
}
