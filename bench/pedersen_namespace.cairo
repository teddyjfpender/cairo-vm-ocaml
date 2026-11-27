%builtins pedersen

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.hash import hash2

func chain{hash_ptr: HashBuiltin*}(n: felt, state: felt) -> (result: felt) {
    if (n == 0) {
        return (state,);
    }
    let (next) = hash2{hash_ptr=hash_ptr}(0x049ee3eba8c1600700ee1b87eb599f16716b0b1022947733551fde4050ca6804, state);
    return chain(n - 1, next);
}

func main{pedersen_ptr: HashBuiltin*}() {
    let (result) = chain{hash_ptr=pedersen_ptr}(8192, 123);
    return ();
}
