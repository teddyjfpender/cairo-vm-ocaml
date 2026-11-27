(* Compile CASM's serialized operands once when a class enters OS memory. *)
open Errors
module U = Yojson.Safe.Util

let variant = function
  | `Assoc [name, args] -> name, args
  | _ -> fail "Invalid CASM hint or operand"

let cell j =
  let offset = U.to_int (U.member "offset" j) in
  if offset < -32768 || offset > 32767 then fail "CASM cell offset is outside i16";
  match U.to_string (U.member "register" j) with
  | "AP" -> (fun vm -> vm.Vm.ap + offset)
  | "FP" -> (fun vm -> vm.Vm.fp + offset)
  | r -> fail "Unknown CASM register %s" r

let require_felt v =
  if not (Felt.is_felt v) then fail "CASM operand requires an integer";
  v

let rec operand ?(address=false) j =
  let checked v =
    if v = Felt.empty then fail "Unassigned CASM operand";
    if address then v else require_felt v in
  match variant j with
  | "Deref", j ->
      let at = cell j in (fun vm -> checked (Vm.get vm 1 (at vm)))
  | "DoubleDeref", `List [j; delta] ->
      let at = cell j and delta = U.to_int delta in
      (fun vm ->
        let ptr = Vm.get vm 1 (at vm) in
        if not (Felt.is_reloc ptr) then fail "CASM indirect operand requires a pointer";
        checked (Vm.get vm (Felt.rseg ptr) (Felt.roff ptr + delta)))
  | "Immediate", j ->
      let value = Felt.of_z (Pie_file.z_of_json j) in (fun _ -> value)
  | "BinOp", j ->
      let left = cell (U.member "a" j) and right = operand (U.member "b" j) in
      let op = match U.to_string (U.member "op" j) with
        | "Add" -> Vm.value_add | "Mul" -> Vm.value_mul | op -> fail "Unknown CASM operation %s" op in
      (fun vm -> op (checked (Vm.get vm 1 (left vm))) (right vm))
  | name, _ -> fail "Unknown CASM operand %s" name

let compile ~rng ~syscall scopes j =
  let name, fields = variant j in
  let arg k = operand (U.member k fields) in
  let ptr k = operand ~address:true (U.member k fields) in
  let put k =
    let at = cell (U.member k fields) in
    fun vm v -> Vm.write vm 1 (at vm) v
  in
  match name with
  | "AllocFelt252Dict" | "Felt252DictEntryInit" | "Felt252DictEntryUpdate" | "GetSegmentArenaIndex"
  | "InitSquashData" | "GetCurrentAccessIndex" | "ShouldSkipSquashLoop" | "GetCurrentAccessDelta"
  | "ShouldContinueSquashLoop" | "GetNextDictKey" -> Casm_dict.compile name ~arg ~ptr ~put scopes
  | "RandomEcPoint" ->
      let x = put "x" and y = put "y" in
      (fun vm -> let a,b = Os_rng.point (Lazy.force rng) in x vm a; y vm b)
  | "SystemCall" ->
      let base, delta = match variant (U.member "system" fields) with
        | "Deref", r -> cell r, Felt.zero
        | "BinOp", b when U.member "op" b = `String "Add" ->
            (match variant (U.member "b" b) with
             | "Immediate", offset -> cell (U.member "a" b), Felt.of_z (Pie_file.z_of_json offset)
             | _ -> fail "Expected syscall pointer offset")
        | _ -> fail "Expected CASM syscall pointer" in
      (fun vm -> let ptr = Vm.get vm 1 (base vm) in
        if not (Felt.is_reloc ptr) then fail "Expected syscall segment";
        syscall vm (Vm.reloc_add_felt ptr delta))
  | "AllocSegment" ->
      let dst = put "dst" in
      (fun vm -> dst vm (Felt.reloc (Vm.add_segment vm) 0))
  | "AllocConstantSize" ->
      let size = arg "size" and dst = put "dst" in
      (fun vm ->
        let n = size vm in
        let ptr = match Hintrt.var_opt scopes "memory_exec_scope" with
          | Some (Hintrt.Value v) -> v | _ -> Felt.reloc (Vm.add_segment vm) 0 in
        dst vm ptr;
        Hintrt.set scopes "memory_exec_scope" (Hintrt.Value (Vm.reloc_add_felt ptr n)))
  | "TestLessThan" ->
      let lhs = arg "lhs" and rhs = arg "rhs" and dst = put "dst" in
      (fun vm -> dst vm (Hintrt.of_bool (Felt.compare (lhs vm) (rhs vm) < 0)))
  | "TestLessThanOrEqual" | "TestLessThanOrEqualAddress" ->
      let get k = operand ~address:true (U.member k fields) in
      let lhs = get "lhs" and rhs = get "rhs" and dst = put "dst" in
      (fun vm ->
        let a = lhs vm and b = rhs vm in
        (* Rust derives Ord with RelocatableValue before Int. *)
        let le = match Felt.is_reloc a, Felt.is_reloc b with
          | true, true -> (a :> int) <= (b :> int)
          | true, false -> true | false, true -> false
          | false, false -> Felt.compare a b <= 0 in
        dst vm (Hintrt.of_bool le))
  | "LinearSplit" ->
      let v = arg "value" and scalar = arg "scalar" and bound = arg "max_x" in
      let x = put "x" and y = put "y" in
      (fun vm ->
        let v = Felt.to_z (v vm) and scalar = Felt.to_z (scalar vm) in
        if Z.equal scalar Z.zero then fail "LinearSplit with zero scalar";
        let q = Z.min (Z.div v scalar) (Felt.to_z (bound vm)) in
        x vm (Felt.of_z q); y vm (Felt.of_z (Z.sub v (Z.mul q scalar))))
  | "DivMod" | "WideMul128" ->
      let lhs = arg "lhs" and rhs = arg "rhs" in
      let divide = name = "DivMod" in
      let high = put (if divide then "quotient" else "high") in
      let low = put (if divide then "remainder" else "low") in
      (fun vm ->
        let a = Felt.to_z (lhs vm) and b = Felt.to_z (rhs vm) in
        let h, l = if divide then begin
            if Z.equal b Z.zero then fail "DivMod with zero divisor";
            Z.ediv_rem a b
          end else let p = Z.mul a b in Z.shift_right p 128, Z.extract p 0 128 in
        high vm (Felt.of_z h); low vm (Felt.of_z l))
  | "EvalCircuit" -> Casm_circuit.compile ~arg ~ptr
  | "Uint256DivMod" -> Casm_uint.division ~arg ~put 2
  | "Uint512DivModByUint256" -> Casm_uint.division ~arg ~put 4
  | "U256InvModN" -> Casm_uint.inverse ~arg ~put
  | "SquareRoot" ->
      let v = arg "value" and dst = put "dst" in
      (fun vm -> dst vm (Felt.of_z (Z.sqrt (Felt.to_z (v vm)))))
  | "FieldSqrt" ->
      let v = arg "val" and dst = put "sqrt" in
      (fun vm ->
        let z = Felt.to_z (v vm) in
        let root = match Secp.felt_sqrt z with
          | Some root -> root
          | None -> (match Secp.felt_sqrt (Z.erem (Z.mul (Z.of_int 3) z) Felt.p) with
                     | Some root -> root | None -> fail "CASM FieldSqrt has no square root") in
        dst vm (Felt.of_z (Z.min root (Z.sub Felt.p root))))
  | _ -> (fun _ -> fail "Unsupported CASM hint: %s" name)
