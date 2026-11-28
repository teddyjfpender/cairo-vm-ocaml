// Append to starknet_os_flow_tests/src/tests.rs at the pinned sequencer revision.
#[tokio::test]
async fn test_oxcairo_wide_deploy_and_l1() {
    let n: u64 = std::env::var("OXCAIRO_DEPLOYS").unwrap().parse().unwrap();
    let blob = std::env::var_os("OXCAIRO_BLOB").is_some();
    let (mut builder, _) = TestBuilder::create_standard_with_config(
        [],
        TestBuilderConfig {
            use_kzg_da: blob,
            full_output: false,
            ..Default::default()
        },
    )
    .await;
    let contract = FeatureContract::TestContract(CairoVersion::Cairo1(RunnableCairo1::Casm));
    let sierra = contract.get_sierra();
    let class_hash = sierra.calculate_class_hash();
    let tx = declare_tx(declare_tx_args! {
        sender_address: *FUNDED_ACCOUNT_ADDRESS,
        class_hash,
        compiled_class_hash: contract.get_compiled_class_hash(&HashVersion::V2),
        resource_bounds: *NON_TRIVIAL_RESOURCE_BOUNDS,
        nonce: builder.next_nonce(*FUNDED_ACCOUNT_ADDRESS),
    });
    builder.add_cairo1_declare_tx(
        DeclareTransaction::create(tx, contract.get_class_info(), &builder.chain_id()).unwrap(),
        &sierra,
    );
    for i in 0..n {
        let salt = ContractAddressSalt(Felt::from(71001 + i));
        let constructor = [Felt::from(i + 7), Felt::from(i + 90)];
        let call = [
            class_hash.0,
            salt.0,
            Felt::TWO,
            constructor[0],
            constructor[1],
            Felt::ZERO,
        ];
        let addr = calculate_contract_address(
            salt,
            class_hash,
            &Calldata(constructor.to_vec().into()),
            *FUNDED_ACCOUNT_ADDRESS,
        )
        .unwrap();
        let calldata = create_calldata(
            *FUNDED_ACCOUNT_ADDRESS,
            DEPLOY_CONTRACT_FUNCTION_ENTRY_POINT_NAME,
            &call,
        );
        builder.add_funded_account_invoke(invoke_tx_args! {calldata});
        let key = Felt::from(143 + i);
        let value = starknet_types_core::hash::Poseidon::hash(&key, &Felt::from(54321u64));
        let calldata = create_calldata(addr, "test_storage_read_write", &[key, value]);
        builder.add_funded_account_invoke(invoke_tx_args! {calldata});
        builder.add_l1_handler(
            addr,
            "l1_handler_set_value",
            calldata![Felt::THREE, Felt::from(3761 + i), value],
            None,
        );
    }
    builder.divide_transactions_into_n_blocks(4);
    builder.build_and_run().await.perform_default_validations();
}
