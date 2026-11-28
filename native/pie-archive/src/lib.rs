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
    level_one: bool,
) -> i32 {
    let bytes = unsafe { slice::from_raw_parts(name, length) };
    let Ok(name) = std::str::from_utf8(bytes) else {
        return -1;
    };
    let options = FileOptions::default()
        .compression_method(CompressionMethod::Deflated)
        .compression_level(if level_one { Some(1) } else { None })
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

/// Encode a level-one raw deflate range. Intermediate ranges finish on a byte
/// boundary, allowing the caller to concatenate them into a single ZIP member.
fn encode_range(input: &[u8], last: bool) -> io::Result<Vec<u8>> {
    use flate2::{write::DeflateEncoder, Compress, Compression, FlushCompress};
    let level = Compression::fast();
    if last {
        let mut stream = DeflateEncoder::new(Vec::new(), level);
        stream.write_all(input)?;
        return stream.finish();
    }
    let mut stream = Compress::new(level, false);
    let mut output = Vec::with_capacity(input.len() / 3 + 4096);
    for _ in 0..input.len() / 64 + 4096 {
        if output.capacity() - output.len() < 4096 {
            output.reserve(output.capacity().max(4096));
        }
        let consumed = stream.total_in() as usize;
        let written = output.len();
        stream
            .compress_vec(&input[consumed..], &mut output, FlushCompress::Sync)
            .map_err(io::Error::other)?;
        if stream.total_in() as usize == input.len() && output.ends_with(&[0, 0, 255, 255]) {
            return Ok(output);
        }
        if output.len() == written && consumed == stream.total_in() as usize {
            return Err(io::Error::other("deflate sync flush made no progress"));
        }
    }
    Err(io::Error::other(
        "deflate sync flush exceeded its iteration bound",
    ))
}

fn verifies(input: &[u8], encoded: &[u8], last: bool) -> bool {
    use flate2::{Decompress, FlushDecompress, Status};
    // A non-final range ends at a flush boundary. Finish it independently
    // with an empty final stored block before checking every decoded byte.
    let suffix: &[u8] = if last { &[] } else { &[1, 0, 0, 255, 255] };
    let mut decoder = Decompress::new(false);
    let mut buffer = [0; 32768];
    loop {
        let consumed = decoder.total_in() as usize;
        let produced = decoder.total_out() as usize;
        let source = if consumed < encoded.len() {
            &encoded[consumed..]
        } else {
            &suffix[consumed - encoded.len()..]
        };
        let Ok(status) = decoder.decompress(source, &mut buffer, FlushDecompress::None) else {
            return false;
        };
        let end = decoder.total_out() as usize;
        if input.get(produced..end) != Some(&buffer[..end - produced]) {
            return false;
        }
        if status == Status::StreamEnd {
            return end == input.len()
                && decoder.total_in() as usize == encoded.len() + suffix.len();
        }
        if produced == end && consumed == decoder.total_in() as usize {
            return false;
        }
    }
}

/// # Safety
/// Caller supplies nonoverlapping valid buffers of their respective lengths.
#[no_mangle]
pub unsafe extern "C" fn ox_pie_deflate_range(
    input: *const u8,
    len: usize,
    last: bool,
    output: *mut u8,
    capacity: usize,
) -> isize {
    let input = unsafe { slice::from_raw_parts(input, len) };
    match encode_range(input, last) {
        Ok(bytes) if bytes.len() <= capacity && verifies(input, &bytes, last) => {
            unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len()) };
            bytes.len() as isize
        }
        _ => -1,
    }
}

#[cfg(test)]
mod range_tests {
    use super::{encode_range, verifies};
    use flate2::read::DeflateDecoder;
    use std::io::Read;

    #[test]
    fn ranges_recover_every_byte_and_reject_incomplete_or_trailing_data() {
        let width = 32_768 * 40;
        let mut seed = 1_u32;
        let data: Vec<u8> = (0..width)
            .map(|_| {
                seed ^= seed << 13;
                seed ^= seed >> 17;
                seed ^= seed << 5;
                seed as u8
            })
            .collect();
        for input in [&[][..], &data[..1], &data[..32769], &data[..]] {
            let mut joined = Vec::new();
            for last in [false, true] {
                let mut encoded = encode_range(input, last).unwrap();
                assert!(verifies(input, &encoded, last));
                assert!(!verifies(input, &encoded[..encoded.len() - 1], last));
                assert!(!verifies(b"different source bytes", &encoded, last));
                joined.extend_from_slice(&encoded);
                encoded.push(0);
                assert!(!verifies(input, &encoded, last));
            }
            let mut decoded = Vec::new();
            DeflateDecoder::new(&joined[..])
                .read_to_end(&mut decoded)
                .unwrap();
            assert_eq!(decoded.len(), 2 * input.len());
            assert_eq!(&decoded[..input.len()], input);
            assert_eq!(&decoded[input.len()..], input);
        }
    }
}
