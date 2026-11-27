(* Cairo layouts with the instance parameters proof mode needs, mirroring
   cairo-vm v3.2.0 vm/src/types/layout.rs and instance_definitions/*.rs.

   The reference cairo-vm-cli is built without the [mod_builtin] cargo
   feature, so add_mod/mul_mod are absent from every layout here
   ([with_mod_builtin] = false). *)

open Vm

let with_mod_builtin = false

(* LowRatio: numerator / denominator; [num] = 0 is a dynamic-layout ratio 0 *)
type ratio = { num : int; den : int }

type diluted = { units_per_step : int; fractional : bool; spacing : int; n_bits : int }

type t = {
  name : string;
  cpu_component_step : int;
  rc_units : int;
  memory_units_per_step : int;
  public_memory_fraction : int;
  diluted : diluted option;
  (* builtins in canonical order; Output carries a dummy ratio *)
  builtins : (bkind * ratio) list;
}

let r n = { num = n; den = 1 }
let default_diluted = { units_per_step = 16; fractional = false; spacing = 4; n_bits = 16 }
let diluted u s n = { default_diluted with units_per_step = u; spacing = s; n_bits = n }

let make ?(rc_units = 4) ?(fraction = 8) ?diluted name builtins =
  { name; cpu_component_step = 1; rc_units; memory_units_per_step = 8; public_memory_fraction = fraction;
    diluted; builtins = (if builtins = [] then [] else (Output, r 0) :: builtins) }

let mods a m = if with_mod_builtin then [ (Add_mod, r a); (Mul_mod, r m) ] else []

let of_name = function
  | "plain" -> Some (make ~rc_units:16 ~fraction:4 "plain" [])
  | "small" -> Some (make ~rc_units:16 ~fraction:4 "small" [ (Pedersen, r 8); (Range_check, r 8); (Ecdsa, r 512) ])
  | "dex" -> Some (make ~fraction:4 "dex" [ (Pedersen, r 8); (Range_check, r 8); (Ecdsa, r 512) ])
  | "recursive" ->
      Some (make ~diluted:default_diluted "recursive" [ (Pedersen, r 128); (Range_check, r 8); (Bitwise, r 8) ])
  | "starknet" ->
      Some
        (make ~diluted:(diluted 2 4 16) "starknet"
           [ (Pedersen, r 32); (Range_check, r 16); (Ecdsa, r 2048); (Bitwise, r 64); (Ec_op, r 1024); (Poseidon, r 32) ])
  | "starknet_with_keccak" ->
      Some
        (make ~diluted:default_diluted "starknet_with_keccak"
           [ (Pedersen, r 32); (Range_check, r 16); (Ecdsa, r 2048); (Bitwise, r 64); (Ec_op, r 1024);
             (Keccak, r 2048); (Poseidon, r 32) ])
  | "recursive_large_output" ->
      Some
        (make ~diluted:default_diluted "recursive_large_output"
           [ (Pedersen, r 128); (Range_check, r 8); (Bitwise, r 8); (Poseidon, r 8) ])
  | "recursive_with_poseidon" ->
      Some
        (make ~diluted:(diluted 8 4 16) "recursive_with_poseidon"
           [ (Pedersen, r 256); (Range_check, r 16); (Bitwise, r 16); (Poseidon, r 64) ])
  | "all_cairo" ->
      Some
        (make ~diluted:default_diluted "all_cairo"
           ([ (Pedersen, r 256); (Range_check, r 8); (Ecdsa, r 2048); (Bitwise, r 16); (Ec_op, r 1024);
              (Keccak, r 2048); (Poseidon, r 256); (Range_check96, r 8) ] @ mods 128 256))
  | "all_cairo_stwo" ->
      Some
        (make ~diluted:default_diluted "all_cairo_stwo"
           ([ (Pedersen, r 256); (Range_check, r 8); (Bitwise, r 16); (Ec_op, r 1024); (Poseidon, r 256);
              (Range_check96, r 8) ] @ mods 128 256))
  | "stwo_no_ecop" ->
      Some
        (make ~diluted:default_diluted "stwo_no_ecop"
           ([ (Pedersen, r 256); (Range_check, r 8); (Bitwise, r 16); (Poseidon, r 256); (Range_check96, r 8) ]
           @ mods 128 256))
  | "all_solidity" ->
      Some
        (make ~rc_units:8 ~diluted:default_diluted "all_solidity"
           [ (Pedersen, r 8); (Range_check, r 8); (Ecdsa, r 512); (Bitwise, r 256); (Ec_op, r 256) ])
  | "perpetual" ->
      Some (make ~fraction:4 "perpetual" [ (Pedersen, r 32); (Range_check, r 16); (Ecdsa, r 2048) ])
  | "dex_with_bitwise" ->
      Some
        (make ~diluted:(diluted 2 4 16) ~fraction:4 "dex_with_bitwise"
           [ (Pedersen, r 8); (Range_check, r 8); (Ecdsa, r 512); (Bitwise, r 64) ])
  | _ -> None

(* ---- dynamic layout (CairoLayoutParams) ---- *)

let dynamic_of_json (j : Yojson.Safe.t) : t =
  let module U = Yojson.Safe.Util in
  let field k =
    match U.member k j with
    | `Int n -> n
    | `Intlit s -> fail "Invalid layout params: %s = %s is out of range" k s
    | `Null -> fail "Invalid layout params: missing field `%s`" k
    | _ -> fail "Invalid layout params: invalid type for `%s`" k
  in
  let u32 k =
    let n = field k in
    if n < 0 || n > 0xffffffff then fail "Invalid layout params: %s = %d is not a u32" k n;
    n
  in
  let uses k =
    match U.member k j with
    | `Bool b -> b
    | `Int n -> n <> 0
    | `Null -> fail "Invalid layout params: missing field `%s`" k
    | _ -> fail "Invalid layout params: invalid type for `%s`" k
  in
  let log_diluted =
    let n = field "log_diluted_units_per_step" in
    if n < -0x80000000 || n > 0x7fffffff then fail "Invalid layout params: log_diluted_units_per_step is not an i32";
    n
  in
  let ratio name =
    let n = u32 (name ^ "_ratio") in
    if (not (uses ("uses_" ^ name ^ "_builtin"))) && n <> 0 then
      fail "Builtin(s) %s not present in layout dynamic" name;
    n
  in
  let rc_units = u32 "rc_units" and cpu = u32 "cpu_component_step" and mem = u32 "memory_units_per_step" in
  let ped = ratio "pedersen" and rc = ratio "range_check" and ecdsa = ratio "ecdsa" in
  let bw = ratio "bitwise" and ec = ratio "ec_op" and kec = ratio "keccak" and pos = ratio "poseidon" in
  let rc96 = ratio "range_check96" and rc96d = u32 "range_check96_ratio_den" in
  let add = ratio "add_mod" and addd = u32 "add_mod_ratio_den" in
  let mul = ratio "mul_mod" and muld = u32 "mul_mod_ratio_den" in
  let a = abs log_diluted in
  if a >= 32 then fail "Dynamic layout: log_diluted_units_per_step %d overflows" log_diluted;
  let diluted = { default_diluted with units_per_step = 1 lsl a; fractional = log_diluted < 0 } in
  {
    name = "dynamic";
    cpu_component_step = cpu;
    rc_units;
    memory_units_per_step = mem;
    public_memory_fraction = 8;
    diluted = Some diluted;
    builtins =
      [ (Output, r 0); (Pedersen, r ped); (Range_check, r rc); (Ecdsa, r ecdsa); (Bitwise, r bw); (Ec_op, r ec);
        (Keccak, r kec); (Poseidon, r pos); (Range_check96, { num = rc96; den = rc96d }) ]
      @ (if with_mod_builtin then [ (Add_mod, { num = add; den = addd }); (Mul_mod, { num = mul; den = muld }) ]
         else []);
  }

let dynamic_of_file path =
  let j = try Yojson.Safe.from_file path with Yojson.Json_error m -> fail "Invalid layout params file: %s" m in
  dynamic_of_json j

let builtin_kinds l = List.map fst l.builtins

(* ---- per-builtin constants (instance_definitions) ---- *)

let instances_per_component = function Keccak -> 16 | _ -> 1

let n_parts = function Range_check -> 8 | Range_check96 -> 6 | _ -> 0

(* Bitwise diluted-check units for TOTAL_N_BITS = 251 *)
let bitwise_diluted_units spacing n_bits =
  let total = 251 in
  let len = ref 0 and trimmed = ref 0 in
  let step = spacing * n_bits in
  let i = ref 0 in
  while !i < total do
    for j = 0 to spacing - 1 do
      if !i + j < total then begin
        incr len;
        if !i + j + (spacing * (n_bits - 1)) + 1 > total then incr trimmed
      end
    done;
    i := !i + step
  done;
  (4 * !len) + !trimmed

let used_diluted_units kind spacing n_bits =
  match kind with
  | Bitwise -> bitwise_diluted_units spacing n_bits
  | Keccak -> if n_bits = 0 || 262144 mod n_bits <> 0 then 0 else 262144 / n_bits
  | _ -> 0
