(* Hint runtime: execution scopes and `ids` access.

   Hints are adversarial witnesses for soundness: everything they write goes
   through the same write-once memory and builtin validation as the CPU. *)

open Vm
module P = Program

type dict_tracker = {
  data : (int, int) Hashtbl.t; (* canonical key code -> value code *)
  default : int option;
  mutable current_ptr : int; (* relocatable code *)
}

type dyn =
  | Int of Z.t
  | Value of int (* felt/relocatable code *)
  | Ints of int list
  | Values of int list
  | Dict_manager of (int, dict_tracker) Hashtbl.t
  | Access_indices of (int, int list) Hashtbl.t
  | Positions of (int, int list) Hashtbl.t
  | Initial_dict of (int, int) Hashtbl.t
  | Nothing

type scopes = { mutable stack : (string, dyn) Hashtbl.t list }

let new_scopes () = { stack = [ Hashtbl.create 8 ] }
let only_main_scope s = List.length s.stack = 1
let top s = List.hd s.stack

let enter s vars =
  let h = Hashtbl.create 8 in
  List.iter (fun (k, v) -> Hashtbl.replace h k v) vars;
  s.stack <- h :: s.stack

let exit_scope s =
  match s.stack with
  | [ _ ] -> fail "Cannot exit main scope."
  | _ :: rest -> s.stack <- rest
  | [] -> assert false

let var s name = match Hashtbl.find_opt (top s) name with Some v -> v | None -> fail "Variable %s not present in current execution scope" name
let var_opt s name = Hashtbl.find_opt (top s) name
let set s name v = Hashtbl.replace (top s) name v
let del s name = Hashtbl.remove (top s) name

let var_z s name = match var s name with Int z -> z | Value v when Felt.is_felt v -> Felt.to_z v | _ -> fail "Variable %s is not an integer" name

(* ---- canonical keys (big felts interned so keys are plain ints) ---- *)

module Felt_keys = Hashtbl.Make (struct
  type t = int
  let equal = Felt.equal
  let hash = Felt.hash
end)

let intern = Felt_keys.create 64

let canon v =
  if Felt.is_big v then begin
    match Felt_keys.find_opt intern v with
    | Some c -> c
    | None -> Felt_keys.add intern v v; v
  end else v

(* Python ordering on felt values (ints); relocatables after ints, ordered by (segment, offset) *)
let compare_values a b =
  match (Felt.is_felt a, Felt.is_felt b) with
  | true, true -> Felt.compare a b
  | true, false -> -1
  | false, true -> 1
  | false, false -> Stdlib.compare a b

(* ---- compiled hint context ---- *)

type ctx = {
  prog : P.t;
  hint : P.hint;
  scopes : scopes;
  refs : (string, P.reference) Hashtbl.t; (* short name -> reference *)
  plans : (string * string list, bool * step list) Hashtbl.t; (* memoized member paths *)
}

(* A resolved member path: add an offset, or follow a pointer. *)
and step = Off of int | Follow

let make_ctx prog scopes (hint : P.hint) =
  let refs = Hashtbl.create 8 in
  let inner = match List.rev hint.scopes with s :: _ -> s | [] -> "" in
  List.iter
    (fun (full, id) ->
      let short =
        if String.length full > String.length inner + 1 && String.sub full 0 (String.length inner) = inner then
          String.sub full (String.length inner + 1) (String.length full - String.length inner - 1)
        else match String.rindex_opt full '.' with Some i -> String.sub full (i + 1) (String.length full - i - 1) | None -> full
      in
      if id < Array.length prog.P.references then Hashtbl.replace refs short prog.P.references.(id))
    hint.ref_ids;
  { prog; hint; scopes; refs; plans = Hashtbl.create 4 }

