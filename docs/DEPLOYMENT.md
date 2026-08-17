# Filecoin Boss deployment

This repository keeps three authorities separate:

1. **deterministic local qualification** — a fresh Anvil chain with the locked Filecoin Pay V1 contract and explicit PDP/FWSS/token test doubles;
2. **environment deployment** — a caller-supplied devnet or Calibration tuple whose chain, addresses, and runtime code hashes are checked before any broadcast;
3. **receipt-backed manifest verification** — a generated manifest tied to one protocol artifact commit and one deployment-source commit, with successful receipts, runtime hashes, topology checks, and a smoke Boss account.

A local manifest proves reproducibility of the repository-owned deployment procedure. It is not Calibration evidence.

## Locked prerequisites

Use:

- Foundry `v1.3.5`;
- Solidity `0.8.30`;
- recursive submodule `lib/filecoin-pay` at `04ded6af6c15c4b5d98545f393dc656004d4aede`;
- Python 3 and `jq`.

Run the ordinary contract gates first:

```sh
forge fmt --check
forge build --sizes
forge test -vvv
```

## Deterministic local deployment

The local wrapper starts a fresh Anvil process and uses only Anvil's published first test key. `DeployLocal.s.sol` deploys the real locked `FilecoinPayV1` plus local-only PDP, FWSS, state-view, and token markers. It then deploys the complete Boss suite, registers the exact adapters, transfers adapter governance when requested, creates one bounded smoke account, and verifies the resulting topology.

Generate a local manifest from the current source commit:

```sh
BOSS_DEPLOYMENT_COMMIT="$(git rev-parse HEAD)" \
BOSS_MANIFEST_OUTPUT=deployments/devnet.json \
  scripts/deploy-local-anvil.sh
```

Reproduce the committed manifest byte-for-byte:

```sh
BOSS_DEPLOYMENT_COMMIT="$(jq -r .deploymentCommit deployments/devnet.json)" \
BOSS_MANIFEST_OUTPUT=deployments/devnet.json \
BOSS_CHECK_MANIFEST=true \
  scripts/deploy-local-anvil.sh
```

The committed `deployments/devnet.json` is a generated artifact. Its `deploymentCommit` identifies the source commit used to build and deploy; the artifact is recorded in a dedicated follow-up commit.

## Existing devnet or Calibration deployment

The network wrapper never discovers, guesses, or copies a dependency. Every dependency address and expected runtime hash is mandatory.

```sh
export BOSS_CHAIN_ID=<independently-verified-chain-id>
export BOSS_RPC_URL=<authorized-rpc-url>
export BOSS_DEPLOYER_PRIVATE_KEY=<protected-signing-input>
export BOSS_GOVERNANCE=<governance-address>
export BOSS_SMOKE_OWNER=<smoke-account-owner>

export BOSS_FILECOIN_PAY=<address>
export BOSS_FILECOIN_PAY_CODE_HASH=<bytes32>
export BOSS_PDP_VERIFIER=<address>
export BOSS_PDP_VERIFIER_CODE_HASH=<bytes32>
export BOSS_FWSS_SERVICE=<address>
export BOSS_FWSS_SERVICE_CODE_HASH=<bytes32>
export BOSS_FWSS_STATE_VIEW=<address>
export BOSS_FWSS_STATE_VIEW_CODE_HASH=<bytes32>
export BOSS_TOKEN=<address>
export BOSS_TOKEN_CODE_HASH=<bytes32>

export BOSS_PROTOCOL_COMMIT="$(jq -r .sourceCommit packages/contracts/artifacts.json)"
export BOSS_DEPLOYMENT_COMMIT="$(git rev-parse HEAD)"
export BOSS_MANIFEST_OUTPUT=deployments/calibration.json

scripts/deploy-calibration.sh
```

For another controlled devnet, set `BOSS_NETWORK`, `BOSS_CHAIN_ID`, `BOSS_RPC_URL`, and `BOSS_MANIFEST_OUTPUT`, then run `scripts/deploy-devnet.sh` or `scripts/deploy-network.sh`.

The wrapper fails before broadcast when:

- `HEAD` is not the declared deployment commit;
- the RPC chain ID differs from `BOSS_CHAIN_ID`;
- any required address or expected runtime hash is missing or malformed;
- any dependency has no code or its live hash differs;
- the FWSS state view is not bound to the configured FWSS service;
- a manifest already exists and replacement was not explicitly authorized.

## Manifest authority

`finalize-deployment-manifest.py` consumes the flat suite summary emitted by the Foundry script, the exact `run-latest.json`, and live RPC state. It records:

- network and chain ID;
- exact protocol and deployment-source commits;
- deployer and final adapter-governance addresses;
- every dependency address and runtime code hash;
- every Boss contract address, successful transaction hash, deployment block, and runtime code hash;
- the canonical Boss account creation-code hash;
- one smoke account with owner, successful transaction, block, and runtime code hash.

Static validation:

```sh
python3 scripts/validate-deployment-manifest.py deployments/devnet.json
```

Live receipt, runtime, and topology validation:

```sh
python3 scripts/validate-deployment-manifest.py deployments/devnet.json \
  --rpc-url "$BOSS_RPC_URL"
```

Live validation checks receipt success and block identity, every runtime hash, adapter governance, factory/bundles linkage, resource-adapter dependencies, and all smoke-account authority fields.

## Security boundary

Never commit private keys, RPC credentials, provisional addresses, edited manifests, copied receipts, or synthetic network output. `deployments/calibration.json` is publishable only after an owner-authorized broadcast and independent receipt/runtime/configuration verification. Mainnet deployment, key-management automation, proxy administration, multisig automation, and hosted deployment services remain outside this gate.
