(** Stark-curve point hints (random_ec_point, recover_y). *)

val register : Hintrt.registrar -> unit

val be32 : Z.t -> string
(** Encode a nonnegative field element as 32 big-endian bytes. *)

val recover_y : Z.t -> Z.t option
(** Recover a Stark-curve ordinate for the given abscissa, if one exists. *)
