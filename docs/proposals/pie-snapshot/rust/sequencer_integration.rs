// Integration fragment for starknet_transaction_prover/src/proving/prover.rs
// under its existing stwo_proving feature. Takes an already serialized PIE.
// Keep the existing imports, prove(), and its unsupported-builtin gate.
pub(crate) async fn prove_zip_with_oxcairo(
    input: Vec<u8>,
    precomputes: Arc<RecursiveProverPrecomputes>,
) -> Result<ProverOutput, ProvingError> {
    use oxcairo_pie::{run, Artifact::Pie, Layout, Limits};
    let pie = spawn_blocking_in_current_span(move || {
        let snapshot = run(&input, Layout::AllCairo, &[Pie], Limits::default())
            .map_err(|e| ProvingError::ProverExecution(e.to_string()))?;
        let bytes = snapshot.get(Pie)
            .map_err(|e| ProvingError::ProverExecution(e.to_string()))?;
        CairoPie::from_bytes(bytes).map_err(|e| ProvingError::ProverExecution(e.to_string()))
    }).await.map_err(ProvingError::TaskJoin)??;
    prove(pie, precomputes).await
}
