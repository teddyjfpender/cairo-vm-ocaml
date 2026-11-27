(* The dex excess-balance hint (cairo-vm excess_balance.rs). *)

open Errors
open Vm
open Hintrt
module C = Hint_codes

(* ---- dex excess balance: rust_decimal arithmetic, value = m / 10^s ---- *)
module Dec = struct
  type t = Z.t * int

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
    let b = Z.to_bits (Felt.to_z v) in
    let n = String.length b in
    if Felt.is_felt v && String.is_valid_utf_8 (String.init n (fun i -> b.[n - 1 - i])) then v else raise Unexpected
  in
  let cell p k =
    if not (Felt.is_reloc p) then raise Unexpected;
    let v = get vm (Felt.rseg p) (Felt.roff p + k) in
    if Felt.is_felt v then v else raise Unexpected
  in
  let dict ptr what conv =
    try List.map conv (Dict.dict_entries (Dict.get_tracker c.scopes (get_ptr vm c ptr)))
    with Unexpected | Vm_error _ ->
      fail "excess_balance_func: Failed to fetch %s dictionary. It is either missing or has unexpected data types" what
  in
  let initial = Z.equal (Felt.to_z (get_felt vm c "margin_check_type")) (const_suffix c "MARGIN_CHECK_INITIAL") in
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

let register reg = reg C.excess_balance excess_balance
