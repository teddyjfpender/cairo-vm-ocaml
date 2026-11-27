use starknet_os::{io::os_input::OsHints, runner::run_virtual_os};
use std::{fs::File, io::BufReader, path::Path};
fn main() {
    let mut args = std::env::args().skip(1);
    let input: OsHints =
        serde_json::from_reader(BufReader::new(File::open(args.next().unwrap()).unwrap())).unwrap();
    let result = run_virtual_os(input).unwrap();
    if let Some(path) = args.next() {
        result
            .cairo_pie
            .write_zip_file(Path::new(&path), false)
            .unwrap();
    }
    for w in result.raw_output {
        println!("{w:#x}");
    }
}
