//! Alternate witnesses across six process launches each. Measure launch-to-ready
//! externally, and keep first and second job counters for each process.
use std::env;
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Instant;
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let a: Vec<_> = env::args_os().collect();
    if a.len() != 6 {
        return Err("usage: driver DIAGNOSTIC PACKED_PROGRAM WITNESS_A WITNESS_B OUT_DIR".into());
    }
    let out = Path::new(&a[5]);
    let mut log = File::create(out.join("phase-rows.jsonl"))?;
    for round in 0..6 {
        for slot in 0..2 {
            let case = (slot + round) % 2;
            let witness = &a[3 + case];
            let first = out.join(format!("case-{case}-first.zip"));
            let second = out.join(format!("case-{case}-second.zip"));
            let start = Instant::now();
            let mut child = Command::new(&a[1])
                .arg(&a[2])
                .arg(witness)
                .arg(first)
                .arg(witness)
                .arg(second)
                .stdout(Stdio::piped())
                .spawn()?;
            let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
            let init = lines.next().ok_or("missing initialized record")??;
            let ready = start.elapsed().as_nanos();
            writeln!(
                log,
                r#"{{"round":{round},"case":{case},"job":0,"launch_ready_ns":{ready},"ns":{init}}}"#
            )?;
            for job in 1..=2 {
                let phases = lines.next().ok_or("missing job record")??;
                writeln!(
                    log,
                    r#"{{"round":{round},"case":{case},"job":{job},"ns":{phases}}}"#
                )?;
            }
            if lines.next().is_some() || !child.wait()?.success() {
                return Err("worker failed".into());
            }
        }
    }
    Ok(())
}
