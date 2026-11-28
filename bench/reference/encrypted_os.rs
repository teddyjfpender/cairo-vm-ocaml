use starknet_os::io::os_input::OsHints;
use starknet_os::io::os_output::{OsOutput, OsStateDiff};
use starknet_os::io::os_output_types::{FullOsStateDiff, PartialOsStateDiff, TryFromOutputIter};
use starknet_os::io::test_utils::validate_kzg_segment;
use starknet_os::runner::{run_os_stateless, DEFAULT_OS_LAYOUT};
use starknet_types_core::felt::Felt;
use std::{
    env,
    fs::File,
    io::{BufRead, BufReader},
};

fn words(path: &str) -> Vec<Felt> {
    BufReader::new(File::open(path).unwrap())
        .lines()
        .map(Result::unwrap)
        .filter(|line| line.starts_with("0x"))
        .map(|line| Felt::from_hex(&line).unwrap())
        .collect()
}
fn main() {
    let args: Vec<String> = env::args().collect();
    let keys = args[1]
        .split(',')
        .map(|k| Felt::from_dec_str(k).unwrap())
        .collect::<Vec<_>>();
    let (raw, da) = if args[2] == "run" {
        let hints: OsHints =
            serde_json::from_reader(BufReader::new(File::open(&args[3]).unwrap())).unwrap();
        let r = run_os_stateless(DEFAULT_OS_LAYOUT, hints).unwrap();
        (r.raw_os_output, r.da_segment.unwrap_or_default())
    } else {
        (words(&args[3]), words(&args[4]))
    };
    let mut iter = raw.into_iter();
    let out = OsOutput::try_from_output_iter(&mut iter, Some(&keys)).unwrap();
    assert!(iter.next().is_none());
    let diff = match out.state_diff {
        OsStateDiff::Full(d) => serde_json::to_value(d).unwrap(),
        OsStateDiff::Partial(d) => serde_json::to_value(d).unwrap(),
        OsStateDiff::PartialCommitment(c) => {
            validate_kzg_segment(&da, &c.0);
            serde_json::to_value(
                PartialOsStateDiff::try_from_output_iter(&mut da.into_iter(), Some(&keys)).unwrap(),
            )
            .unwrap()
        }
        OsStateDiff::FullCommitment(_) => {
            panic!("unexpected full commitment in encrypted fixtures")
        }
    };
    println!("{}", serde_json::json!([out.common_os_output, diff]));
}
