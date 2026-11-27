func products(x: felt, y: felt, n: felt) -> (res: felt) {
    if (n == 0) {
        return (x,);
    }
    tempvar next_x = x * y;
    tempvar next_y = y * y + x;
    return products(next_x, next_y, n - 1);
}

func main() {
    products(2 ** 220 + 1879, 2 ** 211 + 533, 1048576);
    return ();
}
