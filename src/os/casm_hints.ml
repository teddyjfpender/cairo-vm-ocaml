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

let rec operand j =
  match variant j with
  | "Deref", j ->
      let at = cell j in (fun vm -> require_felt (Vm.get vm 1 (at vm)))
  | "DoubleDeref", `List [j; delta] ->
      let at = cell j and delta = U.to_int delta in
      (fun vm ->
        let ptr = Vm.get vm 1 (at vm) in
        if not (Felt.is_reloc ptr) then fail "CASM indirect operand requires a pointer";
        require_felt (Vm.get vm (Felt.rseg ptr) (Felt.roff ptr + delta)))
  | "Immediate", j ->
      let value = Felt.of_z (Pie_file.z_of_json j) in (fun _ -> value)
  | "BinOp", j ->
      let left = cell (U.member "a" j) and right = operand (U.member "b" j) in
      let op = match U.to_string (U.member "op" j) with
        | "Add" -> Felt.add | "Mul" -> Felt.mul | op -> fail "Unknown CASM operation %s" op in
      (fun vm -> op (require_felt (Vm.get vm 1 (left vm))) (right vm))
  | name, _ -> fail "Unknown CASM operand %s" name

let compile scopes j =
  let name, fields = variant j in
  let arg k = operand (U.member k fields) in
  let put k =
    let at = cell (U.member k fields) in
    fun vm v -> Vm.write vm 1 (at vm) v
  in
  match name with
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
  | "TestLessThan" | "TestLessThanOrEqual" ->
      let lhs = arg "lhs" and rhs = arg "rhs" and dst = put "dst" in
      let inclusive = name = "TestLessThanOrEqual" in
      (fun vm -> let cmp = Felt.compare (lhs vm) (rhs vm) in
        dst vm (Hintrt.of_bool (cmp < 0 || (inclusive && cmp = 0))))
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
