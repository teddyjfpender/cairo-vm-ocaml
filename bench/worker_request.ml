exception Refusal of int * string

let refuse code detail = raise (Refusal (code, detail))
let code_name = function
  | 2 -> "invalid_request" | 4 -> "program_mismatch" | 5 -> "invalid_input"
  | 6 -> "unsupported_randomized_encryption" | 20 -> "step_limit"
  | 21 -> "memory_limit" | 22 -> "wall_limit" | 23 -> "output_limit"
  | 24 -> "file_limit" | 25 -> "storage_limit" | 26 -> "busy"
  | 27 -> "io_error" | 28 -> "interrupted" | _ -> "internal_fault"

let refusal code detail = `Assoc ["schema", `Int 1; "status", `String "rejected";
                                   "code", `String (code_name code); "detail", `String detail]
let err_code = function
  | Unix.ENOMEM -> 21 | Unix.EFBIG -> 23 | Unix.EMFILE | Unix.ENFILE -> 24
  | Unix.ENOSPC -> 25 | e when Unix.error_message e = "Disk quota exceeded" -> 25
  | _ -> 27

let classify = function
  | Refusal (code, detail) -> code, detail
  | Cairovm.Os_hints.Randomized_encryption -> 6, "randomized encryption"
  | Cairovm.Runner.Step_limit -> 20, "step limit"
  | Out_of_memory -> 21, "memory exhausted"
  | Unix.Unix_error (e, _, _) -> err_code e, Unix.error_message e
  | Sys_error detail ->
      let suffix = List.find_opt (fun e ->
          let reason = Unix.error_message e in
          detail = reason || String.ends_with ~suffix:(": " ^ reason) detail)
          [Unix.ENOMEM; Unix.EFBIG; Unix.EMFILE; Unix.ENFILE; Unix.ENOSPC] in
      (match suffix with Some e -> err_code e | None ->
        if String.ends_with ~suffix:"Disk quota exceeded" detail then 25 else 27), detail
  | Cairovm.Errors.Vm_error msg | Cairovm.Program.Parse_error msg
  | Yojson.Json_error msg | Failure msg | Invalid_argument msg
  | Yojson.Safe.Util.Type_error (msg, _) -> 5, msg
  | e -> 70, Printexc.to_string e

let fields names = function
  | `Assoc xs when List.for_all (fun (k,_) -> List.mem k names) xs &&
                   List.length xs = List.length (List.sort_uniq String.compare (List.map fst xs)) -> xs
  | _ -> refuse 2 "expected object with recognized, unique fields"

let parse raw = try Yojson.Safe.from_string raw with Yojson.Json_error _ -> refuse 2 "invalid JSON"
type limits = { steps:int; memory:int; wall:int; output_bytes:int; files:int }
let defaults = { steps=100_000_000; memory=4 lsl 30; wall=120_000; output_bytes=1 lsl 30; files=128 }
let limits ?ceiling initial json =
  let xs = fields ["steps"; "memory_bytes"; "wall_ms"; "output_bytes"; "open_files"] json in
  let get key f = let top = Option.fold ~none:max_int ~some:f ceiling in
    match List.assoc_opt key xs with
    | None -> min (f initial) top
    | Some (`Int n) when n > 0 && n <= top -> n
    | _ -> refuse 2 ("invalid limit " ^ key) in
  {steps=get "steps" (fun l -> l.steps); memory=get "memory_bytes" (fun l -> l.memory);
   wall=get "wall_ms" (fun l -> l.wall); output_bytes=get "output_bytes" (fun l -> l.output_bytes);
   files=get "open_files" (fun l -> l.files)}

type publication = Stored | Rust | Standard
type job = {witness:string; output:string; limits:limits; profile:publication}

let request ceiling raw =
  let xs = fields ["schema"; "witness"; "output"; "publication"; "limits"] (parse raw) in
  if List.assoc_opt "schema" xs <> Some (`Int 1) then refuse 2 "expected schema 1";
  let path key = match List.assoc_opt key xs with
    | Some (`String p) when Filename.is_relative p = false && not (String.contains p '\000') -> p
    | _ -> refuse 2 ("expected absolute path for " ^ key) in
  let limits = limits ~ceiling defaults (Option.value (List.assoc_opt "limits" xs) ~default:(`Assoc [])) in
  if limits.memory < 32 lsl 20 then refuse 21 "memory budget below minimum";
  if limits.files < 8 then refuse 24 "file budget below minimum";
  let profile = match List.assoc_opt "publication" xs with
    | None | Some (`String "os-host-standard") -> Standard
    | Some (`String "rust-3.2") -> Rust | Some (`String "stored") -> Stored
    | _ -> refuse 2 "unknown publication" in
  {witness=path "witness"; output=path "output"; limits; profile}
