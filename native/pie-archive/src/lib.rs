//! Container-only bridge. The OCaml runner supplies all five uncompressed members.
use std::ffi::OsStr;
use std::fs::File;
use std::io::{self, BufWriter, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::slice;
use zip::result::{ZipError, ZipResult};
use zip::write::FileOptions;
use zip::{CompressionMethod, DateTime, ZipWriter};

pub struct Archive(ZipWriter<BufWriter<File>>);

// 0 is success, a positive value is the original platform errno, and -1
// identifies a container error without a platform error code.
fn io_status(error: io::Error) -> i32 {
    error.raw_os_error().unwrap_or(-1)
}

fn zip_status(result: ZipResult<()>) -> i32 {
    match result {
        Ok(()) => 0,
        Err(ZipError::Io(error)) => io_status(error),
        Err(_) => -1,
    }
}

/// # Safety
/// The filename is a valid byte buffer and out points to writable pointer storage.
#[no_mangle]
pub unsafe extern "C" fn ox_pie_create(
    path: *const u8,
    length: usize,
    out: *mut *mut Archive,
) -> i32 {
    let bytes = unsafe { slice::from_raw_parts(path, length) };
    match File::create(Path::new(OsStr::from_bytes(bytes))) {
        Ok(file) => {
            unsafe {
                *out = Box::into_raw(Box::new(Archive(ZipWriter::new(BufWriter::new(file)))));
            }
            0
        }
        Err(error) => io_status(error),
    }
}

/// # Safety
/// The caller has exclusive access to a live archive and a valid member name.
#[no_mangle]
pub unsafe extern "C" fn ox_pie_start(
    archive: *mut Archive,
    name: *const u8,
    length: usize,
) -> i32 {
    let bytes = unsafe { slice::from_raw_parts(name, length) };
    let Ok(name) = std::str::from_utf8(bytes) else {
        return -1;
    };
    let options = FileOptions::default()
        .compression_method(CompressionMethod::Deflated)
        .last_modified_time(DateTime::default())
        .large_file(true);
    zip_status(unsafe { &mut *archive }.0.start_file(name, options))
}

/// # Safety
/// The caller has exclusive access to a live archive and readable bytes.
#[no_mangle]
pub unsafe extern "C" fn ox_pie_append(
    archive: *mut Archive,
    data: *const u8,
    length: usize,
) -> i32 {
    match unsafe { &mut *archive }
        .0
        .write_all(unsafe { slice::from_raw_parts(data, length) })
    {
        Ok(()) => 0,
        Err(error) => io_status(error),
    }
}

/// # Safety
/// The caller has exclusive access to a live archive, and calls finish at most once.
#[no_mangle]
pub unsafe extern "C" fn ox_pie_finish(archive: *mut Archive) -> i32 {
    zip_status(
        unsafe { &mut *archive }
            .0
            .finish()
            .and_then(|mut writer| Ok(writer.flush()?)),
    )
}

/// # Safety
/// The pointer was returned by create and has not already been released.
#[no_mangle]
pub unsafe extern "C" fn ox_pie_drop(archive: *mut Archive) {
    if !archive.is_null() {
        drop(unsafe { Box::from_raw(archive) });
    }
}
