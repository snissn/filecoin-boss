#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

source_commit=${SOURCE_COMMIT:-}
if [[ -z "$source_commit" ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "working tree is not clean; commit the source or set SOURCE_COMMIT explicitly" >&2
    exit 1
  fi
  source_commit=$(git rev-parse HEAD)
fi
if [[ ! "$source_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "invalid SOURCE_COMMIT: $source_commit" >&2
  exit 1
fi
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git cat-file -e "${source_commit}^{commit}" 2>/dev/null || {
    echo "SOURCE_COMMIT is not available in this repository: $source_commit" >&2
    exit 1
  }
  generated_pathspecs=(
    ':(exclude)packages/contracts/abi/**'
    ':(exclude)packages/contracts/bytecode/**'
    ':(exclude)packages/contracts/artifacts.json'
  )
  if ! git diff --quiet "$source_commit" -- . "${generated_pathspecs[@]}"; then
    echo "build inputs do not match SOURCE_COMMIT: $source_commit" >&2
    git diff --stat "$source_commit" -- . "${generated_pathspecs[@]}" >&2
    exit 1
  fi
  untracked=$(git ls-files --others --exclude-standard -- . "${generated_pathspecs[@]}")
  if [[ -n "$untracked" ]]; then
    echo "untracked build inputs are not represented by SOURCE_COMMIT: $source_commit" >&2
    printf '%s\n' "$untracked" >&2
    exit 1
  fi
fi

forge build >/dev/null
forge_config=$(forge config --json)
compiler=$(jq -c '{
  solcVersion: .solc,
  evmVersion: .evm_version,
  optimizer: {enabled: .optimizer, runs: .optimizer_runs},
  viaIR: .via_ir,
  bytecodeHash: .bytecode_hash,
  cborMetadata: .cbor_metadata
}' <<<"$forge_config")

ABI_DIR=packages/contracts/abi
BYTECODE_DIR=packages/contracts/bytecode
rm -rf "$ABI_DIR" "$BYTECODE_DIR"
mkdir -p "$ABI_DIR" "$BYTECODE_DIR"

# This is the sole declaration of the published contract set.
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
  if [[ ! -f "$artifact" ]]; then
    echo "missing Foundry artifact: $artifact" >&2
    exit 1
  fi
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

manifest_tmp=$(mktemp)
jq -S -n \
  --arg sourceCommit "$source_commit" \
  --arg creationHash "$creation_hash" \
  --argjson compiler "$compiler" \
  --args '
{
  schemaVersion: 1,
  sourceCommit: $sourceCommit,
  protocolCommit: $sourceCommit,
  compiler: $compiler,
  accountCreationCodeHash: $creationHash,
  contracts: [
    $ARGS.positional[] as $name
    | {name: $name, abi: ("abi/" + $name + ".json")}
    | if $name == "BossAccount" then
        . + {
          creationCode: "bytecode/BossAccount.creation.hex",
          creationCodeHash: $creationHash
        }
      else . end
  ]
}
' "${contracts[@]}" > "$manifest_tmp"
mv "$manifest_tmp" packages/contracts/artifacts.json
