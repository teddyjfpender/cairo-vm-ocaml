func quotients(n: felt, dividend: felt, divisor: felt) -> (result: felt) {
    if (n == 0) {
        return (dividend,);
    }
    tempvar q = dividend / divisor;
    return quotients(n - 1, q + n, divisor);
}

func main() {
    let (result) = quotients(131072, 1234567, 0x654fd7e67a123dd13868093b3b7777f1ffef596c2e324f25ceaf9146698482c);
    return ();
}
