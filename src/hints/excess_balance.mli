(** The dex excess-balance hint. *)

(** rust_decimal arithmetic: [(m, s)] is m / 10^s; [None] is overflow. *)
module Dec : sig
  type t = Z.t * int

  val limit : Z.t
  val norm : t -> t option
  val mul : t -> t -> t option
  val add : t -> t -> t option
  val align : t -> t -> Z.t * Z.t * int
  val of_felt : Felt.t -> t option
  val to_felt : t -> Felt.t option

  type margin = { base : t; factor : t; mmf : t; shift : t }

  val imf : margin -> t -> t option
end

val register : Hintrt.registrar -> unit
