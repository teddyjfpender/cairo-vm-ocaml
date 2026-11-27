(* Signature (ecdsa) and modular arithmetic (add_mod / mul_mod) builtins, as
   in cairo-vm v4.0.0:
     vm/src/vm/runners/builtin_runner/signature.rs
     vm/src/vm/runners/builtin_runner/modulo.rs
   Signatures are hint-supplied witnesses: the validation rule verifies them
   against the public key and message the program writes, so a bad witness
   makes the run fail rather than pass. *)

open Errors
open Builtin
open Vm

(* ================= ECDSA ================= *)

let p = Felt.p
let ec_order = Z.of_string "3618502788666131213697322783095070105526743751716087489154079457884512865583"
let alpha = Z.one
let beta = Z.of_string "0x6f21413efbe40de150e596d72f7a8c5609ad26c15c915c1f4cdfcb99cee9e89"
let gen_x = Z.of_string "0x1ef15c18599971b7beced415a40f0c7deacfd9b0d1819e03d723d8bc943cfca"
let gen_y = Z.of_string "0x5668060aa49730b7be4801df46ec62de53ecd11abe43a32873000c36e8dc1f"
let upper_bound = Z.shift_left Z.one 251 (* starknet-crypto ELEMENT_UPPER_BOUND *)

let fm x = Z.erem x p
let finv x = Z.invert x p

(* affine points, None = infinity *)
let ec_add a b =
  match (a, b) with
  | None, q | q, None -> q
  | Some (x1, y1), Some (x2, y2) ->
      if Z.equal x1 x2 then begin
        if Z.equal (fm (Z.add y1 y2)) Z.zero then None
        else begin
          let l = fm (Z.mul (Z.add (Z.mul (Z.of_int 3) (Z.mul x1 x1)) alpha) (finv (Z.shift_left y1 1))) in
          let x3 = fm (Z.sub (Z.mul l l) (Z.add x1 x2)) in
          Some (x3, fm (Z.sub (Z.mul l (Z.sub x1 x3)) y1))
        end
      end
      else begin
        let l = fm (Z.mul (Z.sub y2 y1) (finv (Z.sub x2 x1))) in
        let x3 = fm (Z.sub (Z.mul l l) (Z.add x1 x2)) in
        Some (x3, fm (Z.sub (Z.mul l (Z.sub x1 x3)) y1))
      end

let ec_neg = function None -> None | Some (x, y) -> Some (x, fm (Z.neg y))

let ec_mul pt k =
  let acc = ref None and base = ref pt in
  for i = 0 to Z.numbits k - 1 do
    if Z.testbit k i then acc := ec_add !acc !base;
    base := ec_add !base !base
  done;
  !acc

(* Tonelli-Shanks square root modulo the Stark prime; None for non-residues. *)
let sqrt_mod a =
  let a = fm a in
  if Z.equal a Z.zero then Some Z.zero
  else if not (Z.equal (Z.powm a (Z.shift_right (Z.pred p) 1) p) Z.one) then None
  else begin
    let s = Z.trailing_zeros (Z.pred p) in
    let q = Z.shift_right (Z.pred p) s in
    let z = ref (Z.of_int 3) in
    while Z.equal (Z.powm !z (Z.shift_right (Z.pred p) 1) p) Z.one do z := Z.succ !z done;
    let m = ref s and c = ref (Z.powm !z q p) and t = ref (Z.powm a q p)
    and r = ref (Z.powm a (Z.shift_right (Z.succ q) 1) p) in
    while not (Z.equal !t Z.one) do
      let i = ref 0 and t2 = ref !t in
      while not (Z.equal !t2 Z.one) do t2 := fm (Z.mul !t2 !t2); incr i done;
      let b = ref !c in
      for _ = 1 to !m - !i - 1 do b := fm (Z.mul !b !b) done;
      m := !i;
      c := fm (Z.mul !b !b);
      t := fm (Z.mul !t !c);
      r := fm (Z.mul !r !b)
    done;
    Some !r
  end

(* starknet-crypto 0.8.0 ecdsa::verify; Error -> fail, Ok false -> false *)
let verify ~pubkey ~msg ~r ~s =
  if Z.geq msg upper_bound then fail "Signature verification: invalid message hash";
  if Z.equal r Z.zero || Z.geq r upper_bound then fail "Signature verification: invalid r";
  if Z.equal s Z.zero || Z.geq s upper_bound then fail "Signature verification: invalid s";
  let y =
    match sqrt_mod (Z.add (Z.mul pubkey (Z.mul pubkey pubkey)) (Z.add (Z.mul alpha pubkey) beta)) with
    | Some y -> y
    | None -> fail "Signature verification: invalid public key"
  in
  let w = Z.invert s ec_order in
  if Z.equal w Z.zero || Z.geq w upper_bound then fail "Signature verification: invalid s";
  let zw = Z.erem (Z.mul msg w) ec_order and rw = Z.erem (Z.mul r w) ec_order in
  let zw_g = ec_mul (Some (gen_x, gen_y)) zw in
  let rw_q = ec_mul (Some (pubkey, y)) rw in
  let x_of = function
    | Some (x, _) -> x
    | None -> fail "Signature verification: point at infinity"
  in
  Z.equal (x_of (ec_add zw_g rw_q)) r || Z.equal (x_of (ec_add zw_g (ec_neg rw_q))) r

