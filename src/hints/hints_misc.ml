(* Hints outside the original builtin set: math/uint256 variants, Blake2s,
   SHA-256, cairo_keccak/keccak_utils variants and temporary segments.
   Each implementation mirrors starkware-libs/cairo-vm v4.0.0 (including where
   it deliberately departs from the Python hint text, e.g. hard-coded padding
   sizes), and is matched by the exact code string in Hint_codes. *)

open Errors
open Builtin
open Vm
open Hintrt
module C = Hint_codes
module P = Program

let reg = Hints.reg
let z = Z.of_int
let two_pow n = Z.shift_left Z.one n
let mask n = Z.pred (two_pow n)
let fz v = Felt.to_z v

(* constants map lookup by full identifier path (cairo-vm `constants.get`) *)
let const_full ctx full =
  match Hashtbl.find_opt ctx.prog.P.identifiers full with
  | Some { P.i_type = "const"; i_value = Some v; _ } -> Z.erem v Felt.p
  | _ -> fail "Missing constant %s" full

(* get_constant_from_var_name: any constant whose last path component matches *)
let const_suffix ctx name = Z.erem (const_z ctx name) Felt.p

(* get_integer at an address *)
let int_at vm addr k =
  let v = mem_at vm addr k in
  if not (Felt.is_felt v) then fail "Expected integer at %s" (value_to_string (value_add addr (Felt.small k)));
  fz v

(* felt_to_u32 *)
let u32 z = if Z.sign z >= 0 && Z.numbits z <= 32 then Z.to_int z else fail "Felt %s does not fit a u32" (Z.to_string z)

let u64_bound = two_pow 64

let has_range_check vm = List.exists (fun b -> b.kind = Range_check) vm.builtins

(* ---- Tonelli-Shanks over the Stark field; returns the smaller root ---- *)
let p = Felt.p
(* ---- SHA-256 compression (sha2::compress256 on one 64-byte block) ---- *)
let sha_k =
  [| 0x428a2f98; 0x71374491; 0xb5c0fbcf; 0xe9b5dba5; 0x3956c25b; 0x59f111f1; 0x923f82a4; 0xab1c5ed5;
     0xd807aa98; 0x12835b01; 0x243185be; 0x550c7dc3; 0x72be5d74; 0x80deb1fe; 0x9bdc06a7; 0xc19bf174;
     0xe49b69c1; 0xefbe4786; 0x0fc19dc6; 0x240ca1cc; 0x2de92c6f; 0x4a7484aa; 0x5cb0a9dc; 0x76f988da;
     0x983e5152; 0xa831c66d; 0xb00327c8; 0xbf597fc7; 0xc6e00bf3; 0xd5a79147; 0x06ca6351; 0x14292967;
     0x27b70a85; 0x2e1b2138; 0x4d2c6dfc; 0x53380d13; 0x650a7354; 0x766a0abb; 0x81c2c92e; 0x92722c85;
     0xa2bfe8a1; 0xa81a664b; 0xc24b8b70; 0xc76c51a3; 0xd192e819; 0xd6990624; 0xf40e3585; 0x106aa070;
     0x19a4c116; 0x1e376c08; 0x2748774c; 0x34b0bcb5; 0x391c0cb3; 0x4ed8aa4a; 0x5b9cca4f; 0x682e6ff3;
     0x748f82ee; 0x78a5636f; 0x84c87814; 0x8cc70208; 0x90befffa; 0xa4506ceb; 0xbef9a3f7; 0xc67178f2 |]

let sha_iv = [| 0x6A09E667; 0xBB67AE85; 0x3C6EF372; 0xA54FF53A; 0x510E527F; 0x9B05688C; 0x1F83D9AB; 0x5BE0CD19 |]

let m32 = 0xFFFFFFFF
let rotr x n = ((x lsr n) lor (x lsl (32 - n))) land m32

