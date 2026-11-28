//! Each arm retains one process per sequence. Measure only through the completed
//! reply, then compare every emitted member outside that time interval.
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    env,
    fs::{self, File},
    io::{BufRead, BufReader, Read, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc::{self, Receiver},
    thread,
    time::{Duration, Instant},
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
fn string<'a>(obj: &'a Value, key: &str) -> Result<&'a str> {
    obj[key]
        .as_str()
        .ok_or_else(|| format!("expected string {key}").into())
}
struct Worker {
    name: String,
    child: Child,
    input: ChildStdin,
    replies: Receiver<std::io::Result<String>>,
    ready: Value,
    ready_ns: u64,
    publication: Option<String>,
}
impl Worker {
    fn start(cfg: &Value) -> Result<Self> {
        let name = string(cfg, "name")?.to_owned();
        let cmd: Vec<&str> = cfg["command"]
            .as_array()
            .ok_or("expected command")?
            .iter()
            .map(|v| v.as_str().ok_or("expected argument"))
            .collect::<std::result::Result<_, _>>()?;
        let (exe, args) = cmd.split_first().ok_or("empty command")?;
        let start = Instant::now();
        let mut child = Command::new(exe)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()?;
        let input = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (send, replies) = mpsc::channel();
        thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                if send.send(line).is_err() {
                    break;
                }
            }
        });
        let mut worker = Self {
            name,
            child,
            input,
            replies,
            ready: Value::Null,
            ready_ns: 0,
            publication: cfg["publication"].as_str().map(str::to_owned),
        };
        worker.ready = worker.receive()?;
        worker.ready_ns = start.elapsed().as_nanos() as u64;
        Ok(worker)
    }
    fn receive(&mut self) -> Result<Value> {
        let line = self
            .replies
            .recv_timeout(Duration::from_secs(180))
            .map_err(|e| format!("{} worker reply: {e}", self.name))??;
        Ok(serde_json::from_str(&line)?)
    }
    fn run(&mut self, input: &Path, output: &Path) -> Result<(u64, Value)> {
        for path in [input, output] {
            if path
                .to_str()
                .ok_or("expected UTF-8 path")?
                .contains(['\t', '\r', '\n'])
            {
                return Err("path conflicts with framing".into());
            }
        }
        let start = Instant::now();
        if let Some(profile) = &self.publication {
            serde_json::to_writer(
                &mut self.input,
                &json!({"schema":1,"witness":input,"output":output,"publication":profile}),
            )?;
            writeln!(self.input)?;
        } else {
            writeln!(self.input, "{}\t{}", input.display(), output.display())?;
        }
        self.input.flush()?;
        let result = self.receive()?;
        let elapsed = start.elapsed().as_nanos() as u64;
        if self.publication.is_some() && result["status"] != "ok" {
            return Err(format!("worker refused benchmark job: {result}").into());
        }
        Ok((elapsed, result))
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        // Each child here belongs only to this harness.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn contents(path: &Path) -> Result<BTreeMap<String, String>> {
    let mut zip = zip::ZipArchive::new(File::open(path)?)?;
    if zip.len() != 5 {
        return Err("expected five PIE members".into());
    }
    let mut output = BTreeMap::new();
    for name in [
        "version.json",
        "metadata.json",
        "additional_data.json",
        "execution_resources.json",
        "memory.bin",
    ] {
        let mut member = zip.by_name(name)?;
        let digest = if name == "memory.bin" {
            let mut sha = Sha256::new();
            std::io::copy(&mut member, &mut sha)?;
            format!("{:x}", sha.finalize())
        } else {
            let mut bytes = Vec::new();
            member.read_to_end(&mut bytes)?;
            let value: Value = serde_json::from_slice(&bytes)?;
            // Value sorts object keys and arbitrary_precision retains numeric tokens.
            hash(&serde_json::to_vec(&value)?)
        };
        output.insert(name.to_owned(), digest);
    }
    Ok(output)
}
fn main() -> Result<()> {
    let args: Vec<PathBuf> = env::args_os().skip(1).map(PathBuf::from).collect();
    let [config, out] = args.as_slice() else {
        return Err("usage: oxcairo-warm-host-bench CONFIG FRESH_OUTPUT_DIR".into());
    };
    fs::create_dir(out)?;
    let out = out.canonicalize()?;
    let cfg: Value = serde_json::from_reader(File::open(config)?)?;
    let rounds = cfg["rounds"].as_u64().ok_or("missing rounds")? as usize;
    let arms = cfg["arms"].as_array().ok_or("missing arms")?;
    let cases = cfg["cases"].as_array().ok_or("missing cases")?;
    if rounds == 0 || arms.len() < 2 || cases.is_empty() {
        return Err("expected rounds, at least two arms, and cases".into());
    }
    let mut rows = File::create(out.join("rows.jsonl"))?;
    let mut expected = BTreeMap::new();
    for (index, case) in cases.iter().enumerate() {
        expected.insert(index, contents(Path::new(string(case, "oracle")?))?);
    }
    for round in 0..rounds {
        for i in 0..cases.len() {
            let base = (i + round) % cases.len();
            let mut workers = Vec::new();
            for j in 0..arms.len() {
                workers.push(Worker::start(&arms[(j + i + round) % arms.len()])?);
            }
            let next = (base + 1) % cases.len();
            for (request, index) in [base, base, next, base].into_iter().enumerate() {
                let case = string(&cases[index], "name")?;
                let input = Path::new(string(&cases[index], "input")?);
                for j in 0..workers.len() {
                    let slot = (j + request) % workers.len();
                    let worker = &mut workers[slot];
                    let path = out.join("current.zip");
                    let (wall_ns, stages) = worker.run(input, &path)?;
                    let members = contents(&path)?;
                    let want = &expected[&index];
                    if *want != members {
                        return Err(format!("PIE differs for {case} in {}, round {round} request {request}: {members:?} vs {want:?}",worker.name).into());
                    }
                    let mut digest = Sha256::new();
                    let size = std::io::copy(&mut File::open(&path)?, &mut digest)?;
                    let archive = format!("{:x}", digest.finalize());
                    if worker.publication.is_some()
                        && (stages["sha256"] != archive || stages["bytes"] != size)
                    {
                        return Err(format!(
                            "{} returned an incorrect archive receipt",
                            worker.name
                        )
                        .into());
                    }
                    writeln!(
                        rows,
                        "{}",
                        json!({"round":round,"base":string(&cases[base],"name")?,"case":case,
                        "ordinal":request+1,"engine":worker.name,"ready_ns":worker.ready_ns,"ready":worker.ready,
                        "wall_ns":wall_ns,"stages":stages,"bytes":size,"archive_sha256":archive,"members":members})
                    )?;
                    rows.flush()?;
                    fs::remove_file(path)?;
                }
            }
        }
    }
    Ok(())
}
