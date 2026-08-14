#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

forge build >/dev/null

ABI_DIR=packages/contracts/abi
BYTECODE_DIR=packages/contracts/bytecode
rm -rf "$ABI_DIR" "$BYTECODE_DIR"
mkdir -p "$ABI_DIR" "$BYTECODE_DIR"

contracts=(
  BossAccount
  BossFactory
  BossServiceRegistry
  BossAdapterRegistry
  BossBundles
  BossStateView
  FlatRateAdapter
  PDPCapacityAdapter
  CappedMeteredAdapter
  FWSSPDPResourceAdapter
)

for contract in "${contracts[@]}"; do
  artifact="out/${contract}.sol/${contract}.json"
  test -f "$artifact"
  tmp=$(mktemp)
  jq -S '.abi' "$artifact" > "$tmp"
  mv "$tmp" "$ABI_DIR/${contract}.json"
done

account_artifact=out/BossAccount.sol/BossAccount.json
creation_code=$(jq -r '.bytecode.object' "$account_artifact")
case "$creation_code" in
  0x??*) ;;
  *) echo "BossAccount creation bytecode is missing" >&2; exit 1 ;;
esac
printf '%s\n' "$creation_code" > "$BYTECODE_DIR/BossAccount.creation.hex"
creation_hash=$(cast keccak "$creation_code")

jq -S -n --arg creationHash "$creation_hash" '
{
  schemaVersion: 1,
  contracts: [
    {name: "BossAccount", abi: "abi/BossAccount.json", creationCode: "bytecode/BossAccount.creation.hex", creationCodeHash: $creationHash},
    {name: "BossFactory", abi: "abi/BossFactory.json"},
    {name: "BossServiceRegistry", abi: "abi/BossServiceRegistry.json"},
    {name: "BossAdapterRegistry", abi: "abi/BossAdapterRegistry.json"},
    {name: "BossBundles", abi: "abi/BossBundles.json"},
    {name: "BossStateView", abi: "abi/BossStateView.json"},
    {name: "FlatRateAdapter", abi: "abi/FlatRateAdapter.json"},
    {name: "PDPCapacityAdapter", abi: "abi/PDPCapacityAdapter.json"},
    {name: "CappedMeteredAdapter", abi: "abi/CappedMeteredAdapter.json"},
    {name: "FWSSPDPResourceAdapter", abi: "abi/FWSSPDPResourceAdapter.json"}
  ]
}
' > packages/contracts/artifacts.json
