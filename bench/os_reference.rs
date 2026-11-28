use starknet_os::io::os_input::OsHints;
use starknet_os::runner::{run_os_stateless, DEFAULT_OS_LAYOUT};
use std::fs::File;
use std::io::{self, BufRead, Write};

fn main() {
    let mut args = std::env::args().skip(1);
    let first = args.next().expect("block input or --worker");
    if first == "--worker" {
        let path = args.next().expect("block input");
        println!("READY");
        io::stdout().flush().unwrap();
        for line in io::stdin().lock().lines() {
            assert_eq!(line.unwrap(), "RUN");
            run(&path, None, false);
            println!("DONE");
            io::stdout().flush().unwrap();
        }
    } else {
        let archive = args.next();
        let merge = args.next().as_deref() == Some("--merge-extra-segments");
        run(&first, archive.as_deref(), merge);
    }
}

fn run(path: &str, archive: Option<&str>, merge: bool) {
    let input = std::io::BufReader::new(File::open(path).unwrap());
    let hints: OsHints = serde_json::from_reader(input).unwrap();
    let result = run_os_stateless(DEFAULT_OS_LAYOUT, hints).unwrap();
    if let Some(path) = archive {
        result
            .cairo_pie
            .write_zip_file(std::path::Path::new(path), merge)
            .unwrap();
    }
    for value in result.raw_os_output {
        println!("{value:#x}");
    }
}
