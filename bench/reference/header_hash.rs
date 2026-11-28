use starknet_api::{
    block_hash::block_hash_calculator::{calculate_block_hash, PartialBlockHashComponents},
    hash::StateRoots,
};
use starknet_os::io::os_input::OsHints;
use std::{error::Error, fs::File, io::BufReader};
fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args().collect();
    let input: OsHints = serde_json::from_reader(BufReader::new(File::open(&args[2])?))?;
    for b in input.os_input.os_block_inputs {
        let state = &b.contract_state_commitment_info;
        let class = &b.contract_class_commitment_info;
        let roots = if args[1] == "virtual_os" {
            StateRoots {
                contracts_trie_root_hash: state.previous_root,
                classes_trie_root_hash: class.previous_root,
            }
        } else {
            StateRoots {
                contracts_trie_root_hash: state.updated_root,
                classes_trie_root_hash: class.updated_root,
            }
        };
        let hash = calculate_block_hash(
            &PartialBlockHashComponents::new(&b.block_info, b.block_hash_commitments),
            roots.global_root(),
            b.prev_block_hash,
        )?;
        println!("{:#x}", hash.0);
    }
    Ok(())
}
