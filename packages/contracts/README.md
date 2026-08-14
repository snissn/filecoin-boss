# Filecoin Boss contract artifacts

This directory is generated from the exact Foundry source tree by:

```sh
scripts/generate-contract-artifacts.sh
```

It contains sorted contract ABIs, the exact `BossAccount` creation bytecode callers must supply to `BossFactory`, and its authenticated creation-code hash. Do not hand-edit generated files.

CI regenerates the artifact set on every relevant pull request and rejects any byte-level drift in `packages/contracts`.

Deployment addresses are intentionally separate under `deployments/`. The schema is fixed here; issue #11 owns real devnet and Calibration manifests.
