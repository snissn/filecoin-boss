#!/usr/bin/env python3
"""Build a Filecoin Boss deployment manifest from exact Foundry broadcast and live RPC evidence."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")
HASH = re.compile(r"^0x[0-9a-fA-F]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
CONTRACT_KEYS = (
    "BossFactory",
    "BossServiceRegistry",
    "BossAdapterRegistry",
    "BossBundles",
    "BossStateView",
    "FlatRateAdapter",
    "PDPCapacityAdapter",
    "CappedMeteredAdapter",
    "FWSSPDPResourceAdapter",
)
SUMMARY_ADDRESS_KEYS = {
    "BossFactory": "contractBossFactory",
    "BossServiceRegistry": "contractBossServiceRegistry",
    "BossAdapterRegistry": "contractBossAdapterRegistry",
    "BossBundles": "contractBossBundles",
    "BossStateView": "contractBossStateView",
    "FlatRateAdapter": "contractFlatRateAdapter",
    "PDPCapacityAdapter": "contractPDPCapacityAdapter",
    "CappedMeteredAdapter": "contractCappedMeteredAdapter",
    "FWSSPDPResourceAdapter": "contractFWSSPDPResourceAdapter",
}
DEPENDENCY_KEYS = {
    "filecoinPay": ("dependencyFilecoinPay", "dependencyFilecoinPayCodeHash"),
    "pdpVerifier": ("dependencyPdpVerifier", "dependencyPdpVerifierCodeHash"),
    "fwssService": ("dependencyFwssService", "dependencyFwssServiceCodeHash"),
    "fwssStateView": ("dependencyFwssStateView", "dependencyFwssStateViewCodeHash"),
    "token": ("dependencyToken", "dependencyTokenCodeHash"),
}


class ManifestError(RuntimeError):
    pass


def cast(*args: str) -> str:
    completed = subprocess.run(["cast", *args], check=False, text=True, capture_output=True)
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise ManifestError(f"cast {' '.join(args)} failed: {detail}")
    return completed.stdout.strip()


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ManifestError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ManifestError(f"expected an object in {path}")
    return value


def normalize_address(value: Any, label: str) -> str:
    if not isinstance(value, str) or ADDRESS.fullmatch(value) is None or int(value, 16) == 0:
        raise ManifestError(f"{label} is not a nonzero address: {value!r}")
    return value.lower()


def normalize_hash(value: Any, label: str, *, nonzero: bool = True) -> str:
    if not isinstance(value, str) or HASH.fullmatch(value) is None:
        raise ManifestError(f"{label} is not a bytes32 hash: {value!r}")
    if nonzero and int(value, 16) == 0:
        raise ManifestError(f"{label} must be nonzero")
    return value.lower()


def normalize_commit(value: str, label: str) -> str:
    if COMMIT.fullmatch(value) is None:
        raise ManifestError(f"{label} is not a lowercase 40-character commit: {value!r}")
    return value


def parse_int(value: Any, label: str) -> int:
    if isinstance(value, bool):
        raise ManifestError(f"{label} is not an integer")
    if isinstance(value, int):
        result = value
    elif isinstance(value, str):
        try:
            result = int(value, 0)
        except ValueError as exc:
            raise ManifestError(f"{label} is not an integer: {value!r}") from exc
    else:
        raise ManifestError(f"{label} is not an integer: {value!r}")
    if result < 0:
        raise ManifestError(f"{label} must be non-negative")
    return result


def transaction_hash(tx: dict[str, Any]) -> str | None:
    for key in ("hash", "transactionHash"):
        value = tx.get(key)
        if isinstance(value, str) and HASH.fullmatch(value):
            return value.lower()
    return None


def contract_address(tx: dict[str, Any]) -> str | None:
    value = tx.get("contractAddress")
    if isinstance(value, str) and ADDRESS.fullmatch(value):
        return value.lower()
    return None


def transaction_to(tx: dict[str, Any]) -> str | None:
    transaction = tx.get("transaction")
    if isinstance(transaction, dict):
        value = transaction.get("to")
        if isinstance(value, str) and ADDRESS.fullmatch(value):
            return value.lower()
    value = tx.get("to")
    if isinstance(value, str) and ADDRESS.fullmatch(value):
        return value.lower()
    return None


def receipt_for(tx_hash: str, rpc_url: str) -> tuple[int, int]:
    try:
        receipt = json.loads(cast("receipt", tx_hash, "--rpc-url", rpc_url, "--json"))
    except json.JSONDecodeError as exc:
        raise ManifestError(f"cast returned malformed receipt JSON for {tx_hash}") from exc
    if not isinstance(receipt, dict):
        raise ManifestError(f"receipt for {tx_hash} is not an object")
    status = parse_int(receipt.get("status"), f"receipt {tx_hash} status")
    if status != 1:
        raise ManifestError(f"deployment transaction {tx_hash} did not succeed")
    block_number = parse_int(receipt.get("blockNumber"), f"receipt {tx_hash} blockNumber")
    return status, block_number


def live_code_hash(address: str, rpc_url: str, label: str) -> str:
    code = cast("code", address, "--rpc-url", rpc_url)
    if code in ("", "0x"):
        raise ManifestError(f"{label} has no runtime code at {address}")
    return normalize_hash(cast("keccak", code), f"{label} runtime code hash")


def choose_tx_hash(
    name: str,
    address: str,
    transactions: list[dict[str, Any]],
    factory_address: str,
    factory_tx_hash: str | None,
) -> str:
    direct = [transaction_hash(tx) for tx in transactions if contract_address(tx) == address]
    direct = [value for value in direct if value is not None]
    if direct:
        return direct[-1]
    if name == "BossBundles" and factory_tx_hash is not None:
        return factory_tx_hash
    if name == "smokeAccount":
        calls = [transaction_hash(tx) for tx in transactions if transaction_to(tx) == factory_address]
        calls = [value for value in calls if value is not None]
        if calls:
            return calls[-1]
    raise ManifestError(f"cannot bind {name} at {address} to an exact broadcast transaction")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite", type=Path, required=True)
    parser.add_argument("--broadcast", type=Path, required=True)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--network", required=True)
    parser.add_argument("--protocol-commit", required=True)
    parser.add_argument("--deployment-commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    summary = load_json(args.suite)
    broadcast = load_json(args.broadcast)
    transactions_value = broadcast.get("transactions")
    if not isinstance(transactions_value, list) or not transactions_value:
        raise ManifestError("Foundry broadcast contains no transactions")
    transactions = [value for value in transactions_value if isinstance(value, dict)]
    if len(transactions) != len(transactions_value):
        raise ManifestError("Foundry broadcast contains a malformed transaction entry")

    chain_id = parse_int(cast("chain-id", "--rpc-url", args.rpc_url), "RPC chain ID")
    summary_chain_id = parse_int(summary.get("chainId"), "suite chain ID")
    if chain_id != summary_chain_id:
        raise ManifestError(f"suite chain ID {summary_chain_id} does not match RPC chain ID {chain_id}")

    addresses = {
        name: normalize_address(summary.get(summary_key), f"suite {name}")
        for name, summary_key in SUMMARY_ADDRESS_KEYS.items()
    }
    factory_address = addresses["BossFactory"]
    factory_direct = [transaction_hash(tx) for tx in transactions if contract_address(tx) == factory_address]
    factory_direct = [value for value in factory_direct if value is not None]
    factory_tx_hash = factory_direct[-1] if factory_direct else None

    contracts: dict[str, dict[str, Any]] = {}
    deployment_blocks: list[int] = []
    for name in CONTRACT_KEYS:
        address = addresses[name]
        tx_hash = choose_tx_hash(name, address, transactions, factory_address, factory_tx_hash)
        _, block_number = receipt_for(tx_hash, args.rpc_url)
        deployment_blocks.append(block_number)
        contracts[name] = {
            "address": address,
            "runtimeCodeHash": live_code_hash(address, args.rpc_url, name),
            "deploymentTxHash": tx_hash,
            "deploymentBlock": block_number,
        }

    smoke_address = normalize_address(summary.get("smokeAccount"), "suite smoke account")
    smoke_tx_hash = choose_tx_hash("smokeAccount", smoke_address, transactions, factory_address, factory_tx_hash)
    _, smoke_block = receipt_for(smoke_tx_hash, args.rpc_url)
    deployment_blocks.append(smoke_block)

    dependencies: dict[str, str] = {}
    dependency_hashes: dict[str, str] = {}
    for name, (address_key, hash_key) in DEPENDENCY_KEYS.items():
        address = normalize_address(summary.get(address_key), f"dependency {name}")
        expected_hash = normalize_hash(summary.get(hash_key), f"dependency {name} expected hash")
        observed_hash = live_code_hash(address, args.rpc_url, f"dependency {name}")
        if observed_hash != expected_hash:
            raise ManifestError(f"dependency {name} runtime hash drift: expected {expected_hash}, observed {observed_hash}")
        dependencies[name] = address
        dependency_hashes[name] = expected_hash

    manifest = {
        "schemaVersion": 1,
        "network": args.network,
        "chainId": chain_id,
        "protocolCommit": normalize_commit(args.protocol_commit, "protocol commit"),
        "deploymentCommit": normalize_commit(args.deployment_commit, "deployment commit"),
        "deployer": normalize_address(summary.get("deployer"), "deployer"),
        "governance": normalize_address(summary.get("governance"), "governance"),
        "accountCreationCodeHash": normalize_hash(summary.get("accountCreationCodeHash"), "account creation code hash"),
        "deploymentBlock": min(deployment_blocks),
        "dependencies": dependencies,
        "dependencyRuntimeCodeHashes": dependency_hashes,
        "contracts": contracts,
        "smokeAccount": {
            "address": smoke_address,
            "owner": normalize_address(summary.get("smokeOwner"), "smoke owner"),
            "runtimeCodeHash": live_code_hash(smoke_address, args.rpc_url, "smoke account"),
            "deploymentTxHash": smoke_tx_hash,
            "deploymentBlock": smoke_block,
        },
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(args.output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ManifestError as exc:
        print(f"manifest finalization failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
