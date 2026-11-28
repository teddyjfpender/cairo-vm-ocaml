//! One first and one subsequent job on the resident public supervisor.
use serde_json::{json, Value};
use std::{
    env,
    fs::File,
    io::{BufRead, BufReader, Write},
    path::Path,
    process::{Command, Stdio},
    time::Instant,
};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

fn compare(a: &Path, b: &Path) -> Result<()> {
    let mut left = BufReader::new(File::open(a)?);
    let mut right = BufReader::new(File::open(b)?);
    loop {
        let (x, y) = (left.fill_buf()?, right.fill_buf()?);
        let n = x.len().min(y.len());
        if x[..n] != y[..n] || x.is_empty() != y.is_empty() {
            return Err("PIE differs".into());
        }
        if n == 0 {
            return Ok(());
        }
        left.consume(n);
        right.consume(n);
    }
}

fn response(reader: &mut impl BufRead) -> Result<Value> {
    let mut s = String::new();
    if reader.read_line(&mut s)? == 0 {
        return Err("early worker exit".into());
    }
    Ok(serde_json::from_str(&s)?)
}

fn main() -> Result<()> {
    let a: Vec<_> = env::args().skip(1).collect();
    if a.len() != 8 {
        return Err("usage: time-guarded WORKER PACKED_PROGRAM SHA256 FIRST_INPUT SECOND_INPUT OUT_PATH FIRST_REF SECOND_REF".into());
    }
    let mut cmd = Command::new(&a[0]);
    cmd.args(["pie-v1", &a[1], "--sha256", &a[2]])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped());
    let start = Instant::now();
    let mut child = cmd.spawn()?;
    let mut reader = BufReader::new(child.stdout.take().unwrap());
    let mut input = child.stdin.take().unwrap();
    let ready = response(&mut reader)?;
    let startup = start.elapsed();
    if ready["status"] != "ready" || ready["program_sha256"] != a[2] {
        return Err("worker startup failed".into());
    }
    for i in 0..2 {
        let req = serde_json::to_vec(
            &json!({"schema":1,"witness":a[3+i],"output":a[5],"publication":"stored"}),
        )?;
        let begin = Instant::now();
        input.write_all(&req)?;
        input.write_all(b"\n")?;
        input.flush()?;
        let status = response(&mut reader)?;
        let elapsed = begin.elapsed();
        if status["status"] != "ok" || status["output"] != a[5] {
            return Err(format!("worker refused: {status}").into());
        }
        compare(Path::new(&a[5]), Path::new(&a[6 + i]))?;
        println!(
            "{}",
            json!({"job":i+1,"ready_ns":startup.as_nanos() as u64,
            "job_ns":elapsed.as_nanos() as u64,"bytes":status["bytes"],"sha256":status["sha256"]})
        );
    }
    drop(input);
    if !child.wait()?.success() {
        return Err("worker exited unsuccessfully".into());
    }
    Ok(())
}
