%builtins output

func fill{output_ptr: felt*}(n: felt) {
    if (n == 0) {
        return ();
    }
    assert [output_ptr] = n;
    let output_ptr = output_ptr + 1;
    return fill(n - 1);
}

func main{output_ptr: felt*}() {
    fill(262144);
    return ();
}
