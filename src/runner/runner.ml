open Errors
open Builtin
open Vm
open Cpu

let layout_builtins = function
  | "plain" -> Some []
  | "small" | "dex" | "perpetual" -> Some [ Output; Pedersen; Range_check; Ecdsa ]
  | "dex_with_bitwise" -> Some [ Output; Pedersen; Range_check; Ecdsa; Bitwise ]
  | "recursive" -> Some [ Output; Pedersen; Range_check; Bitwise ]
  | "recursive_with_poseidon" | "recursive_large_output" -> Some [ Output; Pedersen; Range_check; Bitwise; Poseidon ]
  | "starknet" -> Some [ Output; Pedersen; Range_check; Ecdsa; Bitwise; Ec_op; Poseidon ]
  | "starknet_with_keccak" -> Some [ Output; Pedersen; Range_check; Ecdsa; Bitwise; Ec_op; Keccak; Poseidon ]
  | "all_solidity" -> Some [ Output; Pedersen; Range_check; Ecdsa; Bitwise; Ec_op ]
  | "all_cairo" -> Some [ Output; Pedersen; Range_check; Ecdsa; Bitwise; Ec_op; Keccak; Poseidon; Range_check96; Add_mod; Mul_mod ]
  | "all_cairo_stwo" -> Some [ Output; Pedersen; Range_check; Bitwise; Ec_op; Poseidon; Range_check96; Add_mod; Mul_mod ]
  | "stwo_no_ecop" -> Some [ Output; Pedersen; Range_check; Bitwise; Poseidon; Range_check96; Add_mod; Mul_mod ]
  | "dynamic" ->
      Some ([ Output; Pedersen; Range_check; Ecdsa; Bitwise; Ec_op; Keccak; Poseidon; Range_check96 ]
            @ if Layout.with_mod_builtin then [ Add_mod; Mul_mod ] else [])
  | _ -> None

type config = {
  layout : string;
  trace : bool;
  secure_run : bool;
  allow_missing_builtins : bool;
  entrypoint : string;
}

(* Accessed-address bookkeeping for memory-hole counting. cairo-vm marks the
   pc, dst, op0 and op1 cells of every executed instruction and the whole
   program segment. We recover the same set from the trace, together with
   the instruction-offset range-check limits. *)
type accessed = {
  mutable bits : Bytes.t array;
  mutable count : int array;
  mutable cursor : int; (* trace words processed *)
  mutable rc_lo : int; (* rc_lo > rc_hi = no instruction seen *)
  mutable rc_hi : int;
}

