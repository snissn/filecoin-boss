#!/usr/bin/env bash
set -euo pipefail

require_env() {
  local name=$1
  if [[ -z ${!name:-} ]]; then
    echo "missing required environment variable: $name" >&2
    exit 1
  fi
}

for command in forge cast jq python3 git; do
  command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }
done

for name in \
  BOSS_NETWORK BOSS_CHAIN_ID BOSS_RPC_URL BOSS_DEPLOYER_PRIVATE_KEY BOSS_GOVERNANCE \
  BOSS_FILECOIN_PAY BOSS_FILECOIN_PAY_CODE_HASH \
  BOSS_PDP_VERIFIER BOSS_PDP_VERIFIER_CODE_HASH \
  BOSS_FWSS_SERVICE BOSS_FWSS_SERVICE_CODE_HASH \
  BOSS_FWSS_STATE_VIEW BOSS_FWSS_STATE_VIEW_CODE_HASH \
  BOSS_TOKEN BOSS_TOKEN_CODE_HASH \
  BOSS_PROTOCOL_COMMIT BOSS_DEPLOYMENT_COMMIT BOSS_MANIFEST_OUTPUT; do
  require_env "$name"
done

[[ $BOSS_PROTOCOL_COMMIT =~ ^[0-9a-f]{40}$ ]] || { echo "invalid BOSS_PROTOCOL_COMMIT" >&2; exit 1; }
[[ $BOSS_DEPLOYMENT_COMMIT =~ ^[0-9a-f]{40}$ ]] || { echo "invalid BOSS_DEPLOYMENT_COMMIT" >&2; exit 1; }
git cat-file -e "${BOSS_DEPLOYMENT_COMMIT}^{commit}"
if [[ $(git rev-parse HEAD) != "$BOSS_DEPLOYMENT_COMMIT" ]]; then
  echo "public-network deployment requires HEAD to equal BOSS_DEPLOYMENT_COMMIT" >&2
  exit 1
fi

observed_chain_id=$(cast chain-id --rpc-url "$BOSS_RPC_URL")
if [[ $observed_chain_id != "$BOSS_CHAIN_ID" ]]; then
  echo "RPC chain mismatch: expected $BOSS_CHAIN_ID, observed $observed_chain_id" >&2
  exit 1
fi

verify_dependency() {
  local label=$1 address=$2 expected=$3 code observed
  [[ $address =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "$label address is malformed" >&2; exit 1; }
  [[ $expected =~ ^0x[0-9a-fA-F]{64}$ ]] || { echo "$label code hash is malformed" >&2; exit 1; }
  code=$(cast code "$address" --rpc-url "$BOSS_RPC_URL")
  [[ $code != 0x && -n $code ]] || { echo "$label has no runtime code at $address" >&2; exit 1; }
  observed=$(cast keccak "$code")
  if [[ ${observed,,} != ${expected,,} ]]; then
    echo "$label runtime hash mismatch: expected $expected, observed $observed" >&2
    exit 1
  fi
}

verify_dependency FilecoinPay "$BOSS_FILECOIN_PAY" "$BOSS_FILECOIN_PAY_CODE_HASH"
verify_dependency PDPVerifier "$BOSS_PDP_VERIFIER" "$BOSS_PDP_VERIFIER_CODE_HASH"
verify_dependency FWSSService "$BOSS_FWSS_SERVICE" "$BOSS_FWSS_SERVICE_CODE_HASH"
verify_dependency FWSSStateView "$BOSS_FWSS_STATE_VIEW" "$BOSS_FWSS_STATE_VIEW_CODE_HASH"
verify_dependency Token "$BOSS_TOKEN" "$BOSS_TOKEN_CODE_HASH"

if [[ -e $BOSS_MANIFEST_OUTPUT && ${BOSS_REPLACE_MANIFEST:-false} != true ]]; then
  echo "manifest already exists at $BOSS_MANIFEST_OUTPUT; set BOSS_REPLACE_MANIFEST=true to replace it" >&2
  exit 1
fi

export BOSS_SUITE_OUTPUT=deployments/.local-suite.json
rm -f "$BOSS_SUITE_OUTPUT"
rm -rf "broadcast/Deploy.s.sol/$BOSS_CHAIN_ID"
forge script script/Deploy.s.sol:Deploy --rpc-url "$BOSS_RPC_URL" --broadcast -vvv

broadcast="broadcast/Deploy.s.sol/$BOSS_CHAIN_ID/run-latest.json"
test -s "$broadcast"
test -s "$BOSS_SUITE_OUTPUT"
python3 scripts/finalize-deployment-manifest.py \
  --suite "$BOSS_SUITE_OUTPUT" \
  --broadcast "$broadcast" \
  --rpc-url "$BOSS_RPC_URL" \
  --network "$BOSS_NETWORK" \
  --protocol-commit "$BOSS_PROTOCOL_COMMIT" \
  --deployment-commit "$BOSS_DEPLOYMENT_COMMIT" \
  --output "$BOSS_MANIFEST_OUTPUT"
python3 scripts/validate-deployment-manifest.py "$BOSS_MANIFEST_OUTPUT" \
  --rpc-url "$BOSS_RPC_URL" \
  --expected-network "$BOSS_NETWORK" \
  --expected-deployment-commit "$BOSS_DEPLOYMENT_COMMIT"
rm -f "$BOSS_SUITE_OUTPUT"
