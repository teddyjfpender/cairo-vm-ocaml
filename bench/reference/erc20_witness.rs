// Append to starknet_os_flow_tests/src/tests.rs in the pinned sequencer.
#[tokio::test]
async fn test_oxcairo_erc20_transfers() {
    let n: u64 = std::env::var("OXCAIRO_TRANSFERS").unwrap().parse().unwrap();
    let recipients: u64 = std::env::var("OXCAIRO_RECIPIENTS")
        .unwrap()
        .parse()
        .unwrap();
    let (mut builder, []) = TestBuilder::create_standard_with_config(
        [],
        TestBuilderConfig {
            use_kzg_da: true,
            ..Default::default()
        },
    )
    .await;
    for i in 0..n {
        let address =
            ContractAddress::try_from(Felt::from(0x12340000_u64 + i % recipients)).unwrap();
        builder.add_fund_address_tx(address, 1_000_000 + u128::from(i));
    }
    builder.divide_transactions_into_n_blocks(4);
    builder.build_and_run().await.perform_default_validations();
}
