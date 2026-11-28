open Errors
open Hintrt

type kind = Sha256 | Sha512

let unsigned64 x = Z.extract (Z.of_int64 x) 0 64
let word64 z =
  if Z.sign z < 0 || Z.numbits z > 64 then fail "SHA-512 word exceeds u64";
  Z.to_int64_unsigned z

let initial = function
  | Sha256 -> Array.map Z.of_int Sha256.iv
  | Sha512 -> Array.map unsigned64 Sha512.iv

let compress kind state message =
  match kind with
  | Sha256 -> Array.map Z.of_int (Sha256.compress (Array.map u32 state) (Array.map u32 message))
  | Sha512 -> Array.map unsigned64 (Sha512.compress (Array.map word64 state) (Array.map word64 message))

let process vm kind state input =
  if not (Felt.is_reloc state && Felt.is_reloc input) then fail "Expected SHA state and input pointers";
  let read p len = Array.init len (fun i -> z_at vm p i) in
  let result = compress kind (read state 8) (read input 16) in
  let ptr = Felt.reloc (Vm.add_temp_segment vm) 0 in
  write_arg vm ptr (Array.to_list (Array.map Felt.of_z result));
  ptr

let register reg =
  let relocate c vm =
    let src = get_member vm c "response" ["state_ptr"] and dst = get_ptr vm c "actual_out_state" in
    write_arg vm dst (read_range vm src 8);
    Vm.add_relocation_rule vm src dst in
  let finalize kind name c vm =
    let prefix = "starkware.cairo.common.cairo_" ^ name ^ "." ^ name ^ "_utils." in
    let batch = const_full c (prefix ^ "BATCH_SIZE") in
    let width = const_full c (prefix ^ String.uppercase_ascii name ^ "_INPUT_CHUNK_SIZE_FELTS") in
    if Z.sign batch <= 0 || not (Z.equal width (Z.of_int 16)) then fail "Invalid SHA batch configuration";
    let missing = Z.erem (Z.neg (get_z vm c "n")) batch in
    if Z.geq missing (Z.of_int 20) then fail "Invalid SHA padding count";
    let iv = initial kind and message = Array.make 16 Z.zero in
    let padding = Array.concat [message; iv; compress kind iv message] |> Array.map Felt.of_z |> Array.to_list in
    let dst = get_ptr vm c (name ^ "_ptr_end") in
    for i = 0 to Z.to_int missing - 1 do
      write_arg vm (Vm.reloc_add_felt dst (Felt.small (32*i))) padding
    done in
  reg "RelocateSha256Segment" relocate;
  reg "RelocateSha512Segment" relocate;
  reg {|# Add dummy pairs of input and output.
from starkware.cairo.common.cairo_sha256.sha256_utils import (
    IV,
    compute_message_schedule,
    sha2_compress_function,
)

number_of_missing_blocks = (-ids.n) % ids.BATCH_SIZE
assert 0 <= number_of_missing_blocks < 20
_sha256_input_chunk_size_felts = ids.SHA256_INPUT_CHUNK_SIZE_FELTS
assert 0 <= _sha256_input_chunk_size_felts < 100

message = [0] * _sha256_input_chunk_size_felts
w = compute_message_schedule(message)
output = sha2_compress_function(IV, w)
padding = (message + IV + output) * number_of_missing_blocks
segments.write_arg(ids.sha256_ptr_end, padding)|} (finalize Sha256 "sha256");
  reg "Sha256Finalize" (finalize Sha256 "sha256");
  reg {|# Add dummy pairs of input and output.
from starkware.cairo.common.cairo_sha512.sha512_utils import (
    SHA512_IV,
    compute_message_schedule,
    sha2_compress_function,
)

number_of_missing_blocks = (-ids.n) % ids.BATCH_SIZE
assert 0 <= number_of_missing_blocks < 20
_sha512_input_chunk_size_felts = ids.SHA512_INPUT_CHUNK_SIZE_FELTS
assert 0 <= _sha512_input_chunk_size_felts < 100

message = [0] * _sha512_input_chunk_size_felts
w = compute_message_schedule(message)
output = sha2_compress_function(SHA512_IV, w)
padding = (message + SHA512_IV + output) * number_of_missing_blocks
segments.write_arg(ids.sha512_ptr_end, padding)|} (finalize Sha512 "sha512");
  reg "Sha512Finalize" (finalize Sha512 "sha512")
