use starknet_os::hint_processor::aggregator_hint_processor::AggregatorInput;
use starknet_os::runner::{run_aggregator, DEFAULT_OS_LAYOUT};
use std::{fs::File, io::BufReader, path::Path};
fn main() {
    let mut args = std::env::args().skip(1);
    let input: AggregatorInput =
        serde_json::from_reader(BufReader::new(File::open(args.next().unwrap()).unwrap())).unwrap();
    let result = run_aggregator(DEFAULT_OS_LAYOUT, input).unwrap();
    if let Some(path) = args.next() {
        result
            .cairo_pie
            .write_zip_file(Path::new(&path), false)
            .unwrap();
    }
    for word in result.aggregator_output {
        println!("{word:#x}");
    }
}
