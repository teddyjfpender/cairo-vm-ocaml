(* Hint runtime: execution scopes and `ids` access.

   Hints are adversarial witnesses for soundness: everything they write goes
   through the same write-once memory and builtin validation as the CPU. *)

open Errors
open Vm
module P = Program

(* Monomorphic tables: generic Hashtbl hashing and comparison dominated
   hint-heavy programs. *)
module Felt_tbl = Hashtbl.Make (struct
  type t = Felt.t
  let equal = Felt.equal
  let hash = Felt.hash
end)

module Int_tbl = Hashtbl.Make (struct
  type t = int
  let equal = Int.equal
  let hash = Felt.mix
end)

module Dict_changes = Map.Make (struct
  type t = Felt.t
  let compare (a : t) (b : t) = Int.compare (a :> int) (b :> int)
end)
type snapshot = Felt.t Felt_tbl.t * Felt.t Dict_changes.t

type dict_tracker = {
  data : Felt.t Felt_tbl.t; (* canonical key -> value *)
  mutable changes : Felt.t Dict_changes.t option; (* Some freezes data for snapshots *)
  default : Felt.t option;
  mutable current_ptr : Felt.t; (* relocatable *)
}

type dyn =
  | Int of Z.t
  | Value of Felt.t
  | Ints of int list
  | Values of Felt.t list
  | Dict_manager of dict_tracker Int_tbl.t (* by segment index *)
  | Access_indices of int list Felt_tbl.t
  | Positions of int list Felt_tbl.t
  | Dict_snapshot of snapshot
  | Initial_dict of Felt.t Felt_tbl.t
  | Nothing

(* Hint bodies pass literal names, so a physical match almost always settles
   a lookup in these short association lists before any string comparison. *)
let named name l = match List.assq_opt name l with None -> List.assoc_opt name l | hit -> hit

(* A scope holds a handful of variables. *)
type frame = { mutable vars : (string * dyn ref) list }
type scopes = { mutable stack : frame list }

let new_scopes () = { stack = [ { vars = [] } ] }
let only_main_scope s = List.length s.stack = 1
let top s = List.hd s.stack

let assign f name v =
  match named name f.vars with Some r -> r := v | None -> f.vars <- (name, ref v) :: f.vars

let enter s vars =
  let f = { vars = [] } in
  List.iter (fun (k, v) -> assign f k v) vars;
  s.stack <- f :: s.stack

let exit_scope s =
  match s.stack with
  | [ _ ] -> fail "Cannot exit main scope."
  | _ :: rest -> s.stack <- rest
  | [] -> assert false

let var_opt s name = match named name (top s).vars with Some r -> Some !r | None -> None
let var s name = match var_opt s name with Some v -> v | None -> fail "Variable %s not present in current execution scope" name
let set s name v = assign (top s) name v
let del s name = let f = top s in f.vars <- List.filter (fun (n, _) -> not (String.equal n name)) f.vars

let var_z s name = match var s name with Int z -> z | Value v when Felt.is_felt v -> Felt.to_z v | _ -> fail "Variable %s is not an integer" name

(* ---- canonical keys (big felts interned so keys are plain ints) ---- *)

