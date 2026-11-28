//! Container-only bridge. The OCaml runner supplies all five uncompressed members.
use std::ffi::OsStr;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::ptr;
use std::slice;
use zip::write::FileOptions;
use zip::{CompressionMethod, DateTime, ZipWriter};

pub struct Archive(ZipWriter<BufWriter<File>>);

/// # Safety
/// The filename is a valid byte buffer of the given length for this call.
#[no_mangle]
pub unsafe extern "C" fn ox_pie_create(path: *const u8, length: usize) -> *mut Archive {
    let bytes = unsafe { slice::from_raw_parts(path, length) };
    match File::create(Path::new(OsStr::from_bytes(bytes))) {
        Ok(file) => Box::into_raw(Box::new(Archive(ZipWriter::new(BufWriter::new(file))))),
        Err(_) => ptr::null_mut(),
    }
}

/// # Safety
/// The caller has exclusive access to a live archive and a valid member name.
#[no_mangle]
pub unsafe extern "C" fn ox_pie_start(
    archive: *mut Archive,
    name: *const u8,
    length: usize,
) -> bool {
    let bytes = unsafe { slice::from_raw_parts(name, length) };
    let Ok(name) = std::str::from_utf8(bytes) else {
        return false;
    };
    let options = FileOptions::default()
        .compression_method(CompressionMethod::Deflated)
        .last_modified_time(DateTime::default())
        .large_file(true);
    unsafe { &mut *archive }.0.start_file(name, options).is_ok()
}

/// # Safety
/// The caller has exclusive access to a live archive and readable bytes.
#[no_mangle]
pub unsafe extern "C" fn ox_pie_append(
    archive: *mut Archive,
    data: *const u8,
    length: usize,
) -> bool {
    unsafe { &mut *archive }
        .0
        .write_all(unsafe { slice::from_raw_parts(data, length) })
        .is_ok()
}

/// # Safety
/// The caller has exclusive access to a live archive, and calls finish at most once.
#[no_mangle]
pub unsafe extern "C" fn ox_pie_finish(archive: *mut Archive) -> bool {
    unsafe { &mut *archive }
        .0
        .finish()
        .and_then(|mut f| Ok(f.flush()?))
        .is_ok()
}

/// # Safety
/// The pointer was returned by create and has not already been released.
#[no_mangle]
pub unsafe extern "C" fn ox_pie_drop(archive: *mut Archive) {
    if !archive.is_null() {
        drop(unsafe { Box::from_raw(archive) });
    }
}
