# Filecoin Boss contract artifacts

This directory is generated from the exact Foundry source tree by:

```sh
SOURCE_COMMIT=$(git rev-parse HEAD) scripts/generate-contract-artifacts.sh
```

It contains sorted contract ABIs, the exact `BossAccount` creation bytecode callers must supply to `BossFactory`, and its authenticated creation-code hash. Do not hand-edit generated files.

`artifacts.json` records the exact source/protocol commit and complete compiler configuration. Artifact publication uses two commits: first commit the source, then generate and commit artifacts with `SOURCE_COMMIT` set to that source commit. This avoids a self-referential commit hash while preserving exact provenance.

The locked build is Solidity `0.8.30`, Prague EVM, optimizer enabled with one run, IR compilation enabled, and CBOR/bytecode metadata hashes disabled. CI verifies that no build input changed after the recorded source commit, regenerates with the recorded commit, stages the complete generated directory, and rejects added, removed, or modified files.

Deployment addresses are intentionally separate under `deployments/`. The schema is fixed here; issue #11 owns real devnet and Calibration manifests.
