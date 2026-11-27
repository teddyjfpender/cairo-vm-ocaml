from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.keccak import KeccakState, unsafe_keccak_finalize

func checkpoints(start: felt*, end: felt*, n: felt) {
    if (n == 0) {
        return ();
    }
    assert [end] = 2 ** 110 + n;
    let (digest) = unsafe_keccak_finalize(KeccakState(start, end + 1));
    return checkpoints(start, end + 1, n - 1);
}

func main() {
    let (data) = alloc();
    checkpoints(data, data, 8192);
    return ();
}