type t = {
  vm : vm;
  prog : Program.t;
  end_seg : int; (* execution mode only *)
  hints : (vm -> unit) array array;
  prog_builtins : bkind list;
  scopes : Hintrt.scopes;
  proof : bool;
  layout : Layout.t option; (* proof mode only *)
  end_pc : int; (* proof mode: offset of __end__ in segment 0 *)
  initial_fp : int;
  mutable exec_public : int list; (* reversed offsets of public execution memory *)
  mutable eff_sizes : int array option; (* segment used sizes, fixed at end_run *)
  seg_sizes : (int, int) Hashtbl.t; (* finalized segment sizes *)
  public_offsets : (int, (int * int) list) Hashtbl.t; (* segment -> (offset, page) *)
  acc : accessed;
  mutable zero_seg : int; (* mod builtins' zero segment, -1 if none *)
  mutable zero_size : int;
}

let rec is_subsequence xs ys =
  match (xs, ys) with
  | [], _ -> true
  | _, [] -> false
  | x :: xs', y :: ys' -> if x = y then is_subsequence xs' ys' else is_subsequence xs ys'

let compile_hints prog =
  let scopes = Hintrt.new_scopes () in
  let hints = Array.make (Array.length prog.Program.data) [||] in
  List.iter
    (fun (pc, hs) ->
      if pc < Array.length hints then
        hints.(pc) <- Array.of_list (List.map (fun h -> Hints.compile prog scopes h) hs))
    prog.hints;
  (scopes, hints)

let entry_pc (cfg : config) (prog : Program.t) =
  let name = cfg.entrypoint in
  let full = "__main__." ^ name in
  match Hashtbl.find_opt prog.identifiers full with
  | Some { Program.i_pc = Some pc; _ } -> pc
  | _ -> ( match (name, prog.main) with "main", Some pc -> pc | _ -> fail "Entrypoint %s not found" name)

(* cairo-vm creates the mod builtins' shared zero segment after the
   entrypoint segments (CairoRunner::initialize) *)
let add_zero_segment r =
  match List.filter (fun b -> b.kind = Add_mod || b.kind = Mul_mod) r.vm.builtins with
  | [] -> r
  | mods ->
      let seg = Builtins_ext.add_zero_segment r.vm mods in
      { r with zero_seg = seg; zero_size = used_size r.vm seg }

let initialize ?layout_def ?(proof = false) (cfg : config) (prog : Program.t) : t =
  let prog_builtins =
    List.map
      (fun n -> match bkind_of_name n with Some k -> k | None -> fail "Unknown builtin %s" n)
      prog.builtins
  in
  if not (is_subsequence prog_builtins all_builtins) then fail "Disordered builtins";
  let layout_kinds, layout_def =
    if proof then begin
      let l =
        match layout_def with
        | Some l -> l
        | None -> ( match Layout.of_name cfg.layout with Some l -> l | None -> fail "Unsupported layout %s" cfg.layout)
      in
      (Layout.builtin_kinds l, Some l)
    end
    else ((match layout_builtins cfg.layout with Some l -> l | None -> fail "Unsupported layout %s" cfg.layout), None)
  in
  List.iter
    (fun b ->
      if (not (List.mem b layout_kinds)) && not cfg.allow_missing_builtins then
        fail "Program uses builtin %s, which is not present in layout %s" (bname b) cfg.layout)
    prog_builtins;
  Builtins_ext.reset ();
  Builtins_ext.install ();
  Opcode_ext.install ();
  (* proof mode always records the trace: memory-hole accounting replays it *)
  let vm = create ~trace:(cfg.trace || proof) in
  let s0 = add_segment vm in
  let s1 = add_segment vm in
  assert (s0 = 0 && s1 = 1);
  (* execution mode: program builtins only; proof mode: every layout builtin *)
  let active = if proof then layout_kinds else List.filter (fun b -> List.mem b prog_builtins) layout_kinds in
  let builtins =
    List.map
      (fun k ->
        let seg = add_segment vm in
        let b = { kind = k; base = seg; stop_ptr = -1; cache = [||] } in
        vm.seg_builtin.(seg) <- Some b;
        vm.seg_flag.(seg) <- flag_of k;
        b)
      active
  in
  vm.builtins <- builtins;
  (* program image *)
  Array.iteri (fun i z -> write vm 0 i (Felt.of_z z)) prog.data;
  let builtin_stack =
    List.map
      (fun k ->
        match List.find_opt (fun b -> b.kind = k) builtins with
        | Some b -> Felt.reloc b.base 0
        | None -> Felt.zero)
      prog_builtins
  in
  let base =
    {
      vm; prog; end_seg = -1; hints = [||]; prog_builtins; scopes = Hintrt.new_scopes (); proof; layout = layout_def;
      end_pc = -1; initial_fp = 0; exec_public = []; eff_sizes = None; seg_sizes = Hashtbl.create 16;
      public_offsets = Hashtbl.create 16;
      acc = { bits = [||]; count = [||]; cursor = 0; rc_lo = max_int; rc_hi = min_int };
      zero_seg = -1; zero_size = 0;
    }
  in
  let base =
    if proof then begin
      ignore (entry_pc cfg prog);
      let start = match prog.start with Some s -> s | None -> fail "Missing __start__ label (NoProgramStart)" in
      let end_pc = match prog.end_ with Some e -> e | None -> fail "Missing __end__ label (NoProgramEnd)" in
      (* canonical proof mode: [exec + 2, 0, builtins...] with fp = ap = exec + 2 *)
      let stack = Felt.reloc 1 2 :: Felt.zero :: builtin_stack in
      List.iteri (fun i v -> write vm 1 i v) stack;
      vm.pc_seg <- 0;
      vm.pc <- start;
      vm.ap <- 2;
      vm.fp <- 2;
      { base with end_pc; initial_fp = 2; exec_public = List.rev (List.init (List.length stack) Fun.id) }
      |> add_zero_segment
    end
    else begin
      let return_fp = add_segment vm in
      let end_seg = add_segment vm in
      let entry = entry_pc cfg prog in
      let stack = builtin_stack @ [ Felt.reloc return_fp 0; Felt.reloc end_seg 0 ] in
      List.iteri (fun i v -> write vm 1 i v) stack;
      let n = List.length stack in
      vm.pc_seg <- 0;
      vm.pc <- entry;
      vm.ap <- n;
      vm.fp <- n;
      { base with end_seg; initial_fp = n } |> add_zero_segment
    end
  in
  let scopes, hints = compile_hints prog in
  { base with scopes; hints }

(* ---- running ---- *)

let run_for_steps r n = run ~steps:n r.vm r.hints

let run_until_end r =
  if r.proof then begin
    run ~stop:(0, r.end_pc) r.vm r.hints;
    (* one more step so that __end__ is the last executed instruction *)
    run_for_steps r 1
  end
  else run ~stop:(r.end_seg, 0) r.vm r.hints
