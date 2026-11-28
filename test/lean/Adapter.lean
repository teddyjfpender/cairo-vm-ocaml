import Verification.Semantics.Cpu
import Mathlib.Algebra.Field.ZMod
import Lean.Data.Json.Parser
import Std.Data.TreeMap

open Lean

namespace Adapter

abbrev prime : Nat := 2^251 + 17 * 2^192 + 1
abbrev Word := ZMod prime
abbrev Memory := Std.TreeMap Nat Word
abbrev Regs := RegisterState Word

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

def writeLE (bytes : ByteArray) (n width : Nat) : ByteArray := Id.run do
  let mut result := bytes
  for i in [:width] do result := result.push (n >>> (8*i)).toUInt8
  return result

structure Program where
  words : Array Nat
  entry : Nat
  output : Bool

def load (layout : String) (json : Json) : Except String Program := do
  unless (← natural (← json.getObjValAs? String "prime")) == prime do throw "reject wrong-field-prime"
  let ids ← json.getObjVal? "identifiers"
  let .ok main := ids.getObjVal? "__main__.main" | throw "reject missing-main"
  let entry ← main.getObjValAs? Nat "pc"
  let builtins ← json.getObjValAs? (List String) "builtins"
  let hints ← json.getObjVal? "hints"
  unless builtins.isEmpty || (builtins == ["output"] && layout == "small") do throw "unsupported builtins"
  unless hints == Json.mkObj [] do throw "unsupported hints"
  let words ← (← json.getObjValAs? (Array String) "data").mapM natural
  unless entry < words.size && words.all (· < prime) do throw "invalid program"
  return ⟨words, entry, !builtins.isEmpty⟩

/-- Restrict flags to the declared, independently exercised instruction forms.
Offsets are decoded from each original instruction word. -/
def decode (w : Nat) : Except String Instruction := do
  let f := w >>> 48
  unless [0x4806,0x4850,0x4830,0x208b,0x1104,0x107,0x206,0x4002,0x4826].contains f do
    throw "unsupported instruction flags"
  let bit := fun (n : Nat) => f.testBit n
  let i : Instruction := ⟨BitVec.ofNat 16 w, BitVec.ofNat 16 (w >>> 16), BitVec.ofNat 16 (w >>> 32),
    bit 0,bit 1,bit 2,bit 3,bit 4,bit 5,bit 6,bit 7,bit 8,bit 9,bit 10,bit 11,bit 12,bit 13,bit 14⟩
  unless i.toNat == w do throw "invalid instruction encoding"
  if i.op1Imm && i.offOp1.toNat != 32769 then throw "invalid immediate offset"
  if i.opcodeRet && w != 0x208b7fff7fff7ffe then throw "unsupported return form"
  if i.opcodeCall && w != 0x1104800180018000 then throw "unsupported call form"
  return i

structure Segments where
  stack : Nat
  output : Nat
  stop : Nat

structure State where
  regs : Regs
  mem : Memory
  trace : Array Regs := #[]

def initial (p : Program) (l : Segments) : State := Id.run do
  let mut mem : Memory := {}
  for (word,k) in p.words.toList.zipIdx do mem := mem.insert (1+k) (word : Word)
  let frame := (if p.output then [l.output] else []) ++ [l.stop,l.stop]
  for (ptr,k) in frame.zipIdx do mem := mem.insert (l.stack+k) (ptr : Word)
  let top : Word := l.stack + frame.length
  return ⟨⟨1+p.entry,top,top⟩, mem, #[]⟩

def lookup (m : Memory) (k : Word) : Except String Word :=
  match m.get? k.val with
  | some v => .ok v
  | none => .error "read from an uninitialized cell"

def put (l : Segments) (m : Memory) (k v : Word) : Except String Memory := do
  unless l.stack ≤ k.val && k.val < l.stop do throw "write outside execution or output segment"
  if let some old := m.get? k.val then
    unless old == v do throw "inconsistent memory"
  return m.insert k.val v

