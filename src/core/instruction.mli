(** Instruction decoding (cairo-vm decoder.rs, including the v4.0.0
    classify_instruction restriction to Stwo-supported shapes).

    A decoded instruction is a non-zero int:
    bits 0..15 off0+2^15, 16..31 off1+2^15, 32..47 off2+2^15,
    48 dst_fp, 49 op0_fp, 50..51 op1 (0 op0, 1 imm, 2 fp, 3 ap),
    52..53 res (0 op1, 1 add, 2 mul, 3 unconstrained),
    54..55 pc (0 regular, 1 jump, 2 jump_rel, 3 jnz),
    56..57 ap (0 regular, 1 add, 2 add1, 3 add2),
    58..59 opcode (0 nop, 1 call, 2 ret, 3 assert_eq), 60 valid,
    61..62 opcode extension (0 Stone, 1 Blake, 2 BlakeFinalize, 3 QM31).
    The extension bits are meaningful only on a fresh decode: words with an
    extension are never cached, and bit 61 of a cached word is the fast
    loop's hint flag. *)

val ext_shift : int
(** Position of the opcode extension field. *)

val ext_mask : int
(** Mask of the opcode extension field. *)

exception Generic_instruction
(** A valid encoding without a dedicated Stwo opcode component. *)

val decode_word : Z.t -> int
(** Decode an instruction word, failing on invalid encodings.
    @raise Generic_instruction on shapes cairo-vm v4.0.0 cannot execute. *)

val decode_legacy_word : Z.t -> int
(** Decode a cairo-vm 3.2 instruction for the generic executor. *)
