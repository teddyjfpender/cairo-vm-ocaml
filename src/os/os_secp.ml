(* Starknet secp256k1/r1 syscalls use opaque point handles in a shared segment.
   Each block owns a table for each curve. The first allocated handle is at
   offset zero and every subsequent handle advances by six Cairo words. *)
open Errors
open Hintrt

type point = Infinity | Point of Z.t * Z.t
type curve = { prime : Z.t; a : Z.t; b : Z.t }
let k1 = {prime=Secp.secp_p; a=Z.zero; b=Z.of_int 7}
let r1 = {prime=Secp.r1_p; a=Z.sub Secp.r1_p (Z.of_int 3); b=Secp.r1_b}

type op = New | Get_point_from_x | Add | Mul | Get_xy
let operations =
  ["New", "NEW", New, 6; "GetPointFromX", "GET_POINT_FROM_X", Get_point_from_x, 5;
   "Add", "ADD", Add, 4; "Mul", "MUL", Mul, 5; "GetXy", "GET_XY", Get_xy, 3]
let selectors =
  List.concat_map (fun (name, prefix, curve) ->
      List.map (fun (suffix, gas, op, size) -> name ^ suffix, (prefix ^ gas, curve, op, size)) operations)
    ["Secp256k1", "SECP256K1_", k1; "Secp256r1", "SECP256R1_", r1]

type t = { mutable base : Felt.t; points : (curve * point) Felt_tbl.t }
let create () = {base=Felt.empty; points=Felt_tbl.create 16}
let reset state = state.base <- Felt.empty; Felt_tbl.clear state.points

let rhs c x = Z.erem Z.(x * (x * x + c.a) + c.b) c.prime

let add c p q = match p, q with
  | Infinity, p | p, Infinity -> p
  | Point (x,y), Point (xx,yy) ->
      if Z.equal x xx && Z.equal (Z.erem (Z.add y yy) c.prime) Z.zero then Infinity
      else
        let n,d = if Z.equal x xx then Z.(of_int 3 * x * x + c.a), Z.(of_int 2 * y)
          else Z.sub yy y, Z.sub xx x in
        let slope = Z.erem (Z.mul n (Z.invert d c.prime)) c.prime in
        let rx = Z.erem Z.(slope * slope - x - xx) c.prime in
        Point (rx, Z.erem Z.(slope * (x - rx) - y) c.prime)

module K1 = Weierstrass.Make (struct let prime = Secp.secp_p let minus_three = false end)
module R1 = Weierstrass.Make (struct let prime = Secp.r1_p let minus_three = true end)

let multiply c p scalar = match p with
  | Infinity -> Infinity
  | Point (x,y) ->
      match (if c == k1 then K1.scale else R1.scale) (x,y) scalar with
      | None -> Infinity | Some (u,v) -> Point (u,v)

let execute state vm c op at =
  let input i = at i in
  let coordinate i =
    let limb j = let x = input j in
      if not (Felt.is_felt x) || Felt.bits x > 128 then fail "Invalid u256 limb";
      Felt.to_z x in
    Z.logor (limb i) (Z.shift_left (limb (i+1)) 128) in
  let allocate point =
    if state.base = Felt.empty then state.base <- Felt.reloc (Vm.add_segment vm) 0;
    let ptr = Vm.reloc_add_felt state.base (Felt.small (6 * Felt_tbl.length state.points)) in
    Felt_tbl.add state.points ptr (c, point); ptr in
  let get i = match Felt_tbl.find_opt state.points (input i) with
    | Some (curve, point) when curve == c -> point
    | _ -> fail "Invalid secp point address" in
  let some p = Ok [Felt.zero; allocate p] and none = Ok [Felt.one; Felt.zero] in
  match op with
  | New ->
      let x = coordinate 2 and y = coordinate 4 in
      if Z.geq x c.prime || Z.geq y c.prime then Error "Invalid argument"
      else if Z.equal x Z.zero && Z.equal y Z.zero then some Infinity
      else if Z.equal (Z.erem (Z.mul y y) c.prime) (rhs c x) then some (Point (x,y)) else none
  | Get_point_from_x ->
      let x = coordinate 2 and parity = input 4 in
      if parity <> Felt.zero && parity <> Felt.one then fail "Invalid secp parity";
      if Z.geq x c.prime then Error "Invalid argument" else
        let squared = rhs c x in
        let root = Z.powm squared (Z.shift_right (Z.succ c.prime) 2) c.prime in
        if not (Z.equal (Z.erem (Z.mul root root) c.prime) squared) then none
        else some (Point (x, if Z.testbit root 0 = (parity = Felt.one) then root else Z.sub c.prime root))
  | Mul -> Ok [allocate (multiply c (get 2) (coordinate 3))]
  | Add -> Ok [allocate (add c (get 2) (get 3))]
  | Get_xy ->
      let x,y = match get 2 with Infinity -> Z.zero,Z.zero | Point (x,y) -> x,y in
      let limbs z = [Felt.of_z (Z.extract z 0 128); Felt.of_z (Z.shift_right z 128)] in
      Ok (limbs x @ limbs y)

let register reg =
  reg "ids.is_on_curve = (y * y) % SECP_P == y_square_int" (fun c vm ->
      let y = var_z c.scopes "y" in
      let square = Z.erem (Z.mul y y) (var_z c.scopes "SECP_P") in
      set_val vm c "is_on_curve" (of_bool (Z.equal square (var_z c.scopes "y_square_int"))));
  reg "ReadEcPointFromAddress" (fun c vm ->
      let ptr = if Felt.equal (get_felt vm c "not_on_curve") Felt.zero then
          get_member vm c "response" ["ec_point"] else Felt.reloc (Vm.add_segment vm) 0 in
      set_val vm c "result_ptr" ptr)
