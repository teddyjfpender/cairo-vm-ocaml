//! Bound the measurement between a materialized value and completed PIE.
use serde_json::{json, Value};
use std::{
    env,
    fs::{self, File},
    io::{BufRead, BufReader, BufWriter, Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Instant,
};
use witness_interop::{direct, Result};

fn exact(left: impl Read, right: impl Read) -> Result<()> {
    let mut a = BufReader::new(left);
    let mut b = BufReader::new(right);
    loop {
        let (x, y) = (a.fill_buf()?, b.fill_buf()?);
        let n = x.len().min(y.len());
        if x[..n] != y[..n] || (x.is_empty() != y.is_empty()) {
            return Err("content mismatch".into());
        }
        if n == 0 {
            return Ok(());
        }
        a.consume(n);
        b.consume(n);
    }
}

fn compare_members(archive: &Path, reference: &Path) -> Result<()> {
    let mut a = zip::ZipArchive::new(File::open(archive)?)?;
    let mut b = zip::ZipArchive::new(File::open(reference)?)?;
    if a.len() != 5 || b.len() != 5 {
        return Err("unexpected member count".into());
    }
    for name in [
        "metadata.json",
        "additional_data.json",
        "version.json",
        "execution_resources.json",
        "memory.bin",
    ] {
        let (left, right) = (a.by_name(name)?, b.by_name(name)?);
        if name == "memory.bin" {
            exact(left, right)?;
        } else {
            let l: Value = serde_json::from_reader(left)?;
            let r: Value = serde_json::from_reader(right)?;
            if l != r {
                return Err(format!("different {name}").into());
            }
        }
    }
    Ok(())
}

fn reply(reader: &mut impl BufRead) -> Result<Value> {
    let mut s = String::new();
    if reader.read_line(&mut s)? == 0 {
        return Err("worker closed".into());
    }
    Ok(serde_json::from_str(&s)?)
}

fn main() -> Result<()> {
    let a: Vec<_> = env::args().skip(1).collect();
    if a.len() != 9 {
        return Err("usage: time-materialized ARM WORKER PROGRAM PIN FIRST_JSON SECOND_JSON OUTPUT FIRST_REF SECOND_REF".into());
    }
    let arm = &a[0];
    let rust = arm == "rust-json";
    if !rust && arm != "ox-json" && arm != "ox-direct" {
        return Err("expected rust-json, ox-json or ox-direct".into());
    }
    let mut source = Vec::new();
    for index in [4, 5] {
        let f = File::open(&a[index])?;
        let capacity = f.metadata()?.len() as usize * 3 / 5;
        let v: Value = serde_json::from_reader(BufReader::new(f))?;
        source.push((v, capacity));
    }
    let mut cmd = Command::new(&a[1]);
    if rust {
        cmd.arg("stored");
    } else {
        cmd.args(["pie-v1", &a[2], "--sha256", &a[3]]);
    }
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped());
    let ready_start = Instant::now();
    let mut child = cmd.spawn()?;
    let mut read = BufReader::new(child.stdout.take().unwrap());
    let mut write = child.stdin.take().unwrap();
    let ready = reply(&mut read)?;
    if rust {
        if !ready["compiler_prepare_s"].is_number() {
            return Err("Rust readiness mismatch".into());
        }
    } else if ready["status"] != "ready" || ready["program_sha256"] != a[3] {
        return Err("guard readiness mismatch".into());
    }
    let startup = ready_start.elapsed();
    for (i, (v, capacity)) in source.iter().enumerate() {
        let encoded = PathBuf::from(format!("{}.{}.witness", a[6], i));
        let output = Path::new(&a[6]);
        let reference = Path::new(&a[7 + i]);
        let begin = Instant::now();
        {
            let mut out = BufWriter::new(File::create_new(&encoded)?);
            if arm == "ox-direct" {
                let payload = direct::encode(v, *capacity)?;
                out.write_all(b"OXW1")?;
                out.write_all(&u32::try_from(payload.len())?.to_be_bytes())?;
                out.write_all(&payload)?;
            } else {
                serde_json::to_writer(&mut out, v)?;
            }
            out.flush()?;
        }
        let submitted = Instant::now();
        if rust {
            writeln!(write, "{}\t{}", encoded.display(), output.display())?;
        } else {
            serde_json::to_writer(
                &mut write,
                &json!({"schema":1,"witness":encoded,"output":output,"publication":"stored"}),
            )?;
            writeln!(write)?;
        }
        write.flush()?;
        let receipt = reply(&mut read)?;
        let done = Instant::now();
        if rust {
            if !receipt["total_s"].is_number() {
                return Err("Rust job failed".into());
            }
        } else {
            if receipt["status"] != "ok" || receipt["output"] != a[6] {
                return Err(format!("failed job {receipt}").into());
            }
            exact(File::open(output)?, File::open(reference)?)?;
        }
        compare_members(output, reference)?;
        println!(
            "{}",
            json!({"job":i+1,"arm":arm,"ready_ns":startup.as_nanos() as u64,
            "encode_ns":(submitted-begin).as_nanos() as u64,
            "worker_ns":(done-submitted).as_nanos() as u64,
            "total_ns":(done-begin).as_nanos() as u64,"canonical_members":5})
        );
        fs::remove_file(encoded)?;
    }
    drop(write);
    if !child.wait()?.success() {
        return Err("worker exit".into());
    }
    Ok(())
}
