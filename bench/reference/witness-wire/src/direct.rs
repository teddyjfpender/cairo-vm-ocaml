//! Streaming encoder over the materialized witness. Only the output byte
//! vector grows; class frames and word vectors write into the parent buffer.
use super::{Json, Result, MAX_BYTES};
use std::cmp::Ordering;

#[derive(Clone, Copy)]
enum Location {
    Document,
    Os,
    ModernClasses,
    LegacyClasses,
    ModernClass,
    Generic,
}

fn argument(out: &mut Vec<u8>, major: u8, value: u64) {
    let head = major << 5;
    match value {
        0..=23 => out.push(head | value as u8),
        24..=255 => out.extend_from_slice(&[head | 24, value as u8]),
        256..=65535 => {
            out.push(head | 25);
            out.extend_from_slice(&(value as u16).to_be_bytes());
        }
        65536..=0xffff_ffff => {
            out.push(head | 26);
            out.extend_from_slice(&(value as u32).to_be_bytes());
        }
        _ => {
            out.push(head | 27);
            out.extend_from_slice(&value.to_be_bytes());
        }
    }
}

fn text(out: &mut Vec<u8>, s: &str) {
    argument(out, 3, s.len() as u64);
    out.extend_from_slice(s.as_bytes());
}

fn byte_string(out: &mut Vec<u8>, append: impl FnOnce(&mut Vec<u8>) -> Result<()>) -> Result<()> {
    let start = out.len();
    out.extend_from_slice(&[0x5a, 0, 0, 0, 0]);
    let body = out.len();
    append(out)?;
    let n = out.len() - body;
    if n >= 65536 {
        out[start + 1..body].copy_from_slice(&u32::try_from(n)?.to_be_bytes());
    } else {
        let header = if n < 24 {
            1
        } else if n <= 255 {
            2
        } else {
            3
        };
        out.copy_within(body.., start + header);
        out.truncate(start + header + n);
        match header {
            1 => out[start] = 0x40 | n as u8,
            2 => {
                out[start] = 0x58;
                out[start + 1] = n as u8;
            }
            _ => {
                out[start] = 0x59;
                out[start + 1..start + 3].copy_from_slice(&(n as u16).to_be_bytes());
            }
        }
    }
    Ok(())
}

const DIGIT: [u8; 256] = {
    let mut table = [255; 256];
    let mut i = 0;
    while i < 10 {
        table[b'0' as usize + i] = i as u8;
        i += 1;
    }
    let mut i = 0;
    while i < 6 {
        table[b'a' as usize + i] = i as u8 + 10;
        table[b'A' as usize + i] = i as u8 + 10;
        i += 1;
    }
    table
};
const PRIME_LE: [u8; 32] = {
    let mut p = [0; 32];
    p[0] = 1;
    p[24] = 17;
    p[31] = 8;
    p
};

fn packed(out: &mut Vec<u8>, words: &[Json]) -> Result<()> {
    if words.len() > 4 << 20 {
        return Err("too many code words".into());
    }
    out.extend_from_slice(&u32::try_from(words.len())?.to_be_bytes());
    for word in words {
        let digits = word
            .as_str()
            .and_then(|s| s.strip_prefix("0x"))
            .ok_or("expected hex word")?
            .as_bytes();
        if digits.is_empty() || digits.len() > 64 {
            return Err("invalid word width".into());
        }
        let first = digits
            .iter()
            .position(|b| *b != b'0')
            .unwrap_or(digits.len());
        let width = (digits.len() - first).div_ceil(2);
        out.push(width as u8);
        let start = out.len();
        let mut end = digits.len();
        while end > first {
            let lo = DIGIT[digits[end - 1] as usize];
            end -= 1;
            let hi = if end > first {
                end -= 1;
                DIGIT[digits[end] as usize]
            } else {
                0
            };
            if (lo | hi) > 15 {
                return Err("invalid hex digit".into());
            }
            out.push((hi << 4) | lo);
        }
        if width == 32 && out[start..].iter().rev().cmp(PRIME_LE.iter().rev()) != Ordering::Less {
            return Err("field word exceeds prime".into());
        }
    }
    Ok(())
}

fn value(out: &mut Vec<u8>, v: &Json, loc: Location) -> Result<()> {
    match v {
        Json::Null => out.push(0xf6),
        Json::Bool(b) => out.push(if *b { 0xf5 } else { 0xf4 }),
        Json::Number(n) => {
            if let Some(u) = n.as_u64() {
                argument(out, 0, u);
            } else if let Some(i) = n.as_i64() {
                argument(out, 1, (!i) as u64);
            } else {
                return Err("reference fixture requires an exact integer".into());
            }
        }
        Json::String(s) => text(out, s),
        Json::Array(items) => {
            argument(out, 4, items.len() as u64);
            for item in items {
                value(out, item, Location::Generic)?;
            }
        }
        Json::Object(fields) => {
            argument(out, 5, fields.len() as u64);
            for (key, item) in fields {
                text(out, key);
                match (loc, key.as_str()) {
                    (Location::Document, "os_input") => value(out, item, Location::Os)?,
                    (Location::Os, "compiled_classes") => {
                        value(out, item, Location::ModernClasses)?
                    }
                    (Location::Os, "deprecated_compiled_classes") => {
                        value(out, item, Location::LegacyClasses)?
                    }
                    (Location::ModernClasses | Location::LegacyClasses, _) => {
                        argument(out, 6, 24);
                        let inner = if matches!(loc, Location::ModernClasses) {
                            Location::ModernClass
                        } else {
                            Location::Generic
                        };
                        byte_string(out, |out| value(out, item, inner))?;
                    }
                    (Location::ModernClass, "bytecode") => {
                        let words = item.as_array().ok_or("expected code array")?;
                        byte_string(out, |out| packed(out, words))?;
                    }
                    _ => value(out, item, Location::Generic)?,
                }
            }
        }
    }
    if out.len() > MAX_BYTES {
        return Err("payload too large".into());
    }
    Ok(())
}

pub fn encode(source: &Json, capacity: usize) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(capacity.min(MAX_BYTES));
    value(&mut out, source, Location::Document)?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn definite_lengths_match_cbor_library() {
        for n in [0, 23, 24, 255, 256, 65535, 65536] {
            let input = vec![0x55; n];
            let mut out = vec![0x80];
            byte_string(&mut out, |out| {
                out.extend_from_slice(&input);
                Ok(())
            })
            .unwrap();
            assert_eq!(&out[1..], {
                use cbor4ii::core::{enc::Encode, utils::BufWriter, Value};
                let mut b = BufWriter::new(Vec::new());
                Value::Bytes(input).encode(&mut b).unwrap();
                b.into_inner()
            });
        }
    }

    #[test]
    fn vector_matches_reference_and_checks_field_bounds() {
        let words = json!(["0x0", "0x0000", "0xaB", "0x0100", "0x123456789ABCDEf"]);
        let mut out = Vec::new();
        packed(&mut out, words.as_array().unwrap()).unwrap();
        assert_eq!(
            out,
            [0, 0, 0, 5, 0, 0, 1, 171, 2, 0, 1, 8, 239, 205, 171, 137, 103, 69, 35, 1]
        );
        for bad in [
            "0x",
            "0x0g",
            "0xg1",
            "0x800000000000011000000000000000000000000000000000000000000000001",
        ] {
            assert!(packed(&mut Vec::new(), &[json!(bad)]).is_err());
        }
    }
}
