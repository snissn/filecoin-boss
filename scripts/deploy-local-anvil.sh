#!/usr/bin/env bash
set -euo pipefail

for command in anvil forge cast jq python3 git; do
  command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }
done

export BOSS_NETWORK=${BOSS_NETWORK:-devnet}
export BOSS_CHAIN_ID=${BOSS_CHAIN_ID:-31337}
export BOSS_ANVIL_PORT=${BOSS_ANVIL_PORT:-8545}
export BOSS_RPC_URL=${BOSS_RPC_URL:-http://127.0.0.1:$BOSS_ANVIL_PORT}
export BOSS_DEPLOYER_PRIVATE_KEY=${BOSS_DEPLOYER_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
export BOSS_DEPLOYMENT_COMMIT=${BOSS_DEPLOYMENT_COMMIT:-$(git rev-parse HEAD)}
export BOSS_PROTOCOL_COMMIT=${BOSS_PROTOCOL_COMMIT:-$(jq -er '.sourceCommit' packages/contracts/artifacts.json)}
export BOSS_MANIFEST_OUTPUT=${BOSS_MANIFEST_OUTPUT:-deployments/devnet.json}
export BOSS_SUITE_OUTPUT=deployments/.local-suite.json

[[ $BOSS_DEPLOYMENT_COMMIT =~ ^[0-9a-f]{40}$ ]] || { echo "invalid BOSS_DEPLOYMENT_COMMIT" >&2; exit 1; }
git cat-file -e "${BOSS_DEPLOYMENT_COMMIT}^{commit}"
git merge-base --is-ancestor "$BOSS_DEPLOYMENT_COMMIT" HEAD
unexpected=$(git diff --name-only "$BOSS_DEPLOYMENT_COMMIT" HEAD | grep -Ev '^(deployments/devnet.json|\.github/workflows/a9-r1-bootstrap.yml)$' || true)
if [[ -n $unexpected ]]; then
  echo "build inputs differ from deployment commit $BOSS_DEPLOYMENT_COMMIT:" >&2
  printf '%s\n' "$unexpected" >&2
  exit 1
fi

log_file=$(mktemp)
generated_output=$BOSS_MANIFEST_OUTPUT
if [[ ${BOSS_CHECK_MANIFEST:-false} == true ]]; then
  generated_output=deployments/.local-manifest.json
fi

cleanup() {
  local status=$?
  if [[ -n ${anvil_pid:-} ]]; then
    kill "$anvil_pid" 2>/dev/null || true
    wait "$anvil_pid" 2>/dev/null || true
  fi
  rm -f "$log_file" "$BOSS_SUITE_OUTPUT" deployments/.local-manifest.json
  exit "$status"
}
trap cleanup EXIT INT TERM

anvil --silent --host 127.0.0.1 --port "$BOSS_ANVIL_PORT" --chain-id "$BOSS_CHAIN_ID" >"$log_file" 2>&1 &
anvil_pid=$!
for _ in $(seq 1 100); do
  if cast chain-id --rpc-url "$BOSS_RPC_URL" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if [[ $(cast chain-id --rpc-url "$BOSS_RPC_URL") != "$BOSS_CHAIN_ID" ]]; then
  echo "local Anvil chain ID mismatch" >&2
  cat "$log_file" >&2
  exit 1
fi

rm -f "$BOSS_SUITE_OUTPUT" "$generated_output"
rm -rf "broadcast/DeployLocal.s.sol/$BOSS_CHAIN_ID"
forge script script/DeployLocal.s.sol:DeployLocal --rpc-url "$BOSS_RPC_URL" --broadcast --slow -vvv
broadcast="broadcast/DeployLocal.s.sol/$BOSS_CHAIN_ID/run-latest.json"
test -s "$broadcast"
test -s "$BOSS_SUITE_OUTPUT"

python3 scripts/finalize-deployment-manifest.py \
  --suite "$BOSS_SUITE_OUTPUT" \
  --broadcast "$broadcast" \
  --rpc-url "$BOSS_RPC_URL" \
  --network "$BOSS_NETWORK" \
  --protocol-commit "$BOSS_PROTOCOL_COMMIT" \
  --deployment-commit "$BOSS_DEPLOYMENT_COMMIT" \
  --output "$generated_output"
python3 scripts/validate-deployment-manifest.py "$generated_output" \
  --rpc-url "$BOSS_RPC_URL" \
  --expected-network "$BOSS_NETWORK" \
  --expected-deployment-commit "$BOSS_DEPLOYMENT_COMMIT"

if [[ ${BOSS_CHECK_MANIFEST:-false} == true ]]; then
  test -s "$BOSS_MANIFEST_OUTPUT"
  cmp --silent "$generated_output" "$BOSS_MANIFEST_OUTPUT" || {
    echo "generated local manifest differs from $BOSS_MANIFEST_OUTPUT" >&2
    diff -u "$BOSS_MANIFEST_OUTPUT" "$generated_output" >&2 || true
    exit 1
  }
fi
