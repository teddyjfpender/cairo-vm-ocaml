type bkind =
  | Output
  | Pedersen
  | Range_check
  | Ecdsa
  | Bitwise
  | Ec_op
  | Keccak
  | Poseidon
  | Range_check96
  | Add_mod
  | Mul_mod

let bname = function
  | Output -> "output"
  | Pedersen -> "pedersen"
  | Range_check -> "range_check"
  | Ecdsa -> "ecdsa"
  | Bitwise -> "bitwise"
  | Ec_op -> "ec_op"
  | Keccak -> "keccak"
  | Poseidon -> "poseidon"
  | Range_check96 -> "range_check96"
  | Add_mod -> "add_mod"
  | Mul_mod -> "mul_mod"

let all_builtins =
  [ Output; Pedersen; Range_check; Ecdsa; Bitwise; Ec_op; Keccak; Poseidon; Range_check96; Add_mod; Mul_mod ]

let bkind_of_name s =
  let s = if String.length s > 8 && String.sub s (String.length s - 8) 8 = "_builtin" then String.sub s 0 (String.length s - 8) else s in
  List.find_opt (fun k -> bname k = s) all_builtins

let cells_per_instance = function
  | Output | Range_check | Range_check96 -> 1
  | Pedersen -> 3
  | Ecdsa -> 2
  | Bitwise -> 5
  | Ec_op -> 7
  | Keccak -> 16
  | Poseidon -> 6
  | Add_mod | Mul_mod -> 7

let n_input_cells = function
  | Output | Range_check | Range_check96 -> 1
  | Pedersen -> 2
  | Ecdsa -> 2
  | Bitwise -> 2
  | Ec_op -> 5
  | Keccak -> 8
  | Poseidon -> 3
  | Add_mod | Mul_mod -> 7

type builtin = {
  kind : bkind;
  base : int; (* segment index *)
  mutable stop_ptr : int;
  mutable cache : Felt.t array; (* deduced outputs by offset, [Felt.empty] = none *)
}

(* Segment flags. cpu_kernel.c relies on these codes: 1 and 2 are the range
   checks, 5..9 the deducing builtins. *)
type flag = int

let k_plain = 0
let k_rc = 1
let k_rc96 = 2
let k_ecdsa = 4

let flag_of = function
  | Range_check -> k_rc
  | Range_check96 -> k_rc96
  | Ecdsa -> k_ecdsa
  | Bitwise -> 5
  | Pedersen -> 6
  | Poseidon -> 7
  | Keccak -> 8
  | Ec_op -> 9
  | Output | Add_mod | Mul_mod -> k_plain

let[@inline] is_deducing k = k >= 5 && k <= 9
