// Independent oracle for malformed historical OS inputs. Build under the pinned sequencer.
use starknet_os::errors::StarknetOsError;
use starknet_os::io::os_input::OsHints;
use starknet_os::runner::{run_os_stateless, DEFAULT_OS_LAYOUT};
use std::{env, fs::File, io::BufReader, process::ExitCode};

fn main() -> ExitCode {
    let Some(path) = env::args_os().nth(1) else { return ExitCode::from(2) };
    let Ok(file) = File::open(path) else { return ExitCode::from(2) };
    let Ok(hints) = serde_json::from_reader::<_, OsHints>(BufReader::new(file)) else {
        return ExitCode::from(2);
    };
    match run_os_stateless(DEFAULT_OS_LAYOUT, hints) {
        Ok(_) => ExitCode::SUCCESS,
        Err(StarknetOsError::VmException(error)) => {
            println!("vm_exception {}:{}", error.pc.segment_index, error.pc.offset);
            ExitCode::from(5)
        }
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(70)
        }
    }
}
