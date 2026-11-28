// Append to starknet_os_flow_tests/src/tests.rs in the pinned sequencer.
#[tokio::test]
async fn test_oxcairo_mixed_reverts() {
    let rounds: u64 = std::env::var("OXCAIRO_ROUNDS").unwrap().parse().unwrap();
    let (mut builder, [legacy, modern]) = TestBuilder::create_standard_with_config(
        [
            (
                FeatureContract::TestContract(CairoVersion::Cairo0),
                nontrivial_test_contract_constructor_calldata(),
            ),
            (
                FeatureContract::TestContract(CairoVersion::Cairo1(RunnableCairo1::Casm)),
                nontrivial_test_contract_constructor_calldata(),
            ),
        ],
        TestBuilderConfig {
            use_kzg_da: true,
            ..Default::default()
        },
    )
    .await;
    for i in 0..rounds {
        let key = Felt::from(45000 + i % 257);
        let value = starknet_types_core::hash::Poseidon::hash(&key, &Felt::from(i));
        let calldata = create_calldata(modern, "test_storage_read_write", &[key, value]);
        builder.add_funded_account_invoke(invoke_tx_args! { calldata });
        for (contract, reason) in [
            (legacy, "ASSERT_EQ instruction failed: 1 != 0"),
            (modern, "Panic for revert"),
        ] {
            let args = invoke_tx_args! {
                sender_address: *FUNDED_ACCOUNT_ADDRESS,
                nonce: builder.next_nonce(*FUNDED_ACCOUNT_ADDRESS),
                calldata: create_calldata(contract, "write_and_revert", &[key, value + Felt::ONE]),
                resource_bounds: *NON_TRIVIAL_RESOURCE_BOUNDS,
            };
            builder.add_invoke_tx_from_args(args, Some(reason.to_string()));
        }
    }
    builder.divide_transactions_into_n_blocks(4);
    builder.build_and_run().await.perform_default_validations();
}
