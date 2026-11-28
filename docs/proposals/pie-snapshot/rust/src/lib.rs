//! Proposed safe wrapper. Link the extended OxCairo shared library on Linux.
use std::{ffi::c_char, fmt, marker::PhantomData, mem, ptr, ptr::NonNull, rc::Rc, slice};

#[repr(C)]
struct RawResult { _opaque: [u8; 0] }
#[repr(C)]
struct View { ptr: *const u8, len: usize }
#[repr(C)]
struct Diagnostic { message: [c_char; 256] }
#[repr(C)]
struct Options {
    struct_size: u32, profile: u32, layout: u32, outputs: u32,
    max_input_bytes: u64, max_inflated_bytes: u64, max_steps: u64,
    max_segment_cells: u64, max_output_bytes: u64,
}
#[link(name = "oxcairo.so", kind = "dylib", modifiers = "+verbatim")]
extern "C" {
    fn ox_pie_abi_major_v1() -> u32;
    fn ox_pie_run_v1(zip: *const u8, len: usize, opts: *const Options,
                     out: *mut *mut RawResult, err: *mut Diagnostic) -> u32;
    fn ox_pie_view_v1(result: *const RawResult, kind: u32, out: *mut View) -> u32;
    fn ox_pie_result_free_v1(result: *mut RawResult);
}
#[repr(u32)]
#[derive(Debug, Clone, Copy)]
pub enum Artifact { Trace = 1, Memory = 2, Pie = 4 }
#[repr(u32)]
#[derive(Debug, Clone, Copy)]
pub enum Layout { AllCairo = 1, Small = 2 }
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub input_bytes: u64, pub inflated_bytes: u64, pub steps: u64,
    pub segment_cells: u64, pub output_bytes: u64,
}
impl Default for Limits {
    fn default() -> Self {
        Self { input_bytes: 1 << 30, inflated_bytes: 4 << 30, steps: 32_000_000,
               segment_cells: 64_000_000, output_bytes: 4 << 30 }
    }
}
#[derive(Debug)]
pub struct Error { pub code: u32, pub message: String }
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "OxCairo error {} ({})", self.code, self.message)
    }
}
impl std::error::Error for Error {}

/// The native handle owns every slice lent by get(). V1 conservatively keeps
/// Rust handles thread-local. Distinct threads may independently call run().
pub struct Snapshot { raw: NonNull<RawResult>, _local: PhantomData<Rc<()>> }
impl Drop for Snapshot {
    fn drop(&mut self) { unsafe { ox_pie_result_free_v1(self.raw.as_ptr()) } }
}
fn internal(message: &str) -> Error { Error { code: 9, message: message.into() } }

/// Explicitly selects the sequencer-3.2.0 replay profile.
pub fn run(zip: &[u8], layout: Layout, outputs: &[Artifact],
           limits: Limits) -> Result<Snapshot, Error> {
    if unsafe { ox_pie_abi_major_v1() } != 1 {
        return Err(Error { code: 2, message: "unsupported ABI major".into() });
    }
    let opts = Options {
        struct_size: mem::size_of::<Options>() as u32, profile: 1, layout: layout as u32,
        outputs: outputs.iter().fold(0, |mask, &kind| mask | kind as u32),
        max_input_bytes: limits.input_bytes, max_inflated_bytes: limits.inflated_bytes,
        max_steps: limits.steps, max_segment_cells: limits.segment_cells,
        max_output_bytes: limits.output_bytes,
    };
    let mut raw = ptr::null_mut();
    let mut diagnostic = Diagnostic { message: [0; 256] };
    let code = unsafe { ox_pie_run_v1(zip.as_ptr(), zip.len(), &opts, &mut raw, &mut diagnostic) };
    if code != 0 {
        let bytes: Vec<u8> = diagnostic.message.iter().take_while(|&&x| x != 0)
            .map(|&x| x as u8).collect();
        return Err(Error { code, message: String::from_utf8_lossy(&bytes).into_owned() });
    }
    Ok(Snapshot { raw: NonNull::new(raw).ok_or_else(|| internal("null successful result"))?,
                  _local: PhantomData })
}
impl Snapshot {
    pub fn get(&self, kind: Artifact) -> Result<&[u8], Error> {
        let mut view = View { ptr: ptr::null(), len: 0 };
        let code = unsafe { ox_pie_view_v1(self.raw.as_ptr(), kind as u32, &mut view) };
        if code != 0 { return Err(Error { code, message: format!("reading {kind:?}") }); }
        if view.len == 0 { return Ok(&[]); }
        if view.ptr.is_null() || view.len > isize::MAX as usize {
            return Err(internal("invalid native view"));
        }
        // Provider guarantees one initialized immutable allocation, live for &self.
        Ok(unsafe { slice::from_raw_parts(view.ptr, view.len) })
    }
}
