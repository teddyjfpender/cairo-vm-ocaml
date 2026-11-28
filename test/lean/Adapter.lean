import CairoVM.Runner.Execute
import CairoVM.Execution.Deduction
import Lean.Data.Json.Parser

open Lean CairoVM CairoVM.Runner

namespace Adapter

def natural (s : String) : Except String Nat := do
  if s.startsWith "0x" then
    let digits := (s.drop 2).toList
    if digits.isEmpty then throw "empty hexadecimal number"
    let mut n := 0
    for ch in digits do
      let k := ch.toLower.toNat
      let value := if ch.isDigit then k - '0'.toNat else k - 'a'.toNat + 10
      unless ch.isDigit || ('a'.toNat ≤ k && k ≤ 'f'.toNat) do throw "invalid hexadecimal digit"
      n := n * 16 + value
    return n
  let some n := s.toNat? | throw "invalid decimal number"
  return n

def load (layout : CairoVM.Runner.Layout) (json : Json) : Except String Plan := do
  let p ← natural (← json.getObjValAs? String "prime")
  unless p == feltModulus do throw "reject wrong-field-prime"
  let ids ← json.getObjVal? "identifiers"
  let .ok main := ids.getObjVal? "__main__.main" | throw "reject missing-main"
  let pc ← main.getObjValAs? Nat "pc"
  let builtins ← json.getObjValAs? (List String) "builtins"
  let hints ← json.getObjVal? "hints"
  unless (builtins.isEmpty || builtins == ["output"]) && hints == Json.mkObj [] do throw "unsupported hints or builtins"
  let declared := if builtins.isEmpty then [] else [Builtin.Registry.Name.output]
  let mut words := #[]
  for word in (← json.getObjValAs? (List String) "data") do
    let some w := Felt.ofCanonical? (← natural word) | throw "noncanonical field element"
    words := words.push w
  let some plan := prepare {layout := layout} ⟨words, declared, some pc, none, none⟩ | throw "invalid entrypoint"
  return plan

def execute (q : Plan) (s : MachineState Store) (trace : Array Registers) :
    Nat → Except String (MachineState Store × Array Registers)
  | 0 => throw "execution exceeded fuel"
  | fuel + 1 => do
    if s.regs.pc == q.endPC then return (s,trace)
    let next ← (Execution.Deduction.step .base s).mapError fun e => reprStr e
    execute q next (trace.push s.regs) fuel

def writeLE (bytes : ByteArray) (n width : Nat) : ByteArray := Id.run do
  let mut result := bytes
  for i in [:width] do result := result.push (n >>> (8*i)).toUInt8
  return result

def artifacts (q : Plan) : Except String (String × ByteArray × ByteArray) := do
  let start ← q.startState.mapError fun e => reprStr e
  let (state, trace) ← execute q start #[] 2049
  unless (validateEnd q state {} {}).isSome do throw "invalid final state"
  let sizes := (List.range q.segments.permanent).map (extent state.memory)
  let layout ← (Relocation.Layout.fromSizes sizes).mapError fun e => reprStr e
  let mut traceBytes := ByteArray.empty
  for r in trace do
    for a in [⟨1,r.ap⟩, ⟨1,r.fp⟩, r.pc] do
      let some n := layout.pointer a | throw "trace relocation failed"
      traceBytes := writeLE traceBytes n.val 8
  let cells ← state.memory.bindings.mapM fun (a,v) => do
    let some k := layout.cell a | throw "cell relocation failed"
    let some n := layout.value v | throw "value relocation failed"
    return (k.val, n.val)
  let mut memoryBytes := ByteArray.empty
  for (k,n) in cells.mergeSort (fun a b => a.1 ≤ b.1) do
    memoryBytes := writeLE (writeLE memoryBytes k 8) n 32
  let mut output := "Program Output:\n"
  if let some seg := q.baseFor .output then
    for i in [:extent state.memory seg] do
      let some (.felt v) := state.memory.read ⟨seg,i⟩ | throw "unsupported sparse or pointer output"
      let signed : Int := if v.val > feltModulus / 2 then (v.val : Int) - feltModulus else v.val
      output := output ++ toString signed ++ "\n"
  return (output,traceBytes,memoryBytes)

end Adapter

def main (args : List String) : IO UInt32 := do
  let [path, "--layout", layoutName, "--print_output", "--trace_file", trace, "--memory_file", mem] := args
    | IO.eprintln "unsupported flags"; return 2
  let some layout := CairoVM.Runner.Layout.parse layoutName | IO.eprintln "unknown layout"; return 2
  unless layout == .plain || layout == .small do IO.eprintln "unsupported layout"; return 2
  let text ← IO.FS.readFile path
  match Lean.Json.parse text >>= Adapter.load layout >>= Adapter.artifacts with
  | .error e =>
    IO.eprintln e
    return if e.startsWith "reject " then 1 else 2
  | .ok (output,t,m) =>
    IO.FS.writeBinFile trace t
    IO.FS.writeBinFile mem m
    IO.print output
    return 0
