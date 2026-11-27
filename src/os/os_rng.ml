(* rand 0.10 StdRng uses ChaCha12. The Starknet OS seeds the stream from block
   hashes to make RandomEcPoint witnesses reproducible across sequencer runs. *)
type t = { state : int array; output : int array; mutable cursor : int }

let word x = x land 0xffffffff
let rotate x n = word ((x lsl n) lor (x lsr (32-n)))

let create seed =
  let key = Ec.be32 (Felt.to_z seed) in
  let state = Array.make 16 0 in
  Array.blit [|0x61707865; 0x3320646e; 0x79622d32; 0x6b206574|] 0 state 0 4;
  for i = 0 to 7 do state.(4+i) <- word (Int32.to_int (String.get_int32_le key (4*i))) done;
  {state; output=Array.make 16 0; cursor=16}

let refill rng =
  let x = rng.output in
  Array.blit rng.state 0 x 0 16;
  let quarter a b c d =
    x.(a) <- word (x.(a) + x.(b)); x.(d) <- rotate (x.(d) lxor x.(a)) 16;
    x.(c) <- word (x.(c) + x.(d)); x.(b) <- rotate (x.(b) lxor x.(c)) 12;
    x.(a) <- word (x.(a) + x.(b)); x.(d) <- rotate (x.(d) lxor x.(a)) 8;
    x.(c) <- word (x.(c) + x.(d)); x.(b) <- rotate (x.(b) lxor x.(c)) 7 in
  for _ = 1 to 6 do
    quarter 0 4 8 12; quarter 1 5 9 13; quarter 2 6 10 14; quarter 3 7 11 15;
    quarter 0 5 10 15; quarter 1 6 11 12; quarter 2 7 8 13; quarter 3 4 9 14
  done;
  for i = 0 to 15 do x.(i) <- word (x.(i) + rng.state.(i)) done;
  rng.state.(12) <- word (rng.state.(12) + 1);
  if rng.state.(12) = 0 then rng.state.(13) <- word (rng.state.(13) + 1);
  rng.cursor <- 0

let byte rng =
  if rng.cursor = 16 then refill rng;
  let x = rng.output.(rng.cursor) in
  rng.cursor <- rng.cursor + 1;
  Char.chr (x land 255)

let rec point rng =
  let x = Hintrt.z_of_be (String.init 31 (fun _ -> byte rng)) in
  match Ec.recover_y x with
  | None -> point rng
  | Some y -> Felt.of_z x, Felt.of_z (Z.min y (Z.sub Felt.p y))
