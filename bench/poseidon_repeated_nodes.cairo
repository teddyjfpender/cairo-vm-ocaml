%builtins output poseidon

from starkware.cairo.common.cairo_builtins import PoseidonBuiltin
from starkware.cairo.common.poseidon_state import PoseidonBuiltinState

// Revisit sixteen node inputs at distinct builtin addresses. Changing a
// subtree input changes the digest, and every digest contributes to output.
func visit{poseidon_ptr: PoseidonBuiltin*}(left: felt, node: felt, sum: felt) -> (total: felt) {
    if (left == 0) {
        return (sum,);
    }
    assert poseidon_ptr.input = PoseidonBuiltinState(node, node + 1, 2);
    let next = sum + poseidon_ptr.output.s0;
    let poseidon_ptr = poseidon_ptr + PoseidonBuiltin.SIZE;
    if (node == 15) {
        return visit(left - 1, 0, next);
    }
    return visit(left - 1, node + 1, next);
}

func main{output_ptr: felt*, poseidon_ptr: PoseidonBuiltin*}() {
    let (total) = visit(32768, 0, 0);
    assert [output_ptr] = total;
    let output_ptr = output_ptr + 1;
    return ();
}
