// Persistent drivers for the stock sequencer APIs. Each RUN parses the
// supplied witness and executes a fresh VM through the public runner.
use starknet_os::hint_processor::aggregator_hint_processor::AggregatorInput;
use starknet_os::io::os_input::OsHints;
use starknet_os::runner::{run_aggregator, run_virtual_os, DEFAULT_OS_LAYOUT};
use std::fs::File;
use std::io::{self, BufRead, BufReader, Write};

fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    assert!(args.len() == 3 && args[1] == "--worker");
    println!("READY");
    io::stdout().flush().unwrap();
    for line in io::stdin().lock().lines() {
        assert_eq!(line.unwrap(), "RUN");
        let source = BufReader::new(File::open(&args[2]).unwrap());
        let words = match args[0].as_str() {
            "--virtual-os" => {
                let input: OsHints = serde_json::from_reader(source).unwrap();
                run_virtual_os(input).unwrap().raw_output
            }
            "--aggregator" => {
                let input: AggregatorInput = serde_json::from_reader(source).unwrap();
                run_aggregator(DEFAULT_OS_LAYOUT, input).unwrap().aggregator_output
            }
            _ => panic!("expected --virtual-os or --aggregator"),
        };
        for word in words {
            println!("{word:#x}");
        }
        println!("DONE");
        io::stdout().flush().unwrap();
    }
}
