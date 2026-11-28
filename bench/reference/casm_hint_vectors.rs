// Copy to the pinned sequencer's starknet_os/examples/ and run with --features deserialize,testing.
use cairo_lang_casm::hints::CoreHintBase;
use cairo_lang_runner::casm_run::execute_core_hint_base;
use cairo_vm::types::exec_scope::ExecutionScopes;
use cairo_vm::vm::vm_core::VirtualMachine;
use num_bigint::BigUint;
use serde_json::{json, Value};

fn cell(offset: usize) -> Value {
    json!({"register": "AP", "offset": offset})
}

fn immediate(n: &BigUint) -> Value {
    json!({"Immediate": format!("{n:#x}")})
}

fn run(hints: Vec<Value>, stack_len: usize, rc_len: usize) -> Value {
    let mut vm = VirtualMachine::new(false, false);
    let mut scopes = ExecutionScopes::new();
    vm.add_memory_segment();
    let stack = vm.add_memory_segment();
    let rc = vm.add_memory_segment();
    vm.insert_value(stack, rc).unwrap();
    for hint in &hints {
        let hint: CoreHintBase = serde_json::from_value(hint.clone()).unwrap();
        execute_core_hint_base(&mut vm, &mut scopes, &hint, false).unwrap();
    }
    let words = |seg: isize, start, n| {
        (start..start + n)
            .map(|i: usize| format!("{:#x}", *vm.get_integer((seg, i).into()).unwrap()))
            .collect::<Vec<_>>()
    };
    json!({"hints": hints, "stack": words(1, 1, stack_len), "range_check": words(2, 0, rc_len)})
}

fn main() {
    let one = BigUint::from(1_u32);
    let zero = BigUint::default();
    let two128: BigUint = &one << 128_usize;
    let mask: BigUint = &two128 - &one;
    let prime: BigUint = (&one << 251_usize) + (BigUint::from(17_u32) << 192_usize) + &one;
    let mut vectors = Vec::new();
    for (a, b) in [
        (&zero, &zero),
        (&one, &zero),
        (&zero, &mask),
        (&mask, &mask),
        (&(&prime / 3_u32), &(&prime * 2_u32 / 3_u32)),
        (&(&prime - &one), &(&prime - &one)),
        (&(&prime / 2_u32), &(&prime - &one)),
    ] {
        vectors.push(run(vec![
            json!({"AssertLeFindSmallArcs": {"a": immediate(a), "b": immediate(b), "range_check_ptr": {"Deref": cell(0)}}}),
            json!({"AssertLeIsFirstArcExcluded": {"skip_exclude_a_flag": cell(1)}}),
            json!({"AssertLeIsSecondArcExcluded": {"skip_exclude_b_minus_a": cell(2)}}),
        ], 2, 4));
    }
    for n in [
        zero,
        one.clone(),
        &two128 - &one,
        two128.clone(),
        &two128 + &one,
        &mask * &mask,
        &mask * &mask - &one,
        &mask * &mask + &one,
        (&one << 256_usize) - &one,
    ] {
        vectors.push(run(
            vec![json!({"Uint256SquareRoot": {
                "value_low": immediate(&(&n & &mask)), "value_high": immediate(&(&n >> 128)),
                "sqrt0": cell(1), "sqrt1": cell(2), "remainder_low": cell(3),
                "remainder_high": cell(4), "sqrt_mul_2_minus_remainder_ge_u128": cell(5)
            }})],
            5,
            0,
        ));
    }
    println!("{}", serde_json::to_string_pretty(&vectors).unwrap());
}