/-- Supply sparse, write-once operand deductions to the public CPU's total-memory interface.
Each instruction form checks its necessary reads before invoking the public transitions. -/
def step (l : Segments) (s : State) : Except String State := do
  let r := s.regs
  unless r.pc.val > 0 && r.pc.val < l.stack do throw "PC outside program"
  let i ← decode (← lookup s.mem r.pc).val
  let dst := (if i.dstReg then r.fp else r.ap) + (i.offDst.toBiased16 : Word)
  let op0 := (if i.op0Reg then r.fp else r.ap) + (i.offOp0.toBiased16 : Word)
  let mut mem := s.mem
  if i.opcodeCall then
    mem ← put l mem dst r.fp
    mem ← put l mem op0 (r.pc + i.size)
  let base ← if i.op1Imm then pure r.pc else if i.op1Ap then pure r.ap
    else if i.op1Fp then pure r.fp else lookup mem op0
  let op1 := base + (i.offOp1.toBiased16 : Word)
  if i.opcodeAssertEq && (mem.get? op1.val).isNone && !i.resAdd && !i.resMul then
    mem ← put l mem op1 (← lookup mem dst)
  let _ ← lookup mem op1
  if i.resAdd || i.resMul then
    let _ ← lookup mem op0
  if i.opcodeAssertEq then
    let view := fun (k : Word) => mem.getD k.val 0
    let some value := i.res view r | throw "undefined assertion result"
    mem ← put l mem dst value
  if i.opcodeRet || i.pcJnz then
    let _ ← lookup mem dst
  let view := fun (k : Word) => mem.getD k.val 0
  let some pc := i.nextPc view r | throw "undefined PC"
  let some ap := i.nextAp view r | throw "undefined AP"
  let some fp := i.nextFp view r | throw "undefined FP"
  return ⟨⟨pc,ap,fp⟩,mem,s.trace.push r⟩

def execute (l : Segments) (s : State) : Nat → Except String State
  | 0 => throw "execution exceeded fuel"
  | fuel+1 => do
    if s.regs.pc.val == l.stop then
      unless s.regs.fp.val == l.stop do throw "invalid return frame"
      return s
    execute l (← step l s) fuel

def extent (m : Memory) (lo hi : Nat) : Nat :=
  m.toList.foldl (fun n (a,_) => if lo ≤ a && a < hi then max n (a+1-lo) else n) 0

def run (p : Program) (l : Segments) := execute l (initial p l) 2049

/-- Public semantics use flat field addresses. First size the execution/output segments on
disjoint intervals, then execute again at their actual relocated addresses. Only the second
execution supplies observations. Check its inferred segment sizes and returned output pointer. -/
def artifacts (p : Program) : Except String (String × ByteArray × ByteArray) := do
  let stack := 1 + p.words.size
  let sizing : Segments := ⟨stack,stack+65536,stack+131072⟩
  let warm ← run p sizing
  let a := extent warm.mem stack sizing.output
  let b := extent warm.mem sizing.output sizing.stop
  let flat : Segments := ⟨stack,stack+a,stack+a+b⟩
  let state ← run p flat
  unless extent state.mem stack flat.output == a && extent state.mem flat.output flat.stop == b do
    throw "inconsistent segment sizes after relocation"
  let mut stdout := "Program Output:\n"
  if p.output then
    unless (← lookup state.mem (state.regs.ap-1)).val == flat.stop do throw "incorrect output stop"
    for offset in [:b] do
      let n := (← lookup state.mem (flat.output+offset)).val
      let signed : Int := if n > prime / 2 then (n : Int)-prime else n
      stdout := stdout ++ toString signed ++ "\n"
  let mut trace := ByteArray.empty
  for r in state.trace do
    for v in [r.ap,r.fp,r.pc] do trace := writeLE trace v.val 8
  let mut memory := ByteArray.empty
  for (k,v) in state.mem.toList do memory := writeLE (writeLE memory k 8) v.val 32
  return (stdout,trace,memory)

end Adapter

def main (args : List String) : IO UInt32 := do
  let [path,"--layout",layout,"--print_output","--trace_file",trace,"--memory_file",mem] := args
    | IO.eprintln "unsupported flags"; return 2
  unless ["small","plain"].contains layout do IO.eprintln "unsupported layout"; return 2
  let text ← IO.FS.readFile path
  match Lean.Json.parse text >>= Adapter.load layout >>= Adapter.artifacts with
  | .error e => IO.eprintln e; return if e.startsWith "reject " then 1 else 2
  | .ok (output,t,m) =>
    IO.FS.writeBinFile trace t
    IO.FS.writeBinFile mem m
    IO.print output
    return 0
