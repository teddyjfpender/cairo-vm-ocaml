use oxcairo_pie::{run, Artifact::{Memory, Pie, Trace}, Layout, Limits};
use std::{error::Error, ffi::OsString, fs, io::{self, Write}, path::PathBuf};

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    if args.len() != 2 { return Err("usage: replay INPUT.zip OUTPUT_DIRECTORY".into()); }
    let input = fs::read(&args[0])?;
    let snapshot = run(&input, Layout::AllCairo, &[Trace, Memory, Pie], Limits::default())?;
    drop(input);
    let dir = PathBuf::from(&args[1]);
    fs::create_dir(&dir)?;
    for (kind, name) in [(Trace, "trace.bin"), (Memory, "memory.bin"), (Pie, "pie.zip")] {
        let bytes = snapshot.get(kind)?;
        let mut file = io::BufWriter::new(fs::File::create(dir.join(name))?);
        file.write_all(bytes)?;
        file.flush()?;
    }
    Ok(())
}