let sha256_compress (state : int array) (words : int array) =
  let w = Array.make 64 0 in
  Array.blit words 0 w 0 16;
  for i = 16 to 63 do
    let s0 = rotr w.(i - 15) 7 lxor rotr w.(i - 15) 18 lxor (w.(i - 15) lsr 3) in
    let s1 = rotr w.(i - 2) 17 lxor rotr w.(i - 2) 19 lxor (w.(i - 2) lsr 10) in
    w.(i) <- (w.(i - 16) + s0 + w.(i - 7) + s1) land m32
  done;
  let a = ref state.(0) and b = ref state.(1) and c = ref state.(2) and d = ref state.(3) in
  let e = ref state.(4) and f = ref state.(5) and g = ref state.(6) and h = ref state.(7) in
  for i = 0 to 63 do
    let s1 = rotr !e 6 lxor rotr !e 11 lxor rotr !e 25 in
    let ch = (!e land !f) lxor (lnot !e land m32 land !g) in
    let t1 = (!h + s1 + ch + sha_k.(i) + w.(i)) land m32 in
    let s0 = rotr !a 2 lxor rotr !a 13 lxor rotr !a 22 in
    let maj = (!a land !b) lxor (!a land !c) lxor (!b land !c) in
    let t2 = (s0 + maj) land m32 in
    h := !g; g := !f; f := !e;
    e := (!d + t1) land m32;
    d := !c; c := !b; b := !a;
    a := (t1 + t2) land m32
  done;
  let out = [| !a; !b; !c; !d; !e; !f; !g; !h |] in
  Array.mapi (fun i v -> (state.(i) + v) land m32) out

let smalls a = Array.to_list (Array.map Felt.small a)

(* ---- uint256 at an address (cairo-vm Uint256::from_base_addr) ---- *)
let uint256_at vm addr off_low off_high = (int_at vm addr off_low, int_at vm addr off_high)
let pack256 (low, high) = Z.add (Z.shift_left high 128) low

let insert_uint256 vm c name v =
  let a = get_addr vm c name in
  write_checked vm (Felt.rseg a) (Felt.roff a) (Felt.of_z (Z.logand v (mask 128)));
  write_checked vm (Felt.rseg a) (Felt.roff a + 1) (Felt.of_z (Z.shift_right v 128))

let ge_felt v bound = Z.geq (fz v) bound

(* ---- dex excess balance: rust_decimal arithmetic, value = m / 10^s ---- *)
module Dec = struct
  let ( let* ) = Option.bind
  let pow10 = Z.pow (z 10)
  let limit = two_pow 96

  (* rust_decimal keeps |m| < 2^96 and s <= 28, dropping the fewest digits
     with round-half-even on the exact result; None is its overflow. *)
  let norm (m, s) =
    let rec go r =
      if r > s then None
      else
        let d = pow10 r in
        let q, rem = Z.div_rem (Z.abs m) d in
        let c = Z.compare (Z.shift_left rem 1) d in
        let q = if c > 0 || (c = 0 && Z.is_odd q) then Z.succ q else q in
        if Z.lt q limit then Some ((if Z.sign m < 0 then Z.neg q else q), s - r) else go (r + 1)
    in
    go (max 0 (s - 28))

  let mul (a, s) (b, t) = norm (Z.mul a b, s + t)
  let align (a, s) (b, t) = (Z.mul a (pow10 (t - min s t)), Z.mul b (pow10 (s - min s t)), max s t)
  let add x y = let a, b, u = align x y in norm (Z.add a b, u)
  let sub x (b, t) = add x (Z.neg b, t)
  let max x y = let a, b, _ = align x y in if Z.lt a b then y else x
  let abs (m, s) = (Z.abs m, s)
  let trunc (m, s) = Z.div m (pow10 s)
  let e8 = (pow10 8, 0)

  (* felt_to_scaled_decimal: the signed felt must parse as a 96-bit mantissa *)
  let of_felt v = let m = Felt.to_signed_z v in if Z.lt (Z.abs m) limit then Some (m, 8) else None
  let to_felt d = let* d = mul d e8 in Some (Felt.of_z (Z.erem (trunc d) Felt.p))

  type margin = { base : Z.t * int; factor : Z.t * int; mmf : Z.t * int; shift : Z.t * int }

  let imf p v =
    let* d = sub v p.shift in
    let* d = mul d e8 in
    let* root = mul (Z.sqrt (Z.max (trunc d) Z.zero), 0) (Z.one, 4) in
    let* f = mul p.factor root in
    Some (max p.base f)
