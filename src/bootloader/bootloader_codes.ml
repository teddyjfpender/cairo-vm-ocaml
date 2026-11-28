(* Exact hint strings in cairo-program-runner-lib 1.3.1. *)

let check_address = {|# Sanity check.
assert ids.program_address == program_address|}

let enter_task = {|from starkware.cairo.bootloaders.simple_bootloader.objects import (
    CairoPieTask,
    RunProgramTask,
    Task,
)
from starkware.cairo.bootloaders.simple_bootloader.utils import (
    load_cairo_pie,
    prepare_output_runner,
)

assert isinstance(task, Task)
n_builtins = len(task.get_program().builtins)
new_task_locals = {}
if isinstance(task, RunProgramTask):
    new_task_locals['program_input'] = task.program_input
    new_task_locals['WITH_BOOTLOADER'] = True

    vm_load_program(task.program, program_address)
elif isinstance(task, CairoPieTask):
    ret_pc = ids.ret_pc_label.instruction_offset_ - ids.call_task.instruction_offset_ + pc
    load_cairo_pie(
        task=task.cairo_pie, memory=memory, segments=segments,
        program_address=program_address, execution_segment_address= ap - n_builtins,
        builtin_runners=builtin_runners, ret_fp=fp, ret_pc=ret_pc,
        ecdsa_additional_data=vm_ecdsa_additional_data)
else:
    raise NotImplementedError(f'Unexpected task type: {type(task).__name__}.')

output_runner_data = prepare_output_runner(
    task=task,
    output_builtin=output_builtin,
    output_ptr=ids.pre_execution_builtin_ptrs.output)
vm_enter_scope(new_task_locals)|}

let exit_task = {|vm_exit_scope()
# Note that bootloader_input will only be available in the next hint.|}

let return_builtins = {|from starkware.cairo.bootloaders.simple_bootloader.utils import write_return_builtins

# Fill the values of all builtin pointers after executing the task.
builtins = task.get_program().builtins
write_return_builtins(
    memory=memory, return_builtins_addr=ids.return_builtin_ptrs.address_,
    used_builtins=builtins, used_builtins_addr=ids.used_builtins_addr,
    pre_execution_builtins_addr=ids.pre_execution_builtin_ptrs.address_, task=task)

vm_enter_scope({'n_selected_builtins': n_builtins})|}

let append_topology = {|from starkware.cairo.bootloaders.simple_bootloader.utils import get_task_fact_topology

# Add the fact topology of the current task to 'fact_topologies'.
output_start = ids.pre_execution_builtin_ptrs.output
output_end = ids.return_builtin_ptrs.output
fact_topologies.append(get_task_fact_topology(
    output_size=output_end - output_start,
    task=task,
    output_builtin=output_builtin,
    output_runner_data=output_runner_data,
))|}

let simulate_ec = {|from starkware.cairo.lang.builtins.ec.ec_op_builtin_runner import (
    ec_op_auto_deduction_rule_wrapper,
)
ids.new_ec_op_ptr = segments.add()
vm_add_auto_deduction_rule(
    segment_index=ids.new_ec_op_ptr.segment_index,
    rule=ec_op_auto_deduction_rule_wrapper(ec_op_cache={}),
)|}

let simulate_keccak = {|from starkware.cairo.common.keccak_utils.keccak_utils import keccak_func
from starkware.cairo.lang.builtins.keccak.keccak_builtin_runner import (
    keccak_auto_deduction_rule_wrapper,
)
ids.new_keccak_ptr = segments.add()
vm_add_auto_deduction_rule(
    segment_index=ids.new_keccak_ptr.segment_index,
    rule=keccak_auto_deduction_rule_wrapper(keccak_cache={}),
)|}

let simulate_ecdsa = {|from starkware.cairo.lang.builtins.signature.signature_builtin_runner import (
    signature_rule_wrapper,
)
from starkware.cairo.lang.vm.cairo_runner import verify_ecdsa_sig
ids.new_ecdsa_ptr = segments.add()
vm_add_validation_rule(
    segment_index=ids.new_ecdsa_ptr.segment_index,
    rule=signature_rule_wrapper(
        verify_signature_func=verify_ecdsa_sig,
        # Store signatures inside the vm's state. vm_ecdsa_additional_data is dropped
        # into the execution scope by the vm.
        signature_cache=vm_ecdsa_additional_data,
        ),
)|}

let read_input = {|from starkware.cairo.bootloaders.simple_bootloader.objects import SimpleBootloaderInput
simple_bootloader_input = SimpleBootloaderInput.Schema().load(program_input)|}

let finish = {|# Dump fact topologies to a json file.
from starkware.cairo.bootloaders.simple_bootloader.utils import (
    configure_fact_topologies,
    write_to_fact_topologies_file,
)

# The task-related output is prefixed by a single word that contains the number of tasks.
tasks_output_start = output_builtin.base + 1

if not simple_bootloader_input.single_page:
    # Configure the memory pages in the output builtin, based on fact_topologies.
    configure_fact_topologies(
        fact_topologies=fact_topologies, output_start=tasks_output_start,
        output_builtin=output_builtin,
    )

if simple_bootloader_input.fact_topologies_path is not None:
    write_to_fact_topologies_file(
        fact_topologies_path=simple_bootloader_input.fact_topologies_path,
        fact_topologies=fact_topologies,
    )|}
