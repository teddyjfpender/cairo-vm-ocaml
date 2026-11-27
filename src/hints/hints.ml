(* The hint table: every family module registers its implementations here,
   matched by exact code string as in cairo-vm's BuiltinHintProcessor. Each
   mirrors the cairo-vm v4.0.0 / cairo-lang 0.13.5 reference. Unknown hints
   fail when executed. *)

let table =
  lazy
    (let t = Hashtbl.create 256 in
     let reg code f =
       if Hashtbl.mem t code then invalid_arg ("Hints: registered twice: " ^ code);
       Hashtbl.add t code f
     in
     List.iter (fun register -> register reg)
       [ Segments.register; Math.register; Uint256.register; Uint384.register; Dict.register;
         Collections.register; Keccak.register; Blake2s.register; Sha256.register; Secp.register;
         Ec.register; Signature.register; Mod_circuit.register; Excess_balance.register ];
     (* Runtime counterpart of cairo-vm's `cairo-0-secp-hints` cargo feature
        (off by default, as in the reference CLI build). *)
     if Sys.getenv_opt "CAIRO_VM_CAIRO0_SECP_HINTS" = Some "1" then Secp.register_cairo0 reg;
     t)

let mem code = Hashtbl.mem (Lazy.force table) code

let compile prog scopes (h : Program.hint) =
  let ctx = Hintrt.make_ctx prog scopes h in
  match Hashtbl.find_opt (Lazy.force table) h.code with
  | Some f -> f ctx
  | None ->
      fun _ ->
        Errors.fail "Unknown hint: %s" (if String.length h.code > 80 then String.sub h.code 0 80 ^ "..." else h.code)
