open Cairovm
open Yojson.Safe.Util

let bounded limit n =
  if n < 0 || n > limit then invalid_arg "integer outside probe limits";
  n

let offset = bounded 65_535
let int_field name json = member name json |> to_int
let pair seg off = `List [`Int seg; `Int off]

let address json =
  match to_list json with
  | [`Int seg; `Int off] -> bounded 63 seg, offset off
  | _ -> invalid_arg "expected [segment,offset]"

let decode_value = function
  | `Assoc ["felt", `String text] ->
      let n = Z.of_string text in
      if Z.sign n < 0 || Z.geq n Felt.p || Z.to_string n <> text then invalid_arg "noncanonical felt";
      Felt.of_z n
  | `Assoc ["ptr", json] ->
      let seg, off = address json in
      Felt.reloc seg off
  | _ -> invalid_arg "expected tagged value"

let encode_value v =
  if Felt.is_reloc v then `Assoc ["ptr", pair (Felt.rseg v) (Felt.roff v)]
  else `Assoc ["felt", `String (Z.to_string (Felt.to_z v))]

let empty_program =
  Program.{ data = [||]; builtins = []; main = Some 0; start = None; end_ = None;
            hints = []; references = [||]; identifiers = Hashtbl.create 0 }

let initialize request segments =
  let cfg = Runner.{ trace = false; layout = "plain"; secure_run = false;
                     allow_missing_builtins = true; entrypoint = "main" } in
  let context = Runner.initialize cfg empty_program in
  (* Access markers are observable even when the caller requests no trace.
     The runner recovers those markers from its internal instruction trace. *)
  let vm = Vm.create ~trace:true in
  vm.allow_legacy_instructions <- true;
  for _ = 1 to segments do ignore (Vm.add_segment vm) done;
  (match member "pedersen_segment" request with
   | `Null -> ()
   | `Int n when n >= 2 && n < segments ->
       let b = Builtin.{ kind = Pedersen; base = n; stop_ptr = -1; cache = [||] } in
       vm.seg_builtin.(n) <- Some b;
       vm.seg_flag.(n) <- Builtin.flag_of Pedersen;
       vm.builtins <- [b]
   | _ -> invalid_arg "invalid Pedersen segment");
  { context with vm }

let memory_records (runner : Runner.t) =
  let vm = runner.vm and records = ref [] in
  for seg = 0 to vm.nsegs - 1 do
    for off = 0 to vm.hi.(seg) - 1 do
      let v = Vm.get vm seg off in
      if v <> Felt.empty then begin
        let accessed = Resources.range_accessed runner (Felt.reloc seg off) 1 in
        records := `List [pair seg off; encode_value v; `Bool accessed] :: !records
      end
    done
  done;
  `List (List.rev !records)

let relocated_trace (vm : Vm.vm) =
  let starts = Array.make vm.nsegs 1 in
  for i = 1 to vm.nsegs - 1 do starts.(i) <- starts.(i - 1) + vm.hi.(i - 1) done;
  let rec scan cursor entries =
    if cursor = vm.tlen then `List (List.rev entries)
    else
      let next, seg, pc, ap, fp = Resources.trace_entry vm.trace cursor in
      let entry = `List [`Int (starts.(seg) + pc); `Int (starts.(1) + ap); `Int (starts.(1) + fp)] in
      scan next (entry :: entries)
  in
  scan 0 []

let pedersen_data (vm : Vm.vm) (b : Builtin.builtin) =
  let verified = ref [] and inputs = ref [] in
  let hex v = `String ("0x" ^ Z.format "%x" (Felt.to_z v)) in
  for i = 0 to (vm.hi.(b.base) + 2) / 3 - 1 do
    let out = 3 * i + 2 in
    if out < Array.length b.cache && b.cache.(out) <> Felt.empty then
      verified := pair b.base out :: !verified;
    let x = Vm.get vm b.base (out - 2) and y = Vm.get vm b.base (out - 1) in
    if x <> Felt.empty && y <> Felt.empty && Felt.is_felt x && Felt.is_felt y then
      inputs := `Assoc ["index", `Int i; "x", hex x; "y", hex y] :: !inputs
  done;
  `List [`String (Builtin.bname b.kind); `List (List.rev !verified); `List (List.rev !inputs)]

let run request =
  if int_field "schema" request <> 1 then invalid_arg "unknown schema";
  let segments = bounded 64 (int_field "segments" request) in
  if segments < 2 then invalid_arg "need program and execution segments";
  let checked_address json =
    let seg, off = address json in
    if seg >= segments then invalid_arg "unallocated segment";
    seg, off
  in
  let runner = initialize request segments in
  let vm = runner.vm in
  let set_pc json = let seg, off = checked_address json in vm.pc_seg <- seg; vm.pc <- off in
  let write addr v = let seg, off = checked_address addr in Vm.write_checked vm seg off (decode_value v) in
  let memory = to_list (member "memory" request) in
  ignore (bounded 262_144 (List.length memory));
  List.iter (function `List [a; v] -> write a v | _ -> invalid_arg "malformed cell") memory;
  let registers = member "registers" request in
  set_pc (member "pc" registers);
  vm.ap <- offset (int_field "ap" registers);
  vm.fp <- offset (int_field "fp" registers);
  let attempted = ref 0 and failure = ref None in
  let blake = ref 0 and blake_finalize = ref 0 in
  let step () =
    let word = Vm.get vm vm.pc_seg vm.pc in
    (try
       Cpu.step vm;
       if Felt.is_felt word then begin
         let ext = Z.shift_right (Felt.to_z word) 63 in
         if Z.equal ext Z.one then incr blake
         else if Z.equal ext (Z.of_int 2) then incr blake_finalize
       end
     with Errors.Vm_error msg -> failure := Some (`Assoc ["step", `Int !attempted; "error", `String msg]));
    incr attempted
  in
  let act = function
    | `Assoc ["step", `Int count] ->
        ignore (bounded (65_535 - !attempted) count);
        for _ = 1 to count do if !failure = None then step () done
    | `Assoc ["pc", addr] -> set_pc addr
    | `Assoc ["fp", `Int n] -> vm.fp <- offset n
    | `Assoc ["skip", `Bool true] -> Cpu.skip_instruction vm
    | `Assoc ["replace_unaccessed", `List [addr; v]] ->
        let seg, off = checked_address addr in
        if Resources.range_accessed runner (Felt.reloc seg off) 1 then invalid_arg "cell already accessed";
        if Vm.get vm seg off = Felt.empty then invalid_arg "cell is absent";
        Vm.clear_code_cell vm seg off;
        write addr v
    | _ -> invalid_arg "unknown action"
  in
  let actions = to_list (member "actions" request) in
  ignore (bounded 262_144 (List.length actions));
  List.iter (fun action -> if !failure = None then act action) actions;
  let resource (name, count) =
    if !count = 0 then None else Some (`List [`String name; `Int !count]) in
  `Assoc [
    "schema", `Int 1;
    "registers", `List [pair vm.pc_seg vm.pc; pair 1 vm.ap; pair 1 vm.fp];
    "steps", `Int vm.steps;
    "trace", (if to_bool (member "trace" request) then relocated_trace vm else `List []);
    "memory", memory_records runner;
    "builtins", `List (List.map (pedersen_data vm) vm.builtins);
    "extended_resources", `List (List.filter_map resource ["Blake", blake; "BlakeFinalize", blake_finalize]);
    "failure", Option.value ~default:`Null !failure;
  ]

let () =
  try
    Yojson.Safe.to_channel stdout (run (Yojson.Safe.from_channel stdin));
    print_newline ()
  with exn -> prerr_endline (Printexc.to_string exn); exit 2
