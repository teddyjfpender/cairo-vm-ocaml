(* Stateful hint processor for cairo-program-runner-lib's simple bootloader. *)
open Errors
open Hintrt
module U = Yojson.Safe.Util
module Code = Bootloader_codes

type task = { program : Program.t; hash_function : int; pie : Pie_file.t option; source : Pie_file.memory_source option }

let read_task j =
  let member name = U.member name j in
  let program, pie, source = match member "type" with
    | `String "RunProgramTask" ->
        let p = match member "program", member "path" with
          | `Assoc _ as p, _ -> Program.load_json p
          | `Null, `String path -> Program.load_file path
          | _ -> fail "RunProgramTask needs a compiled program or path" in
        p, None, None
    | `String "CairoPiePath" ->
        let pie,source = Pie_file.read_deferred (U.to_string (member "path")) in
        Pie_run.stripped_program pie, Some pie, Some source
    | _ -> fail "Unsupported bootloader task type" in
  let hash_function = match String.lowercase_ascii (U.to_string (member "program_hash_function")) with
    | "pedersen" -> 0 | "poseidon" -> 1 | "blake" -> 2
    | value -> fail "Unknown program hash function %s" value in
  { program; hash_function; pie; source }

let initialize ?(on_pie_loaded=ignore) ?layout_def ~proof ~path cfg prog =
  let input = Yojson.Safe.from_file path in
  let tasks = Array.of_list (U.to_list (U.member "tasks" input)) in
  let active = ref None and previous = ref None and address = ref Felt.empty in
  let current () = match !active with Some task -> task | None -> fail "No current bootloader task" in
  let topologies = ref [] and runner = ref None in
  let table = Hashtbl.create 32 in
  let register code f = Hashtbl.add table code f in
  Builtin_selection.register register;
  register Code.read_input (fun _ _ -> ());
  register "SETUP_RUN_SIMPLE_BOOTLOADER_BEFORE_TASK_EXECUTION" (fun c vm ->
      write_arg vm (get_ptr vm c "output_ptr") [Felt.small (Array.length tasks)];
      set_val vm c "initial_subtasks_range_check_ptr" (Felt.reloc (Vm.add_temp_segment vm) 0));
  register "SIMPLE_BOOTLOADER_SET_CURRENT_TASK" (fun c vm ->
      let index = Array.length tasks - Felt.to_nat (get_felt vm c "n_tasks") in
      if index < 0 || index >= Array.length tasks then fail "Invalid bootloader task index";
      previous := Option.map (fun task -> task.program) !active;
      active := Some (read_task tasks.(index)));
  register "DETERMINE_USE_PREV_HASH" (fun c vm ->
      let p = (current ()).program in
      let same = match !previous with
        | None -> false
        | Some prev -> p.builtins = prev.builtins && p.main = prev.main && p.data = prev.data in
      set_val vm c "use_prev_hash" (of_bool same));
  register "memory[ap] = to_felt_or_relocatable(task.program_hash_function)" (fun _ vm ->
      write_ap vm (Felt.small (current ()).hash_function));
  register "memory[ap] = to_felt_or_relocatable(ids.num // 2)" (fun c vm ->
      write_ap vm (Felt.of_z (Z.shift_right (Felt.to_z (get_felt vm c "num")) 1)));
  register "LOAD_PROGRAM_SEGMENT" (fun c vm ->
      let p = (current ()).program in
      let seg = Vm.add_segment vm in
      set_val vm c "program_segment_ptr" (Felt.reloc seg 0);
      let base = get_ptr vm c "program_header" in
      let header = 4 + List.length p.builtins in
      let size = header + Array.length p.data in
      let main = match p.main with Some pc -> pc | None -> fail "Missing task main" in
      write_arg vm base (List.map Felt.small [size - 1; 0; main; List.length p.builtins]
        @ List.map (fun s -> Felt.of_z (z_of_be s)) p.builtins);
      address := Vm.value_add base (Felt.small header);
      Array.iteri (fun i z -> Vm.write_checked vm (Felt.rseg !address) (Felt.roff !address + i) (Felt.of_z z)) p.data;
      Hashtbl.replace (Option.get !runner).Runner.seg_sizes seg size);
  register Code.check_address (fun c vm ->
      if not (Felt.equal !address (get_ptr vm c "program_address")) then fail "Unexpected task program address");
  register Code.enter_task (fun c vm ->
      let p = (current ()).program in
      Option.iter (fun pie ->
          let pc name =
            let label = "starkware.cairo.bootloaders.simple_bootloader.execute_task.execute_task." ^ name in
            match Hashtbl.find_opt prog.Program.identifiers label with
            | Some { Program.i_pc = Some pc; _ } -> pc
            | _ -> fail "Missing bootloader label %s" label in
          let return = vm.Vm.pc + pc "ret_pc_label" - pc "call_task" in
          Pie_run.load_subtask ?source:(current ()).source vm pie ~code:!address ~stack:(Felt.reloc 1 (vm.ap - List.length p.builtins))
            ~ret_fp:(Felt.reloc 1 vm.fp) ~ret_pc:(Felt.reloc vm.pc_seg return);
          on_pie_loaded vm;
          (* Release the compressed mapping after the task memory is loaded. *)
          active := Some { (current ()) with source = None }) (current ()).pie;
      enter c.scopes [];
      List.iter (fun (offset, hints) ->
          Cpu.register_runtime_hints vm ~segment:(Felt.rseg !address) ~pc:(Felt.roff !address + offset)
            (Array.of_list (List.map (Hints.compile p c.scopes) hints))) p.hints);
  register Code.exit_task (fun c _ -> exit_scope c.scopes);
  register Code.return_builtins (fun c vm ->
      let names = (current ()).program.builtins in
      let used = get_ptr vm c "used_builtins_addr" and pre = get_addr vm c "pre_execution_builtin_ptrs" in
      let idx = ref 0 in
      write_arg vm (get_addr vm c "return_builtin_ptrs") (List.mapi (fun i kind ->
          if List.mem (Builtin.bname kind) names then begin
            let v = mem_at vm used !idx in incr idx;
            Option.iter (fun pie -> if Felt.is_reloc v then begin
                let consumed = Vm.value_sub v (mem_at vm pre i) in
                let info = List.assoc (Builtin.bname kind) pie.Pie_file.builtin_segments in
                if not (Felt.equal consumed (Felt.small info.size)) then fail "Task builtin usage mismatch"
              end) (current ()).pie;
            v
          end else mem_at vm pre i) Builtin.all_builtins);
      enter c.scopes ["n_selected_builtins", Value (Felt.small (List.length names))]);
  register Code.append_topology (fun c vm ->
      let ptr name = get_member vm c name ["output"] in
      let size = Felt.to_nat (Vm.value_sub (ptr "return_builtin_ptrs") (ptr "pre_execution_builtin_ptrs")) in
      let topology = match (current ()).pie with
        | None -> [1; 0], [size]
        | Some pie -> Bootloader_topology.of_pie pie size in
      topologies := topology :: !topologies);
  register Code.finish (fun _ _ ->
      let facts = List.rev !topologies in
      if U.member "single_page" input <> `Bool true then
        (Option.get !runner).Runner.output_pages <- Bootloader_topology.pages facts;
      match U.member "fact_topologies_path" input with
      | `Null -> ()
      | value -> Bootloader_topology.write (U.to_string value) facts);
  List.iter (fun (code, name, kind) -> register code (fun c vm ->
      let seg = Vm.add_segment vm in
      vm.seg_builtin.(seg) <- Some { Builtin.kind; base = seg; stop_ptr = -1; cache = [||] };
      vm.seg_flag.(seg) <- Builtin.flag_of kind;
      set_val vm c name (Felt.reloc seg 0)))
    [Code.simulate_ec, "new_ec_op_ptr", Builtin.Ec_op; Code.simulate_keccak, "new_keccak_ptr", Builtin.Keccak;
     Code.simulate_ecdsa, "new_ecdsa_ptr", Builtin.Ecdsa];
  let compile_hint p scopes h = match Hashtbl.find_opt table h.Program.code with
    | Some f -> f (make_ctx p scopes h)
    | None -> Hints.compile p scopes h in
  let r = Runner.initialize ?layout_def ~proof ~compile_hint cfg prog in
  runner := Some r;
  r
