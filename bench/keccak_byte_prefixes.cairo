from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.keccak import unsafe_keccak

func checkpoints(data: felt*, n: felt, left: felt) {
    if (left == 0) {
        return ();
    }
    assert [data + n] = 2 ** 52 + n;
    let (low, high) = unsafe_keccak(data, n * 16 + 7);
    return checkpoints(data, n + 1, left - 1);
}

func main() {
    let (data) = alloc();
    checkpoints(data, 0, 4096);
    return ();
}