(* signatures added by hints, keyed by offset in the ecdsa segment; the first
   signature for an address wins (HashMap::entry().or_insert) *)
let signatures : (int, Z.t * Z.t) Hashtbl.t = Hashtbl.create 16

let add_signature off rs = if not (Hashtbl.mem signatures off) then Hashtbl.replace signatures off rs

(* SignatureBuiltinRunner validation rule, run on every new cell write *)
let ecdsa_validate vm seg off =
  let idx = off mod 2 in
  let pk_off = off - idx in
  if idx = 1 && off < 1 then ()
  else begin
    let pubkey = read vm seg pk_off and msg = read vm seg (pk_off + 1) in
    let pubkey_ok = pubkey <> 0 && Felt.is_felt pubkey and msg_ok = msg <> 0 && Felt.is_felt msg in
    let proceed =
      if not pubkey_ok then (if idx = 1 then false else fail "Signature builtin: public key at %d:%d is not an integer" seg pk_off)
      else if not msg_ok then (if idx = 0 then false else fail "Signature builtin: message at %d:%d is not an integer" seg off)
      else true
    in
    if proceed then begin
      let r, s =
        match Hashtbl.find_opt signatures pk_off with
        | Some rs -> rs
        | None -> fail "Signature hint is missing for ECDSA builtin at address %d:%d" seg pk_off
      in
      let pubkey = Felt.to_z pubkey and msg = Felt.to_z msg in
      if not (verify ~pubkey ~msg ~r ~s) then
        fail "Signature (%s, %s) is invalid, with respect to the public key %s, and the message hash %s."
          (Z.to_string r) (Z.to_string s) (Z.to_string pubkey) (Z.to_string msg)
    end
  end

(* ================= add_mod / mul_mod ================= *)

let n_words = 4
let fill_memory_max = 100000
let values_ptr_offset = 4
let offsets_ptr_offset = 5
let n_offset = 6

(* Every v4.0.0 layout with mod builtins uses ModInstanceDef(_, 1, 96). *)
let batch_size (_ : builtin) = 1
let word_bit_len (_ : builtin) = 96

let mod_name b = bname b.kind
let shift b = Z.shift_left Z.one (word_bit_len b)
let k_bound b = match b.kind with Add_mod -> Z.of_int 2 | _ -> Z.shift_left Z.one (n_words * word_bit_len b)

let addr_add (seg, off) k =
  let o = off + k in
  if o < 0 || o > max_off then fail "Offset exceeds range";
  (seg, o)

let cell vm (seg, off) = if seg_ok vm seg && off >= 0 then read vm seg off else 0

let get_reloc vm a =
  let v = cell vm a in
  if v = 0 then fail "Unknown memory cell %d:%d" (fst a) (snd a);
  if not (Felt.is_reloc v) then fail "Expected relocatable at %d:%d" (fst a) (snd a);
  (Felt.rseg v, Felt.roff v)

let get_int vm a =
  let v = cell vm a in
  if v = 0 then fail "Unknown memory cell %d:%d" (fst a) (snd a);
  if not (Felt.is_felt v) then fail "Expected integer at %d:%d" (fst a) (snd a);
  v

let get_usize vm a =
  let n = Felt.to_nat (get_int vm a) in
  if n < 0 then fail "Value at %d:%d does not fit in usize" (fst a) (snd a);
  n

(* Memory::insert_as_accessed: cells the mod builtins fill count as accessed
   for memory-hole accounting (Runner replays this log) *)
let accessed_log : (int * int) list ref = ref []

let insert vm (seg, off) v =
  write_checked vm seg off v;
  accessed_log := (seg, off) :: !accessed_log

(* words and value; None if a word is missing *)
let read_n_words vm b a =
  let words = Array.make n_words 0 in
  let rec go i acc =
    if i = n_words then Some (words, acc)
    else begin
      let ai = addr_add a i in
      let v = cell vm ai in
      if v = 0 then None
      else if Felt.is_reloc v then fail "Expected integer at %d:%d" (fst ai) (snd ai)
      else begin
        let w = Felt.to_z v in
        if Z.geq w (shift b) then
          fail "Expected integer at address %d:%d to be smaller than 2^%d. Got: %s" (fst ai) (snd ai)
            (word_bit_len b) (Z.to_string w);
        words.(i) <- v;
        go (i + 1) (Z.add acc (Z.shift_left w (i * word_bit_len b)))
      end
    end
  in
  go 0 Z.zero