let rec eval vm ctx (r : P.reference) (e : P.expr) : int =
  match e with
  | P.Reg_ap ->
      if r.r_group <> ctx.hint.h_group then fail "AP tracking group mismatch when evaluating a reference";
      let ap = vm.ap - (ctx.hint.h_offset - r.r_offset) in
      if ap < 0 then fail "Invalid ap correction";
      Felt.reloc 1 ap
  | P.Reg_fp -> Felt.reloc 1 vm.fp
  | P.Int z -> Felt.of_z z
  | P.Deref e ->
      let a = eval vm ctx r e in
      if not (Felt.is_reloc a) then fail "Dereference of a non-pointer in reference";
      let v = get vm (Felt.rseg a) (Felt.roff a) in
      if v = 0 then fail "Unknown memory cell %d:%d while evaluating a reference" (Felt.rseg a) (Felt.roff a);
      v
  | P.Add (a, b) -> value_add (eval vm ctx r a) (eval vm ctx r b)
  | P.Sub (a, b) -> value_sub (eval vm ctx r a) (eval vm ctx r b)
  | P.Mul (a, b) -> value_mul (eval vm ctx r a) (eval vm ctx r b)
  | P.Neg a -> Felt.neg (eval vm ctx r a)
  | P.Cast (a, _) -> eval vm ctx r a
  | P.Tuple _ -> fail "Tuple references are not supported"

let find_ref ctx name =
  match Hashtbl.find_opt ctx.refs name with Some r -> r | None -> fail "Unknown identifier ids.%s" name

(* value of ids.name *)
let get_val vm ctx name =
  let r = find_ref ctx name in
  eval vm ctx r r.r_expr

(* address of ids.name: strip the outer dereference *)
let get_addr vm ctx name =
  let r = find_ref ctx name in
  let a = match r.r_expr with P.Deref e -> eval vm ctx r e | e -> eval vm ctx r e in
  if not (Felt.is_reloc a) then fail "ids.%s has no address" name;
  a

let set_val vm ctx name v =
  let a = get_addr vm ctx name in
  write_checked vm (Felt.rseg a) (Felt.roff a) v

let get_felt vm ctx name =
  let v = get_val vm ctx name in
  if not (Felt.is_felt v) then fail "ids.%s: expected an integer" name;
  v

let get_z vm ctx name = Felt.to_z (get_felt vm ctx name)

let get_ptr vm ctx name =
  let v = get_val vm ctx name in
  if not (Felt.is_reloc v) then fail "ids.%s: expected a relocatable" name;
  v

(* ---- types and struct members ---- *)

let strip_star t = if String.length t > 0 && t.[String.length t - 1] = '*' then Some (String.sub t 0 (String.length t - 1)) else None

let var_type ctx name =
  let r = find_ref ctx name in
  match r.r_expr with
  | P.Deref (P.Cast (_, t)) -> (match strip_star t with Some t -> t | None -> t)
  | P.Cast (_, t) -> t
  | _ -> "felt"

let resolve_ident ctx name =
  let rec go n d =
    if d > 32 then None
    else
      match Hashtbl.find_opt ctx.prog.P.identifiers n with
      | Some { P.i_type = "alias"; i_destination = Some dst; _ } -> go dst (d + 1)
      | x -> x
  in
  go name 0

let member_offset ctx struct_t m =
  match resolve_ident ctx struct_t with
  | Some id -> (
      match List.assoc_opt m id.P.i_members with
      | Some o -> o
      | None -> fail "Struct %s has no member %s" struct_t m)
  | None -> fail "Unknown struct type %s" struct_t

(* address of ids.a.b.c: struct variables are addressed in place, pointers are followed *)
let member_plan ctx name path =
  let t = var_type ctx name in
  let is_ptr, st = match strip_star t with Some st -> (true, st) | None -> (false, t) in
  let rec go st = function
    | [] -> []
    | [ m ] -> [ Off (member_offset ctx st m) ]
    | m :: rest ->
        let off = member_offset ctx st m in
        let mt =
          match resolve_ident ctx st with
          | Some id -> (
              match List.assoc_opt m id.P.i_member_types with Some x -> x | None -> fail "Unknown type of %s.%s" st m)
          | None -> fail "Unknown struct %s" st
        in
        (match strip_star mt with Some st' -> Off off :: Follow :: go st' rest | None -> Off off :: go mt rest)
  in
  (is_ptr, go st path)