end

exception Unexpected

let excess_balance c vm =
  let calc what = function Some x -> x | None -> fail "excess_balance_func: Failed to calculate %s" what in
  let lookup what l k =
    match List.find_opt (fun (k', _) -> Felt.equal k k') l with
    | Some (_, v) -> v
    | None -> fail "excess_balance_func: Key not found in %s dictionary" what
  in
  let num v = match if Felt.is_felt v then Dec.of_felt v else None with Some d -> d | None -> raise Unexpected in
  (* market names are UTF-8 short strings; distinct felts give distinct names *)
  let market v =
    let b = Z.to_bits (fz v) in
    let n = String.length b in
    if Felt.is_felt v && String.is_valid_utf_8 (String.init n (fun i -> b.[n - 1 - i])) then v else raise Unexpected
  in
  let cell p k =
    if not (Felt.is_reloc p) then raise Unexpected;
    let v = get vm (Felt.rseg p) (Felt.roff p + k) in
    if Felt.is_felt v then v else raise Unexpected
  in
  let dict ptr what conv =
    try List.map conv (Hints.dict_entries (Hints.get_tracker c.scopes (get_ptr vm c ptr)))
    with Unexpected | Vm_error _ ->
      fail "excess_balance_func: Failed to fetch %s dictionary. It is either missing or has unexpected data types" what
  in
  let initial = Z.equal (fz (get_felt vm c "margin_check_type")) (const_suffix c "MARGIN_CHECK_INITIAL") in
  let token_assets = get_felt vm c "token_assets_value_d" and account = get_felt vm c "account" in
  let prices = dict "prices_cache_ptr" "prices" (fun (k, v) -> (market k, num v)) in
  let indices = dict "indices_cache_ptr" "indices" (fun (k, v) -> (market k, num v)) in
  let perps =
    dict "perps_cache_ptr" "perps" (fun (k, p) ->
        ignore (market (cell p 0)) (* validated, unused *);
        (market k, Dec.{ base = num (cell p 4); factor = num (cell p 5); mmf = num (cell p 6); shift = num (cell p 7) }))
  in
  let fees = dict "fees_cache_ptr" "fees" (fun (k, v) -> ((if Felt.is_felt k then k else raise Unexpected), num v)) in
  let balances =
    dict "perps_balances_cache_ptr" "balances" (fun (_, p) ->
        (market (cell p 0), num (cell p 1), num (cell p 2), num (cell p 3)))
  in
  let usdc = Felt.of_z (String.fold_left (fun acc ch -> Z.add (Z.shift_left acc 8) (z (Char.code ch))) Z.zero "USDC-USD") in
  let settlement = lookup "prices" prices usdc in
  let open Dec in
  let zero = (Z.zero, 0) in
  (* cairo-vm sums in HashMap order: order matters only when a sum rounds *)
  let pnl, funding, abs_total, margin =
    List.fold_left
      (fun ((pnl, funding, abs_total, margin) as acc) (m, amount, cost, cached) ->
        if Felt.equal m usdc then acc
        else
          let price = lookup "prices" prices m and index = lookup "indices" indices m in
          let value = calc "position_value" (mul amount price) in
          let abs_total = calc "abs_balance_value" (add abs_total (abs value)) in
          let p = lookup "perps" perps m in
          let fraction = if initial then imf p (abs value) else Option.bind (imf p (abs value)) (mul p.mmf) in
          let fraction = calc "margin_fraction" fraction in
          let margin = calc "position_margin" (let* x = mul fraction (abs value) in add margin x) in
          let pnl = calc "unrealized_pnl" (let* x = mul cost settlement in let* x = sub value x in add pnl x) in
          let funding =
            calc "unrealized_funding_pnl"
              (let* x = sub cached index in let* x = mul x amount in let* x = mul x settlement in add funding x)
          in
          (pnl, funding, abs_total, margin))
      (zero, zero, zero, zero) balances
  in
  let token_assets = calc "account_value" (of_felt token_assets) in
  let account_value = calc "account_value" (let* x = add pnl funding in add x token_assets) in
  let fee = lookup "fees" fees account in
  let fee_provision = calc "fee_provision" (mul abs_total fee) in
  let requirement = calc "margin_requirements" (add margin fee_provision) in
  let excess = calc "excess_balance" (sub account_value requirement) in
  let felts =
    [ ("check_account_value", "account_value", account_value); ("check_excess_balance", "excess_balance", excess);
      ("check_margin_requirement_d", "margin_requirement_d", requirement);
      ("check_unrealized_pnl_d", "unrealized_pnl_d", pnl) ]
    |> List.map (fun (id, what, d) -> (id, calc what (to_felt d)))
  in
  List.iter (fun (id, v) -> set_val vm c id v) felts

let register () =
  (* ---------------- math ---------------- *)
  reg C.assert_le_felt_v_0_6 (fun c vm ->
      let a = get_z vm c "a" and b = get_z vm c "b" in
      if Z.gt a b then fail "a = %s is not less than or equal to b = %s." (Z.to_string a) (Z.to_string b));
  reg C.assert_le_felt_v_0_8 (fun c vm ->
      let a = get_felt vm c "a" and b = get_felt vm c "b" in
      if Felt.compare a b > 0 then
        fail "a = %s is not less than or equal to b = %s." (Felt.to_string a) (Felt.to_string b);
      if not (has_range_check vm) then fail "Expected range_check builtin to be present";
      let bound = Hintrt.rc_bound in
      let small_inputs = Z.lt (fz a) bound && Z.lt (fz (Felt.sub b a)) bound in
      set_val vm c "small_inputs" (of_bool small_inputs));
  reg C.is_250_bits (fun c vm ->
      set_val vm c "is_250" (of_bool (Felt.bits (get_felt vm c "addr") <= 250)));
  reg C.is_addr_bounded (fun c vm ->
      let addr = get_z vm c "addr" in
      let bound = const_full c "starkware.starknet.common.storage.ADDR_BOUND" in
      if not (Z.lt (two_pow 250) bound && Z.leq bound (two_pow 251) && Z.gt (Z.shift_left bound 1) Felt.p) then
        fail "normalize_address() cannot be used with the current constants.";
      set_val vm c "is_small" (of_bool (Z.lt addr bound)));
  reg C.sqrt (fun c vm ->
      let v = get_z vm c "value" in
      if Z.geq v (two_pow 250) then fail "Value: %s is outside valid range [0, 2**250)" (Z.to_string v);
      set_val vm c "root" (Felt.of_z (Z.sqrt v)));
  reg C.a_b_bitand_1 (fun c vm ->
      let a = get_z vm c "a" and b = get_z vm c "b" in
      set_val vm c "a_lsb" (Felt.of_z (Z.logand a Z.one));
      set_val vm c "b_lsb" (Felt.of_z (Z.logand b Z.one)));
  reg C.nondet_n_greater_than_10 (fun c vm -> write_ap vm (of_bool (Z.geq (get_z vm c "n") (z 10))));
  reg C.nondet_n_greater_than_2 (fun c vm -> write_ap vm (of_bool (Z.geq (get_z vm c "n") (z 2))));

  (* ---------------- uint256 ---------------- *)
  reg C.uint256_add_low (fun c vm ->
      let a = get_addr vm c "a" and b = get_addr vm c "b" in
      let al = mem_at vm a 0 and bl = mem_at vm b 0 in
      ignore (int_at vm a 1); ignore (int_at vm b 1);
      if not (Felt.is_felt al && Felt.is_felt bl) then fail "uint256_add: expected integers";
      set_val vm c "carry_low" (of_bool (ge_felt (Felt.add al bl) (two_pow 128))));
  reg C.uint128_add (fun c vm ->
      let a = get_felt vm c "a" and b = get_felt vm c "b" in
      set_val vm c "carry" (of_bool (ge_felt (Felt.add a b) (two_pow 128))));
  reg C.uint256_sub (fun c vm ->
      let a = pack256 (uint256_at vm (get_addr vm c "a") 0 1) in
      let b = pack256 (uint256_at vm (get_addr vm c "b") 0 1) in
      let m256 = two_pow 256 in
      let res =
        if Z.geq a b then Z.sub a b
        else if Z.geq m256 b then Z.add (Z.sub m256 b) a
        else
          let lb = Z.erem b m256 in
          if Z.geq a lb then Z.sub a lb else Z.add (Z.sub m256 lb) a
      in
      insert_uint256 vm c "res" res);
  reg C.uint256_sqrt_felt (fun c vm ->
      let n = pack256 (uint256_at vm (get_addr vm c "n") 0 1) in
      let root = Z.sqrt n in
      if Z.numbits root > 128 then fail "assert 0 <= %s < 2 ** 128" (Z.to_string root);
      set_val vm c "root" (Felt.of_z root));
  reg C.uint256_expanded_unsigned_div_rem (fun c vm ->
      let a = pack256 (uint256_at vm (get_addr vm c "a") 0 1) in
      let d = pack256 (uint256_at vm (get_addr vm c "div") 1 3) in
      if Z.equal d Z.zero then fail "Attempted to divide by zero";
      let q, r = Z.ediv_rem a d in
      insert_uint256 vm c "quotient" q;
      insert_uint256 vm c "remainder" r);

  (* ---------------- blake2s ---------------- *)
  let modified_iv () = let v = Array.copy Hints.iv in v.(0) <- v.(0) lxor 0x01010020; v in
  let finalize_padding ~message_first =
    let miv = modified_iv () and message = Array.make 16 0 in
    let output = Hints.blake2s_compress miv message 0 0 0xffffffff 0 in
    let one =
      (if message_first then Array.to_list message @ Array.to_list miv else Array.to_list miv @ Array.to_list message)
      @ [ 0; 0xffffffff ] @ Array.to_list output
    in
    (* cairo-vm hard-codes N_PACKED_INSTANCES = 7 *)
    List.map Felt.small (List.concat (List.init 6 (fun _ -> one)))
  in
  reg C.blake2s_finalize_v2 (fun c vm ->
      write_arg vm (get_ptr vm c "blake2s_ptr_end") (finalize_padding ~message_first:false));
  reg C.blake2s_finalize_v3 (fun c vm ->
      write_arg vm (get_ptr vm c "blake2s_ptr_end") (finalize_padding ~message_first:true));
  reg C.is_less_than_63_bits_and_not_end (fun c vm ->
      let e = get_ptr vm c "end" and pv = get_ptr vm c "packed_values" in
      if Felt.equal e pv then write_ap vm Felt.zero
      else write_ap vm (of_bool (Z.lt (int_at vm pv 0) (two_pow 63))));
  reg C.blake2s_unpack_felts (fun c vm ->
      let n = get_z vm c "packed_values_len" in
      if Z.numbits n > 62 then fail "Felt %s does not fit a usize" (Z.to_string n);
      let pv = get_ptr vm c "packed_values" and out = get_ptr vm c "unpacked_u32s" in
      let vals = List.init (Z.to_int n) (fun i -> int_at vm pv i) in
      let limbs v =
        if Z.lt v (two_pow 63) then [ Z.shift_right v 32; Z.logand v (z m32) ]
        else
          let v = Z.add v (two_pow 255) in
          List.init 8 (fun i -> Z.logand (Z.shift_right v (32 * (7 - i))) (z m32))
      in
      write_arg vm out (List.map Felt.of_z (List.concat_map limbs vals)));
  reg C.example_blake2s_compress (fun c vm ->
      let start = get_ptr vm c "blake2s_start" and out = get_ptr vm c "output" in
      let n_bytes = u32 (get_z vm c "n_bytes") in
      let msg = Array.init 16 (fun i -> u32 (int_at vm start i)) in
      let st = Hints.blake2s_compress (modified_iv ()) msg n_bytes 0 0xffffffff 0 in
      write_arg vm out (smalls st));

  (* ---------------- sha256 ---------------- *)
  reg C.sha256_input (fun c vm -> set_val vm c "full_word" (of_bool (Z.geq (get_z vm c "n_bytes") (z 4))));
  let sha256_main c vm iv =
    let start = get_ptr vm c "sha256_start" in
    let chunk = const_suffix c "SHA256_INPUT_CHUNK_SIZE_FELTS" in
    if Z.geq chunk (z 100) then fail "assert 0 <= _sha256_input_chunk_size_felts < 100";
    let chunk = Z.to_int chunk in
    let words = Array.init chunk (fun i -> u32 (int_at vm start i)) in
    (* sha2::compress256 takes exactly one 64-byte block *)
    if chunk <> 16 then fail "SHA256 block must be 16 words, got %d" chunk;
    let st = sha256_compress iv words in
    write_arg vm (get_ptr vm c "output") (smalls st)
  in
  reg C.sha256_main_constant_input_length (fun c vm -> sha256_main c vm sha_iv);
  reg C.sha256_main_arbitrary_input_length (fun c vm ->
      let state = get_ptr vm c "state" in
      let size = const_suffix c "SHA256_STATE_SIZE_FELTS" in
      if Z.geq size (z 100) then fail "assert 0 <= _sha256_state_size_felts < 100";
      if not (Z.equal size (z 8)) then fail "Invalid value for SHA256_STATE_SIZE_FELTS: %s, expected 8" (Z.to_string size);
      let iv = Array.init 8 (fun i -> u32 (int_at vm state i)) in
      sha256_main c vm iv);
  reg C.sha256_finalize (fun c vm ->
      let output = sha256_compress sha_iv (Array.make 16 0) in
      let one = List.init 16 (fun _ -> Felt.zero) @ smalls sha_iv @ smalls output in
      (* cairo-vm hard-codes BLOCK_SIZE = 7 *)
      write_arg vm (get_ptr vm c "sha256_ptr_end") (List.concat (List.init 6 (fun _ -> one))));

  (* ---------------- cairo_keccak ---------------- *)
  let state_size c =
    let n = const_full c "starkware.cairo.common.cairo_keccak.keccak.KECCAK_STATE_SIZE_FELTS" in
    if Z.geq n (z 100) then fail "Invalid keccak state size felts: %s" (Z.to_string n);
    Z.to_int n
  in
  let lanes vm ptr n =
    let vals =
      Array.init n (fun i ->
          let v = get vm (Felt.rseg ptr) (Felt.roff ptr + i) in
          if not (Felt.is_felt v) then fail "Expected integer at keccak state range";
          let x = fz v in
          if Z.geq x u64_bound then fail "Felt %s does not fit a u64" (Z.to_string x);
          x)
    in
    if n <> 25 then fail "Keccak state must have 25 lanes, got %d" n;
    Hints.keccak_lanes vals
  in
  reg C.block_permutation_whitelist_v1 (fun c vm ->
      let n = state_size c in
      let kp = get_ptr vm c "keccak_ptr" in
      let out = lanes vm (value_sub kp (Felt.small n)) n in
      write_arg vm kp (Array.to_list (Array.map Felt.of_z out)));
  reg C.block_permutation_whitelist_v2 (fun c vm ->
      let n = state_size c in
      let out = lanes vm (get_ptr vm c "keccak_ptr_start") n in
      write_arg vm (get_ptr vm c "output") (Array.to_list (Array.map Felt.of_z out)));
  reg C.cairo_keccak_input_is_full_word (fun c vm ->
      set_val vm c "full_word" (of_bool (Z.geq (get_z vm c "n_bytes") (z 8))));
  reg C.cairo_keccak_finalize_v2 (fun c vm ->
      let n = const_full c "starkware.cairo.common.cairo_keccak.keccak.KECCAK_STATE_SIZE_FELTS" in
      let bs = const_full c "starkware.cairo.common.cairo_keccak.packed_keccak.BLOCK_SIZE" in
      if Z.geq n (z 100) then fail "Invalid keccak state size felts: %s" (Z.to_string n);
      if Z.geq bs (z 1000) then fail "Invalid block size: %s" (Z.to_string bs);
      let n = Z.to_int n and bs = Z.to_int bs in
      if n <> 25 then fail "Keccak state must have 25 lanes, got %d" n;
      if bs = 0 then fail "Invalid block size: 0";
      let inp = Array.make 25 Z.zero in
      let one = List.init n (fun _ -> Felt.zero) @ Array.to_list (Array.map Felt.of_z (Hints.keccak_lanes inp)) in
      write_arg vm (get_ptr vm c "keccak_ptr_end") (List.concat (List.init bs (fun _ -> one))));

  (* ---------------- keccak_utils splits ---------------- *)
  let split_output k c vm =
    let v = get_z vm c (Printf.sprintf "output%d" k) in
    set_val vm c (Printf.sprintf "output%d_high" k) (Felt.of_z (Z.shift_right v 128));
    set_val vm c (Printf.sprintf "output%d_low" k) (Felt.of_z (Z.logand v (mask 128)))
  in
  reg C.split_output_0 (split_output 0);
  reg C.split_output_1 (split_output 1);
  let split_input key e c vm =
    let v = int_at vm (get_ptr vm c "inputs") key in
    set_val vm c (Printf.sprintf "high%d" key) (Felt.of_z (Z.shift_right v (8 * e)));
    set_val vm c (Printf.sprintf "low%d" key) (Felt.of_z (Z.logand v (mask (8 * e))))
  in
  reg C.split_input_3 (split_input 3 1);
  reg C.split_input_6 (split_input 6 2);
  reg C.split_input_9 (split_input 9 3);
  reg C.split_input_12 (split_input 12 4);
  reg C.split_input_15 (split_input 15 5);
  reg C.split_n_bytes (fun c vm ->
      let n = get_z vm c "n_bytes" in
      if Z.geq n u64_bound then fail "Felt %s does not fit a u64" (Z.to_string n);
      let w = const_full c "starkware.cairo.common.builtin_keccak.keccak.BYTES_IN_WORD" in
      if Z.geq w u64_bound then fail "Missing constant BYTES_IN_WORD";
      if Z.equal w Z.zero then fail "Attempted to divide by zero";
      let q, r = Z.ediv_rem n w in
      set_val vm c "n_words_to_copy" (Felt.of_z q);
      set_val vm c "n_bytes_left" (Felt.of_z r));
  reg C.split_output_mid_low_high (fun c vm ->
      let v = get_z vm c "output1" in
      let tmp = Z.shift_right v 56 and low = Z.logand v (mask 56) in
      set_val vm c "output1_high" (Felt.of_z (Z.shift_right tmp 128));
      set_val vm c "output1_mid" (Felt.of_z (Z.logand tmp (mask 128)));
      set_val vm c "output1_low" (Felt.of_z low));

  (* ---------------- segments ---------------- *)
  reg C.temporary_array (fun c vm -> set_val vm c "temporary_array" (Felt.reloc (add_temp_segment vm) 0));
  reg C.relocate_segment (fun c vm ->
      let src = get_ptr vm c "src_ptr" in
      (* cairo-vm: inside segment_arena (`infos` in scope) dest_ptr is
         recomputed as infos[0].end + 1 *)
      let infos = try Some (get_ptr vm c "infos") with Vm_error _ -> None in
      let dst =
        match infos with
        | Some infos ->
            let e = mem_at vm infos 1 in
            if not (Felt.is_reloc e) then fail "Expected relocatable at infos + 1";
            value_add e Felt.one
        | None -> get_ptr vm c "dest_ptr"
      in
      add_relocation_rule vm src dst);
  reg C.excess_balance excess_balance