type inputs = { pv : Z.t; p_words : int array; values_ptr : int * int; offsets_ptr : int * int; n : int }

let read_inputs vm b a =
  let values_ptr = get_reloc vm (addr_add a values_ptr_offset) in
  let offsets_ptr = get_reloc vm (addr_add a offsets_ptr_offset) in
  let n = get_usize vm (addr_add a n_offset) in
  if n < 1 then fail "%s: n must be at least 1, got %d" (mod_name b) n;
  match read_n_words vm b a with
  | Some (w, v) -> { pv = v; p_words = w; values_ptr; offsets_ptr; n }
  | None -> fail "%s: missing value at %d:%d" (mod_name b) (fst a) (snd a + n_words)

let apply_operation b x y pr =
  let full = match b.kind with Add_mod -> Z.add x y | _ -> Z.mul x y in
  let kb = k_bound b in
  if Z.lt full (Z.mul kb pr) then Z.erem full pr else Z.sub full (Z.mul (Z.pred kb) pr)

let deduce_operand b known result pr =
  match b.kind with
  | Add_mod ->
      if Z.leq known result then Z.sub result known
      else begin
        let v = Z.sub (Z.add result pr) known in
        if Z.sign v < 0 then fail "%s: subtraction underflow" (mod_name b);
        v
      end
  | _ ->
      if Z.sign pr = 0 then fail "%s: division modulo zero" (mod_name b);
      if Z.equal pr Z.one then Z.zero
      else if not (Z.equal (Z.gcd known pr) Z.one) then
        fail "%s: %s is not invertible modulo %s" (mod_name b) (Z.to_string known) (Z.to_string pr)
      else Z.erem (Z.mul result (Z.invert known pr)) pr

let write_n_words vm b a value =
  let v = ref value in
  for i = 0 to n_words - 1 do
    insert vm (addr_add a i) (Felt.of_z (Z.extract !v 0 (word_bit_len b)));
    v := Z.shift_right !v (word_bit_len b)
  done;
  if Z.sign !v <> 0 then fail "%s: value does not fit in %d words" (mod_name b) n_words

let fill_inputs vm b ptr inp =
  if inp.n > fill_memory_max then fail "%s: n exceeds the fill_memory maximum %d" (mod_name b) fill_memory_max;
  let bs = batch_size b in
  if inp.n mod bs <> 0 then fail "%s: n is not a multiple of the batch size" (mod_name b);
  for instance = 1 to (inp.n / bs) - 1 do
    let ip = addr_add ptr (instance * cells_per_instance b.kind) in
    for i = 0 to n_words - 1 do
      insert vm (addr_add ip i) inp.p_words.(i)
    done;
    insert vm (addr_add ip values_ptr_offset) (Felt.reloc (fst inp.values_ptr) (snd inp.values_ptr));
    let o = addr_add inp.offsets_ptr (3 * instance * bs) in
    insert vm (addr_add ip offsets_ptr_offset) (Felt.reloc (fst o) (snd o));
    insert vm (addr_add ip n_offset) (Felt.of_int (max 0 (inp.n - (instance * bs))))
  done

let fill_offsets vm offsets_ptr index n_copies =
  if n_copies > 0 then
    for i = 0 to 2 do
      let a = addr_add offsets_ptr i in
      let off = cell vm a in
      if off = 0 then fail "Unknown memory cell %d:%d" (fst a) (snd a);
      for copy_i = 0 to n_copies - 1 do
        insert vm (addr_add offsets_ptr ((3 * (index + copy_i)) + i)) off
      done
    done

let value_addr vm inp k =
  let off = get_int vm (addr_add inp.offsets_ptr k) in
  let r = reloc_add_felt (Felt.reloc (fst inp.values_ptr) (snd inp.values_ptr)) off in
  (Felt.rseg r, Felt.roff r)

let fill_value vm b inp index =
  let addrs = Array.init 3 (fun i -> value_addr vm inp ((3 * index) + i)) in
  let vals = Array.map (fun a -> Option.map snd (read_n_words vm b a)) addrs in
  match (vals.(0), vals.(1), vals.(2)) with
  | Some x, Some y, None -> write_n_words vm b addrs.(2) (apply_operation b x y inp.pv); true
  | Some x, None, Some c -> write_n_words vm b addrs.(1) (deduce_operand b x c inp.pv); true
  | None, Some y, Some c -> write_n_words vm b addrs.(0) (deduce_operand b y c inp.pv); true
  | Some _, Some _, Some _ -> true
  | _ -> false

