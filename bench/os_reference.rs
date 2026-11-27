use std::fs::File;
use starknet_os::io::os_input::OsHints;
use starknet_os::runner::{run_os_stateless, DEFAULT_OS_LAYOUT};

fn main() {
    let mut args = std::env::args().skip(1);
    let input = std::io::BufReader::new(File::open(args.next().unwrap()).unwrap());
    let hints: OsHints = serde_json::from_reader(input).unwrap();
    let result = run_os_stateless(DEFAULT_OS_LAYOUT, hints).unwrap();
    if let Some(path) = args.next() {
        result.cairo_pie.write_zip_file(std::path::Path::new(&path), false).unwrap();
    }
    for value in result.raw_os_output { println!("{value:#x}"); }
}
