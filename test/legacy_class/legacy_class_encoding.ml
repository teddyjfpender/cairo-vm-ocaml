let encode s =
  let buf = Buffer.create 32 in
  Cairovm.Legacy_class.python_string buf s;
  Buffer.contents buf

let () =
  (* PythonJsonFormatter in the pinned sequencer writes raw ASCII DEL and
     uses space-padded hex for non-ASCII BMP characters. *)
  assert (encode "A\127|é|λ|中|😀" = "\"A\127|\\u  e9|\\u 3bb|\\u4e2d|\\ud83d\\ude00\"");
  assert (encode "\"\\\b\t\n\012\r\001" = {|"\"\\\b\t\n\f\r\u0001"|});
  assert (encode "" = "\"\"");
  assert (try ignore (encode "\255"); false with Cairovm.Errors.Vm_error _ -> true)
