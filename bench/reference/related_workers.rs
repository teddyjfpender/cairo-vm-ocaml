// Cold and persistent entry points to the sequencer's two related OS runners.
// Every call reads the supplied witness and executes a fresh VM.
use starknet_os::hint_processor::aggregator_hint_processor::AggregatorInput;
use starknet_os::io::os_input::OsHints;
use starknet_os::runner::{run_aggregator, run_virtual_os, DEFAULT_OS_LAYOUT};
use std::fs::File;
use std::io::{self, BufRead, BufReader, Write};
use std::path::Path;

fn run(kind: &str, path: &str, archive: Option<&str>) {
    let source = BufReader::new(File::open(path).unwrap());
    let (words, pie) = match kind {
        "--virtual-os" => {
            let input: OsHints = serde_json::from_reader(source).unwrap();
            let result = run_virtual_os(input).unwrap();
            (result.raw_output, result.cairo_pie)
        }
        "--aggregator" => {
            let input: AggregatorInput = serde_json::from_reader(source).unwrap();
            let result = run_aggregator(DEFAULT_OS_LAYOUT, input).unwrap();
            (result.aggregator_output, result.cairo_pie)
        }
        _ => panic!("expected --virtual-os or --aggregator"),
    };
    if let Some(path) = archive {
        pie.write_zip_file(Path::new(path), false).unwrap();
    }
    for word in words {
        println!("{word:#x}");
    }
}

fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [kind, mode, input] if mode == "--worker" => {
            println!("READY");
            io::stdout().flush().unwrap();
            for line in io::stdin().lock().lines() {
                assert_eq!(line.unwrap(), "RUN");
                run(kind, input, None);
                println!("DONE");
                io::stdout().flush().unwrap();
            }
        }
        [kind, input] => run(kind, input, None),
        [kind, input, archive] => run(kind, input, Some(archive)),
        _ => panic!("expected KIND [--worker] INPUT or KIND INPUT ARCHIVE"),
    }
}
