%builtins ec_op

from starkware.cairo.common.cairo_builtins import EcOpBuiltin
from starkware.cairo.common.ec_point import EcPoint

func ladder{ec_op_ptr: EcOpBuiltin*}(p: EcPoint, q: EcPoint, n: felt) {
    if (n == 0) {
        return ();
    }
    assert ec_op_ptr.p = p;
    assert ec_op_ptr.q = q;
    assert ec_op_ptr.m = 0x068183d871725cf52bec965731bc92e1cf9b5eec4a6a8b3d2f7793ab5dc68201 + n;
    tempvar x = ec_op_ptr.r.x;
    let ec_op_ptr = ec_op_ptr + EcOpBuiltin.SIZE;
    return ladder(p, q, n - 1);
}

func main{ec_op_ptr: EcOpBuiltin*}() {
    let p = EcPoint(
        0x49ee3eba8c1600700ee1b87eb599f16716b0b1022947733551fde4050ca6804,
        0x3ca0cfe4b3bc6ddf346d49d06ea0ed34e621062c0e056c1d0405d266e10268a,
    );
    let q = EcPoint(
        0x4ba4cc166be8dec764910f75b45f74b40c690c74709e90f3aa372f0bd2d6997,
        0x40301cf5c1751f4b971e46c4ede85fcac5c59a5ce5ae7c48151f27b24b219c,
    );
    ladder(p, q, 2048);
    return ();
}