(* address of ids.a.b.c: struct variables are addressed in place, pointers are followed *)
let member_addr vm ctx name path =
  let key = (name, path) in
  let is_ptr, plan =
    match Hashtbl.find_opt ctx.plans key with
    | Some p -> p
    | None ->
        let p = member_plan ctx name path in
        Hashtbl.replace ctx.plans key p;
        p
  in
  let base = if is_ptr then get_ptr vm ctx name else get_addr vm ctx name in
  List.fold_left
    (fun a st ->
      match st with
      | Off k -> if k = 0 then a else value_add a (Felt.small k)
      | Follow ->
          let p = get vm (Felt.rseg a) (Felt.roff a) in
          if not (Felt.is_reloc p) then fail "Expected pointer in member path of ids.%s" name;
          p)
    base plan

let get_member vm ctx name path =
  let a = member_addr vm ctx name path in
  let v = get vm (Felt.rseg a) (Felt.roff a) in
  if v = 0 then fail "ids.%s.%s is not assigned" name (String.concat "." path);
  v

let get_member_z vm ctx name path =
  let v = get_member vm ctx name path in
  if not (Felt.is_felt v) then fail "ids.%s.%s: expected an integer" name (String.concat "." path);
  Felt.to_z v

let set_member vm ctx name path v =
  let a = member_addr vm ctx name path in
  write_checked vm (Felt.rseg a) (Felt.roff a) v

(* ---- constants (ids.NAME for const identifiers) ---- *)

let const_z ctx name =
  let from_scopes =
    List.find_map
      (fun sc ->
        match resolve_ident ctx (sc ^ "." ^ name) with
        | Some { P.i_type = "const"; i_value = Some v; _ } -> Some v
        | _ -> None)
      (List.rev ctx.hint.scopes)
  in
  match from_scopes with
  | Some v -> v
  | None -> (
      let suffix = "." ^ name in
      let found = ref None in
      Hashtbl.iter
        (fun k (id : P.ident) ->
          if !found = None && id.i_type = "const" && String.length k > String.length suffix
             && String.sub k (String.length k - String.length suffix) (String.length suffix) = suffix
          then found := id.i_value)
        ctx.prog.P.identifiers;
      match !found with Some v -> v | None -> fail "Missing constant %s" name)

(* ---- misc helpers ---- *)

let ap_addr vm = (1, vm.ap)
let write_ap vm v = write_checked vm 1 vm.ap v
let zf z = Felt.of_z z
let of_bool b = if b then Felt.one else Felt.zero

let write_arg vm ptr (vals : int list) =
  if not (Felt.is_reloc ptr) then fail "write_arg: expected a pointer";
  List.iteri (fun i v -> write_checked vm (Felt.rseg ptr) (Felt.roff ptr + i) v) vals

let gen_arg vm (vals : int list) =
  let s = add_segment vm in
  write_arg vm (Felt.reloc s 0) vals;
  Felt.reloc s 0

let read_range vm ptr n =
  List.init n (fun i ->
      let v = get vm (Felt.rseg ptr) (Felt.roff ptr + i) in
      if v = 0 then fail "Unknown memory cell %d:%d" (Felt.rseg ptr) (Felt.roff ptr + i);
      v)

let mem_at vm ptr k =
  let v = get vm (Felt.rseg ptr) (Felt.roff ptr + k) in
  if v = 0 then fail "Unknown memory cell %d:%d" (Felt.rseg ptr) (Felt.roff ptr + k);
  v

let rc_bound = Z.shift_left Z.one 128

let as_int z = if Z.lt z (Z.shift_right Felt.p 1) then z else Z.sub z Felt.p
