%builtins output pedersen

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.hash import hash2

// Revisit 16 pairs of full-width node values at distinct builtin addresses.
func visit{hash_ptr: HashBuiltin*}(left: felt, node: felt, sum: felt) -> (total: felt) {
    if (left == 0) {
        return (sum,);
    }
    // Base values are SHA-256("left child") and SHA-256("right child"), reduced mod p.
    const LEFT = 2442740150498024237783950337676312836337740777691591962728396962101453602275;
    const RIGHT = 563234591342225108832958145097733815921266451233640441874443867661934834424;
    let (digest) = hash2(LEFT + node, RIGHT + node);
    if (node == 15) {
        return visit(left - 1, 0, sum + digest);
    }
    return visit(left - 1, node + 1, sum + digest);
}

func main{output_ptr: felt*, pedersen_ptr: HashBuiltin*}() {
    let (total) = visit{hash_ptr=pedersen_ptr}(8192, 0, 0);
    assert [output_ptr] = total;
    let output_ptr = output_ptr + 1;
    return ();
}
