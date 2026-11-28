(* ZIP32 reserves the all-ones field value for ZIP64. The production writer
   leaves 64 MiB of headroom when choosing its memory encoding. *)
let max_field = 0xffff_fffe
let memory_cutoff = 0xffff_ffff - (64 lsl 20)

let fits_field n = n >= 0 && n <= max_field
let fits_production_memory n = n >= 0 && n < memory_cutoff
