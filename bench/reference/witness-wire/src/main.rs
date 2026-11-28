//! Independent OXW1 producer for integral reference fixtures.
//! A native host can build the same ordered values from its witness directly.
mod direct;
use cbor4ii::core::{enc::Encode, utils::BufWriter, Value};
use serde_json::Value as Json;
use std::{
    env,
    fs::File,
    io::{BufReader, BufWriter as FileWriter, Write},
};

const MAX_BYTES: usize = 256 << 20;
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

fn encode(value: &Value) -> Result<Vec<u8>> {
    let mut buf = BufWriter::new(Vec::new());
    value.encode(&mut buf).map_err(|e| format!("{e:?}"))?;
    Ok(buf.into_inner())
}

fn cbor(v: Json) -> Result<Value> {
    Ok(match v {
        Json::Null => Value::Null,
        Json::Bool(b) => Value::Bool(b),
        Json::Number(n) => {
            let value = n
                .as_i64()
                .map(i128::from)
                .or_else(|| n.as_u64().map(i128::from));
            Value::Integer(value.ok_or("reference fixture requires an exact 64-bit integer")?)
        }
        Json::String(s) => Value::Text(s),
        Json::Array(a) => Value::Array(a.into_iter().map(cbor).collect::<Result<_>>()?),
        Json::Object(o) => Value::Map(
            o.into_iter()
                .map(|(k, v)| Ok((Value::Text(k), cbor(v)?)))
                .collect::<Result<_>>()?,
        ),
    })
}

fn pack_words(words: Vec<Value>) -> Result<Value> {
    let mut out = u32::try_from(words.len())?.to_be_bytes().to_vec();
    for word in words {
        let s = match &word {
            Value::Text(s) => s.strip_prefix("0x").ok_or("expected a hex CASM word")?,
            _ => return Err("reference fixture requires hex CASM words".into()),
        };
        if s.is_empty() || s.len() > 64 || !s.as_bytes().iter().all(u8::is_ascii_hexdigit) {
            return Err("invalid CASM word".into());
        }
        let digits = s.trim_start_matches('0');
        out.push(u8::try_from(digits.len().div_ceil(2))?);
        for pair in digits.as_bytes().rchunks(2) {
            out.push(u8::from_str_radix(std::str::from_utf8(pair)?, 16)?);
        }
    }
    Ok(Value::Bytes(out))
}

fn member<'a>(obj: &'a mut Value, name: &str) -> Result<&'a mut Value> {
    let Value::Map(entries) = obj else {
        return Err("expected object".into());
    };
    entries
        .iter_mut()
        .find_map(|(k, v)| matches!(k, Value::Text(s) if s==name).then_some(v))
        .ok_or_else(|| format!("missing {name}").into())
}

fn frame_classes(doc: &mut Value, name: &str, dense: bool) -> Result<()> {
    let Value::Map(classes) = member(member(doc, "os_input")?, name)? else {
        return Err("expected classes".into());
    };
    for (_, class) in classes {
        if dense {
            let bytecode = member(class, "bytecode")?;
            let Value::Array(words) = bytecode else {
                return Err("expected bytecode list".into());
            };
            *bytecode = pack_words(std::mem::take(words))?;
        }
        *class = Value::Tag(24, Box::new(Value::Bytes(encode(class)?)));
    }
    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args.len() != 2 {
        return Err("usage: witness-interop INPUT.json NEW_OUTPUT.oxw".into());
    }
    let file = File::open(&args[0])?;
    let source_size = file.metadata()?.len();
    if source_size > MAX_BYTES as u64 {
        return Err("fixture too large".into());
    }
    let timer = std::time::Instant::now();
    let source: Json = serde_json::from_reader(BufReader::new(file))?;
    let parsed = timer.elapsed();
    let encoding = std::time::Instant::now();
    let output = File::create_new(&args[1])?;
    let mut output = FileWriter::new(output);
    let format = env::var("OXCAIRO_WITNESS_FORMAT").unwrap_or_else(|_| "direct".to_string());
    match format.as_str() {
        "json" => serde_json::to_writer(&mut output, &source)?,
        "direct" => {
            let payload = direct::encode(&source, source_size as usize * 3 / 5)?;
            output.write_all(b"OXW1")?;
            output.write_all(&u32::try_from(payload.len())?.to_be_bytes())?;
            output.write_all(&payload)?;
        }
        "oxw" => {
            let mut doc = cbor(source)?;
            frame_classes(&mut doc, "compiled_classes", true)?;
            frame_classes(&mut doc, "deprecated_compiled_classes", false)?;
            let payload = encode(&doc)?;
            if payload.len() > MAX_BYTES {
                return Err("payload too large".into());
            }
            output.write_all(b"OXW1")?;
            output.write_all(&u32::try_from(payload.len())?.to_be_bytes())?;
            output.write_all(&payload)?;
        }
        _ => return Err("expected json, direct or oxw".into()),
    }
    output.flush()?;
    let encode_ns = encoding.elapsed().as_nanos() as u64;
    if env::var_os("OXCAIRO_WITNESS_TIMING").is_some() {
        println!(
            "{}",
            serde_json::json!({"parse_ns":parsed.as_nanos() as u64,"encode_ns":encode_ns,"format":format})
        );
    }
    Ok(())
}
