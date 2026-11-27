%builtins range_check

from starkware.cairo.common.default_dict import default_dict_new
from starkware.cairo.common.dict import dict_read, dict_write, dict_squash
from starkware.cairo.common.dict_access import DictAccess

const KEYS = 8192;
const CHECKPOINTS = 512;

func populate{dict_ptr: DictAccess*}(n: felt) {
    if (n == 0) {
        return ();
    }
    dict_write(n, n + 1);
    return populate(n - 1);
}

func checkpoints{range_check_ptr}(ptr: DictAccess*, n: felt) {
    if (n == 0) {
        return ();
    }
    let (start, end) = dict_squash(ptr, ptr);
    let dict_ptr = end;
    with dict_ptr {
        let (v) = dict_read(1);
        assert v = 2;
        dict_write(1, n + 2);
        let (updated) = dict_read(1);
        assert updated = n + 2;
    }
    return checkpoints(ptr, n - 1);
}

func main{range_check_ptr}() {
    let (dict_ptr) = default_dict_new(0);
    with dict_ptr {
        populate(KEYS);
        checkpoints(dict_ptr, CHECKPOINTS);
    }
    return ();
}