(* ModBuiltinRunner::fill_memory; each argument is (builtin_ptr, runner, n) *)
let fill_memory vm (add : ((int * int) * builtin * int) option) (mul : ((int * int) * builtin * int) option) =
  let add = match add with Some (_, _, n) when n > 0 -> add | _ -> None in
  let mul = match mul with Some (_, _, n) when n > 0 -> mul | _ -> None in
  if add = None && mul = None then fail "fill_memory: no mod builtin was set";
  (match (add, mul) with
  | Some (_, a, _), Some (_, m, _) when word_bit_len a <> word_bit_len m ->
      fail "fill_memory: mod builtins have mismatched instance definitions"
  | _ -> ());
  let prep = function
    | Some (ptr, b, index) ->
        let inp = read_inputs vm b ptr in
        fill_inputs vm b ptr inp;
        fill_offsets vm inp.offsets_ptr index (max 0 (inp.n - index));
        Some (b, inp, index)
    | None -> None
  in
  let add = prep add in
  let mul = prep mul in
  let add_n = match add with Some (_, _, n) -> n | None -> 0 in
  let mul_n = match mul with Some (_, _, n) -> n | None -> 0 in
  let ai = ref 0 and mi = ref 0 in
  let stuck () = fail "fill_memory: could not fill the values table, add_mod_index=%d, mul_mod_index=%d" !ai !mi in
  while !ai < add_n || !mi < mul_n do
    let progressed =
      !ai < add_n
      && (match add with Some (b, inp, _) -> fill_value vm b inp !ai | None -> false)
      && (incr ai; true)
    in
    if not progressed then begin
      if !mi < mul_n then begin
        match mul with
        | Some (b, inp, _) -> if fill_value vm b inp !mi then incr mi else stuck ()
        | None -> stuck ()
      end
      else stuck ()
    end
  done

(* ModBuiltinRunner::run_additional_security_checks *)
let security_check vm b =
  let size = used_size vm b.base in
  let cpi = cells_per_instance b.kind and bs = batch_size b in
  let n_instances = (size + cpi - 1) / cpi in
  let prev = ref None in
  let err fmt = Printf.ksprintf (fun s -> fail "%s_builtin: %s" (mod_name b) s) fmt in
  for instance = 0 to n_instances - 1 do
    let inp = read_inputs vm b (b.base, instance * cpi) in
    (match !prev with
    | Some pi when instance > 0 && pi.n > bs ->
        for i = 0 to n_words - 1 do
          if not (Felt.equal inp.p_words.(i) pi.p_words.(i)) then err "inputs.p_values[%d] != prev_inputs.p_values[%d]" i i
        done;
        if inp.values_ptr <> pi.values_ptr then err "inputs.values_ptr != prev_inputs.values_ptr";
        if inp.offsets_ptr <> addr_add pi.offsets_ptr (3 * bs) then
          err "inputs.offsets_ptr != prev_inputs.offsets_ptr + 3 * batch_size";
        if inp.n <> max 0 (pi.n - bs) then err "inputs.n != prev_inputs.n - batch_size"
    | _ -> ());
    for index_in_batch = 0 to bs - 1 do
      let value k =
        let off = get_usize vm (addr_add inp.offsets_ptr (k + (3 * index_in_batch))) in
        let a = addr_add inp.values_ptr off in
        match read_n_words vm b a with
        | Some (_, v) -> v
        | None -> fail "%s: missing value at %d:%d" (mod_name b) (fst a) (snd a + n_words)
      in
      let x = value 0 in
      let y = value 1 in
      let c = value 2 in
      if Z.sign inp.pv = 0 then err "modulus p is zero";
      let r = apply_operation b x y inp.pv in
      if not (Z.equal (Z.erem r inp.pv) (Z.erem c inp.pv)) then
        err "Expected a %s b == c (mod p). Got: instance=%d, batch=%d, p=%s, a=%s, b=%s, c=%s."
          (match b.kind with Add_mod -> "+" | _ -> "*") instance index_in_batch (Z.to_string inp.pv) (Z.to_string x)
          (Z.to_string y) (Z.to_string c)
    done;
    prev := Some inp
  done;
  match !prev with
  | Some pi when n_instances > 0 && pi.n <> bs -> err "prev_inputs.n != batch_size"
  | _ -> ()

(* zero segment of MemorySegmentManager::add_zero_segment, sized for the
   largest mod builtin; returns its index *)
let add_zero_segment vm mods =
  let size = List.fold_left (fun acc b -> max acc (max n_words (batch_size b * 3))) 0 mods in
  let seg = add_segment vm in
  for i = 0 to size - 1 do
    write vm seg i Felt.zero
  done;
  seg

let reset () = Hashtbl.reset signatures; accessed_log := []

let install () = Vm.ecdsa_validate := ecdsa_validate