module Felt_keys = Hashtbl.Make (struct
  type t = Felt.t
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

type access = { value : vm -> Felt.t; address : vm -> Felt.t }

type ctx = {
  prog : P.t;
  hint : P.hint;
  scopes : scopes;
  refs : (string, P.reference) Hashtbl.t; (* short name -> reference *)
  mutable constants : (string * Z.t option) list;
  (* Per-hint memos with a handful of entries: assoc lists beat hashing. *)
  mutable bindings : (string * access) list;
  mutable plans : (string * string list * (bool * step list)) list; (* member paths *)
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
  { prog; hint; scopes; refs; constants = []; bindings = []; plans = [] }

let read_reference vm a =
  if not (Felt.is_reloc a) then fail "Dereference of a non-pointer in reference";
  let v = get vm (Felt.rseg a) (Felt.roff a) in
  if v = Felt.empty then fail "Unknown memory cell %d:%d while evaluating a reference" (Felt.rseg a) (Felt.roff a);
  v

let rec eval vm ctx (r : P.reference) (e : P.expr) : Felt.t =
  match e with
  | P.Reg_ap ->
      if r.r_group <> ctx.hint.h_group then fail "AP tracking group mismatch when evaluating a reference";
      let ap = vm.ap - (ctx.hint.h_offset - r.r_offset) in
      if ap < 0 then fail "Invalid ap correction";
      Felt.reloc 1 ap
  | P.Reg_fp -> Felt.reloc 1 vm.fp
  | P.Int z -> Felt.of_z z
  | P.Deref e -> read_reference vm (eval vm ctx r e)
  | P.Add (a, b) -> value_add (eval vm ctx r a) (eval vm ctx r b)
  | P.Sub (a, b) -> value_sub (eval vm ctx r a) (eval vm ctx r b)
  | P.Mul (a, b) -> value_mul (eval vm ctx r a) (eval vm ctx r b)
  | P.Neg a -> Felt.neg (eval vm ctx r a)
  | P.Cast (a, _) -> eval vm ctx r a
  | P.Tuple _ -> fail "Tuple references are not supported"

let find_ref ctx name =
  match Hashtbl.find_opt ctx.refs name with Some r -> r | None -> fail "Unknown identifier ids.%s" name

(* Resolve the register, constant displacements and dereferences once per
   used binding. AP group and address checks still run at the access site. *)
let rec compile_expr ctx (r : P.reference) expr =
  let immediate n = let code = Felt.of_z n in fun _ -> code in
  match expr with
  | P.Cast (e, _) -> compile_expr ctx r e
  | P.Int n -> immediate n
  | P.Neg (P.Int n) -> immediate (Z.neg n)
  | P.Reg_fp -> (fun vm -> Felt.reloc 1 vm.fp)
  | P.Reg_ap ->
      let delta = ctx.hint.h_offset - r.r_offset in
      if r.r_group <> ctx.hint.h_group then
        (fun _ -> fail "AP tracking group mismatch when evaluating a reference")
      else (fun vm ->
        let ap = vm.ap - delta in
        if ap < 0 then fail "Invalid ap correction";
        Felt.reloc 1 ap)
  | P.Deref e ->
      let addr = compile_expr ctx r e in
      (fun vm -> read_reference vm (addr vm))
  | P.Add (e, P.Int n) | P.Add (e, P.Neg (P.Int n)) ->
      let n = match expr with P.Add (_, P.Neg _) -> Z.neg n | _ -> n in
      let offset = Felt.of_z n in
      (match e with
       | P.Reg_fp -> fun vm -> reloc_add_felt (Felt.reloc 1 vm.fp) offset
       | _ -> let base = compile_expr ctx r e in fun vm -> value_add (base vm) offset)
  | _ -> (fun vm -> eval vm ctx r expr)

let binding ctx name =
  match named name ctx.bindings with
  | Some plan -> plan
  | None ->
      let r = find_ref ctx name in
      let plan = match r.r_expr with
        | P.Deref e ->
            let address = compile_expr ctx r e in
            {address; value = (fun vm -> read_reference vm (address vm))}
        | e ->
            let read = compile_expr ctx r e in
            {address = read; value = read}
      in
      ctx.bindings <- (name, plan) :: ctx.bindings;
      plan

let get_val vm ctx name = (binding ctx name).value vm

let get_addr vm ctx name =
  let a = (binding ctx name).address vm in
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

(* Physical match first, as in [named]; [all] is the whole memo. *)
let rec find_plan name path all = function
  | [] -> List.find_map (fun (n, p, plan) -> if String.equal n name && p = path then Some plan else None) all
  | (n, p, plan) :: rest -> if n == name && p == path then Some plan else find_plan name path all rest

(* address of ids.a.b.c: struct variables are addressed in place, pointers are followed *)
let member_addr vm ctx name path =
  let is_ptr, plan =
    match find_plan name path ctx.plans ctx.plans with
    | Some p -> p
    | None ->
        let p = member_plan ctx name path in
        ctx.plans <- (name, path, p) :: ctx.plans;
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
  if v = Felt.empty then fail "ids.%s.%s is not assigned" name (String.concat "." path);
  v

let get_member_z vm ctx name path =
  let v = get_member vm ctx name path in
  if not (Felt.is_felt v) then fail "ids.%s.%s: expected an integer" name (String.concat "." path);
  Felt.to_z v

let set_member vm ctx name path v =
  let a = member_addr vm ctx name path in
  write_checked vm (Felt.rseg a) (Felt.roff a) v

(* ---- constants (ids.NAME for const identifiers) ---- *)

let resolve_constant ctx name =
  let from_scopes =
    List.find_map
      (fun sc ->
        match resolve_ident ctx (sc ^ "." ^ name) with
        | Some { P.i_type = "const"; i_value = Some v; _ } -> Some v
        | _ -> None)
      (List.rev ctx.hint.scopes)
  in
  match from_scopes with
  | Some _ as value -> value
  | None -> (
      let suffix = "." ^ name in
      let found = ref None in
      Hashtbl.iter
        (fun k (id : P.ident) ->
          if !found = None && id.i_type = "const" && String.length k > String.length suffix
             && String.sub k (String.length k - String.length suffix) (String.length suffix) = suffix
          then found := id.i_value)
        ctx.prog.P.identifiers;
      !found)

(* The identifier table and accessible scopes are fixed for a compiled hint.
   Cache misses too: optional constants can otherwise scan every identifier
   on every iteration. Keep lookup lazy for hints that never execute. *)
let const_opt ctx name =
  match named name ctx.constants with
  | Some cached -> cached
  | None ->
      let value = resolve_constant ctx name in
      ctx.constants <- (name, value) :: ctx.constants;
      value

let const_z ctx name =
  match const_opt ctx name with Some v -> v | None -> fail "Missing constant %s" name

(* ---- misc helpers ---- *)

let ap_addr vm = (1, vm.ap)
let write_ap vm v = write_checked vm 1 vm.ap v
let zf z = Felt.of_z z
let of_bool b = if b then Felt.one else Felt.zero

let write_arg vm ptr (vals : Felt.t list) =
  if not (Felt.is_reloc ptr) then fail "write_arg: expected a pointer";
  List.iteri (fun i v -> write_checked vm (Felt.rseg ptr) (Felt.roff ptr + i) v) vals

let gen_arg vm (vals : Felt.t list) =
  let s = add_segment vm in
  write_arg vm (Felt.reloc s 0) vals;
  Felt.reloc s 0

let read_range vm ptr n =
  List.init n (fun i ->
      let v = get vm (Felt.rseg ptr) (Felt.roff ptr + i) in
      if v = Felt.empty then fail "Unknown memory cell %d:%d" (Felt.rseg ptr) (Felt.roff ptr + i);
      v)

let mem_at vm ptr k =
  let v = get vm (Felt.rseg ptr) (Felt.roff ptr + k) in
  if v = Felt.empty then fail "Unknown memory cell %d:%d" (Felt.rseg ptr) (Felt.roff ptr + k);
  v

let rc_bound = Z.shift_left Z.one 128

let as_int z = if Z.lt z Felt.half_p then z else Z.sub z Felt.p
