(* Generate Montgomery affine window tables from the repository's pinned
   canonical Stark curve coordinates. Runs on the build host. *)
let prime = Z.(add one (add (shift_left (of_int 17) 192) (shift_left one 251)))
let reduce v = Z.erem v prime
let radix = Z.shift_left Z.one 256

let coordinates path =
  In_channel.with_open_bin path (fun ic ->
    let table = Hashtbl.create 16 in
    let binding = Str.regexp "static const uint64_t \\([A-Z0-9_]+\\)\\[4\\] = {" in
    let limb = Str.regexp "0x[0-9a-fA-F]+" in
    In_channel.input_lines ic |> List.iter (fun line ->
      if Str.string_match binding line 0 then begin
        let name = Str.matched_group 1 line and start = Str.match_end () in
        let rec read i pos acc =
          if i = 4 then acc else begin
            ignore (Str.search_forward limb line pos);
            let word = Z.of_string (Str.matched_string line) in
            read (i + 1) (Str.match_end ()) Z.(logor acc (shift_left word Stdlib.(64 * i)))
          end
        in
        Hashtbl.add table name (read 0 start Z.zero)
      end);
    fun name -> Hashtbl.find table (name ^ "_X"), Hashtbl.find table (name ^ "_Y"))

let add (x, y) (u, v) =
  let n, d = if Z.equal x u then begin
    assert (Z.equal y v);
    Z.(add (mul (of_int 3) (mul x x)) one), Z.(add y y)
  end else Z.sub v y, Z.sub u x in
  let slope = reduce Z.(mul n (invert d prime)) in
  let xx = reduce Z.(sub (sub (mul slope slope) x) u) in
  xx, reduce Z.(sub (mul slope (sub x xx)) y)

let coordinate z =
  let mont = reduce (Z.mul z radix) in
  let limbs = List.init 4 (fun i -> Z.format "%x" (Z.extract mont (64*i) 64)) in
  "{" ^ String.concat "," (List.map (fun s -> "0x" ^ s ^ "ULL") limbs) ^ "}"

let point (x, y) = "{" ^ coordinate x ^ "," ^ coordinate y ^ "}"

let windows name count digits base =
  Printf.printf "static const aff %s[%d][%d] = {\n" name count digits;
  let base = ref base in
  for _ = 1 to count do
    let multiple = ref !base in
    print_endline "{";
    for _ = 1 to digits do
      Printf.printf "%s,\n" (point !multiple);
      multiple := add !multiple !base
    done;
    print_endline "},";
    base := !multiple
  done;
  print_endline "};"

let () =
  let get = coordinates Sys.argv.(1) in
  Printf.printf "static const aff ped_shift = %s;\n" (point (get "SHIFT_POINT"));
  windows "ped_a" 31 255 (get "PEDERSEN_P0");
  windows "ped_a_high" 1 15 (get "PEDERSEN_P1");
  windows "ped_b" 31 255 (get "PEDERSEN_P2");
  windows "ped_b_high" 1 15 (get "PEDERSEN_P3")
