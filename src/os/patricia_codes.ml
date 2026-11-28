(* Exact hint strings from the sequencer Cairo 0 Patricia library. *)
let build = {|from starkware.cairo.common.patricia_utils import canonic, patricia_guess_descents
from starkware.python.merkle_tree import build_update_tree

# Build modifications list.
modifications = []
DictAccess_key = ids.DictAccess.key
DictAccess_new_value = ids.DictAccess.new_value
DictAccess_SIZE = ids.DictAccess.SIZE
for i in range(ids.n_updates):
    curr_update_ptr = ids.update_ptr.address_ + i * DictAccess_SIZE
    modifications.append((
        memory[curr_update_ptr + DictAccess_key],
        memory[curr_update_ptr + DictAccess_new_value]))

node = build_update_tree(ids.height, modifications)
descent_map = patricia_guess_descents(
    ids.height, node, preimage, ids.prev_root, ids.new_root)
del modifications
__patricia_skip_validation_runner = globals().get(
    '__patricia_skip_validation_runner')

common_args = dict(
    preimage=preimage, descent_map=descent_map,
    __patricia_skip_validation_runner=__patricia_skip_validation_runner)
common_args['common_args'] = common_args|}

let preimage_hashes = {|from starkware.python.merkle_tree import decode_node
left_child, right_child, case = decode_node(node)
left_hash, right_hash = preimage[ids.node]

# Fill non deterministic hashes.
hash_ptr = ids.current_hash.address_
memory[hash_ptr + ids.HashBuiltin.x] = left_hash
memory[hash_ptr + ids.HashBuiltin.y] = right_hash

if __patricia_skip_validation_runner:
    # Skip validation of the preimage dict to speed up the VM. When this flag is set,
    # mistakes in the preimage dict will be discovered only in the prover.
    __patricia_skip_validation_runner.verified_addresses.add(
        hash_ptr + ids.HashBuiltin.result)

memory[ap] = int(case != 'both')|}

let edge = {|ids.edge = segments.add()
ids.edge.length, ids.edge.path, ids.edge.bottom = preimage[ids.node]
ids.hash_ptr.result = ids.node - ids.edge.length
if __patricia_skip_validation_runner is not None:
    # Skip validation of the preimage dict to speed up the VM. When this flag is set,
    # mistakes in the preimage dict will be discovered only in the prover.
    __patricia_skip_validation_runner.verified_addresses.add(
        ids.hash_ptr + ids.HashBuiltin.result)|}

let bottom = {|ids.hash_ptr.x, ids.hash_ptr.y = preimage[ids.edge.bottom]
if __patricia_skip_validation_runner:
    # Skip validation of the preimage dict to speed up the VM. When this flag is
    # set, mistakes in the preimage dict will be discovered only in the prover.
    __patricia_skip_validation_runner.verified_addresses.add(
        ids.hash_ptr + ids.HashBuiltin.result)|}

let new_node = {|ids.child_bit = 0 if case == 'left' else 1
new_node = left_child if case == 'left' else right_child
vm_enter_scope(dict(node=new_node, **common_args))|}

let next_zero = {|new_node = left_child if ids.bit == 0 else right_child
vm_enter_scope(dict(node=new_node, **common_args))|}

let next_one = {|new_node = left_child if ids.bit == 1 else right_child
vm_enter_scope(dict(node=new_node, **common_args))|}

let descend = {|new_node = node
for i in range(ids.length - 1, -1, -1):
    new_node = new_node[(ids.word >> i) & 1]
vm_enter_scope(dict(node=new_node, **common_args))|}
