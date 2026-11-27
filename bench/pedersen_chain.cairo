%builtins pedersen

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.hash import hash2

func chain{hash_ptr: HashBuiltin*}(n: felt, state: felt) -> (result: felt) {
    if (n == 0) {
        return (state,);
    }
    let (next) = hash2{hash_ptr=hash_ptr}(state, state + n);
    return chain(n - 1, next);
}

func main{pedersen_ptr: HashBuiltin*}() {
    let (result) = chain{hash_ptr=pedersen_ptr}(8192, 123);
    return ();
}
