(* Builtin kinds, their memory cell layout and per-run builtin state. *)


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
  included : bool;
  mutable stop_ptr : int;
  mutable cache : int array; (* deduced output codes by offset, 0 = none *)
}



(* segment flags *)
let k_plain = 0
let k_rc = 1
let k_rc96 = 2
let k_deduce = 3 (* pedersen, bitwise, ec_op, keccak, poseidon *)
let k_bitwise = 5
let k_pedersen = 6
let k_poseidon = 7
let k_keccak = 8
let k_ec_op = 9
let is_deducing k = k = k_deduce || (k >= k_bitwise && k <= k_ec_op)
let k_ecdsa = 4
