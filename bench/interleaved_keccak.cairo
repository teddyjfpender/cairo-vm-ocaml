from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.keccak import KeccakState, unsafe_keccak_finalize

func checkpoints(a: felt*, b: felt*, n: felt, left: felt) {
    if (left == 0) {
        return ();
    }
    assert [a + n] = 2 ** 110 + left;
    assert [b + n] = 2 ** 112 + left;
    let (da) = unsafe_keccak_finalize(KeccakState(a, a + n + 1));
    let (db) = unsafe_keccak_finalize(KeccakState(b, b + n + 1));
    return checkpoints(a, b, n + 1, left - 1);
}

func main() {
    alloc_locals;
    let (local a: felt*) = alloc();
    let (b) = alloc();
    checkpoints(a, b, 0, 8192);
    return ();
}
