#!/usr/bin/env python3
"""Fail-closed static and optional live validation for Filecoin Boss deployment manifests."""

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
TOP_LEVEL_KEYS = {
    "schemaVersion", "network", "chainId", "protocolCommit", "deploymentCommit", "deployer", "governance",
    "accountCreationCodeHash", "deploymentBlock", "dependencies", "dependencyRuntimeCodeHashes", "contracts",
    "smokeAccount",
}
DEPENDENCY_KEYS = {"filecoinPay", "pdpVerifier", "fwssService", "fwssStateView", "token"}
CONTRACT_KEYS = {
    "BossFactory", "BossServiceRegistry", "BossAdapterRegistry", "BossBundles", "BossStateView",
    "FlatRateAdapter", "PDPCapacityAdapter", "CappedMeteredAdapter", "FWSSPDPResourceAdapter",
}
DEPLOYMENT_KEYS = {"address", "runtimeCodeHash", "deploymentTxHash", "deploymentBlock"}
SMOKE_KEYS = {"address", "owner", "runtimeCodeHash", "deploymentTxHash", "deploymentBlock"}


class ValidationError(RuntimeError):
    pass


def cast(*args: str) -> str:
    completed = subprocess.run(["cast", *args], check=False, text=True, capture_output=True)
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise ValidationError(f"cast {' '.join(args)} failed: {detail}")
    return completed.stdout.strip()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    observed = set(value)
    require(
        observed == expected,
        f"{label} keys differ: missing={sorted(expected-observed)}, extra={sorted(observed-expected)}",
    )
    return value


def address(value: Any, label: str) -> str:
    require(isinstance(value, str) and ADDRESS.fullmatch(value) is not None, f"{label} is not an address")
    require(int(value, 16) != 0, f"{label} must be nonzero")
    return value.lower()


def hash32(value: Any, label: str) -> str:
    require(isinstance(value, str) and HASH.fullmatch(value) is not None, f"{label} is not bytes32")
    require(int(value, 16) != 0, f"{label} must be nonzero")
    return value.lower()


def nonnegative_int(value: Any, label: str) -> int:
    require(
        isinstance(value, int) and not isinstance(value, bool) and value >= 0,
        f"{label} must be a non-negative integer",
    )
    return value


def parse_cast_int(value: Any, label: str) -> int:
    if isinstance(value, int):
        return value
    require(isinstance(value, str), f"{label} is not an integer")
    try:
        return int(value, 0)
    except ValueError as exc:
        raise ValidationError(f"{label} is not an integer") from exc


def live_code_hash(target: str, rpc_url: str, label: str) -> str:
    code = cast("code", target, "--rpc-url", rpc_url)
    require(code not in ("", "0x"), f"{label} has no runtime code")
    return hash32(cast("keccak", code), f"{label} live code hash")


def receipt(tx_hash: str, rpc_url: str, expected_block: int, label: str) -> None:
    try:
        value = json.loads(cast("receipt", tx_hash, "--rpc-url", rpc_url, "--json"))
    except json.JSONDecodeError as exc:
        raise ValidationError(f"{label} receipt JSON is malformed") from exc
    require(isinstance(value, dict), f"{label} receipt is not an object")
    require(parse_cast_int(value.get("status"), f"{label} status") == 1, f"{label} transaction failed")
    require(
        parse_cast_int(value.get("blockNumber"), f"{label} block") == expected_block,
        f"{label} receipt block differs from manifest",
    )


def cast_address(target: str, signature: str, rpc_url: str) -> str:
    output = cast("call", target, signature, "--rpc-url", rpc_url)
    match = re.search(r"0x[0-9a-fA-F]{40}", output)
    if match is None:
        raise ValidationError(f"cannot decode address from {signature} on {target}: {output}")
    return match.group(0).lower()


def cast_hash(target: str, signature: str, rpc_url: str) -> str:
    output = cast("call", target, signature, "--rpc-url", rpc_url)
    match = re.search(r"0x[0-9a-fA-F]{64}", output)
    if match is None:
        raise ValidationError(f"cannot decode bytes32 from {signature} on {target}: {output}")
    return match.group(0).lower()


def cast_uint(target: str, signature: str, rpc_url: str) -> int:
    output = cast("call", target, signature, "--rpc-url", rpc_url).split()[0]
    return int(output, 0)


def validate_static(manifest: dict[str, Any]) -> None:
    exact_keys(manifest, TOP_LEVEL_KEYS, "manifest")
    require(manifest["schemaVersion"] == 1, "schemaVersion must equal 1")
    require(isinstance(manifest["network"], str) and manifest["network"].strip(), "network must be nonempty")
    require(nonnegative_int(manifest["chainId"], "chainId") > 0, "chainId must be positive")
    require(
        isinstance(manifest["protocolCommit"], str) and COMMIT.fullmatch(manifest["protocolCommit"]),
        "protocolCommit is invalid",
    )
    require(
        isinstance(manifest["deploymentCommit"], str) and COMMIT.fullmatch(manifest["deploymentCommit"]),
        "deploymentCommit is invalid",
    )
    address(manifest["deployer"], "deployer")
    address(manifest["governance"], "governance")
    hash32(manifest["accountCreationCodeHash"], "accountCreationCodeHash")
    deployment_block = nonnegative_int(manifest["deploymentBlock"], "deploymentBlock")

    dependencies = exact_keys(manifest["dependencies"], DEPENDENCY_KEYS, "dependencies")
    dependency_hashes = exact_keys(
        manifest["dependencyRuntimeCodeHashes"], DEPENDENCY_KEYS, "dependencyRuntimeCodeHashes"
    )
    for key in sorted(DEPENDENCY_KEYS):
        address(dependencies[key], f"dependencies.{key}")
        hash32(dependency_hashes[key], f"dependencyRuntimeCodeHashes.{key}")

    contracts = exact_keys(manifest["contracts"], CONTRACT_KEYS, "contracts")
    deployed_addresses: list[str] = []
    for key in sorted(CONTRACT_KEYS):
        item = exact_keys(contracts[key], DEPLOYMENT_KEYS, f"contracts.{key}")
        deployed_addresses.append(address(item["address"], f"contracts.{key}.address"))
        hash32(item["runtimeCodeHash"], f"contracts.{key}.runtimeCodeHash")
        hash32(item["deploymentTxHash"], f"contracts.{key}.deploymentTxHash")
        block = nonnegative_int(item["deploymentBlock"], f"contracts.{key}.deploymentBlock")
        require(block >= deployment_block, f"contracts.{key}.deploymentBlock predates deploymentBlock")

    smoke = exact_keys(manifest["smokeAccount"], SMOKE_KEYS, "smokeAccount")
    deployed_addresses.append(address(smoke["address"], "smokeAccount.address"))
    address(smoke["owner"], "smokeAccount.owner")
    hash32(smoke["runtimeCodeHash"], "smokeAccount.runtimeCodeHash")
    hash32(smoke["deploymentTxHash"], "smokeAccount.deploymentTxHash")
    require(
        nonnegative_int(smoke["deploymentBlock"], "smokeAccount.deploymentBlock") >= deployment_block,
        "smokeAccount.deploymentBlock predates deploymentBlock",
    )
    require(len(deployed_addresses) == len(set(deployed_addresses)), "contract and smoke addresses must be unique")


def validate_live(manifest: dict[str, Any], rpc_url: str) -> None:
    observed_chain = int(cast("chain-id", "--rpc-url", rpc_url), 0)
    require(observed_chain == manifest["chainId"], "RPC chain ID differs from manifest")

    for key in sorted(DEPENDENCY_KEYS):
        target = manifest["dependencies"][key].lower()
        observed = live_code_hash(target, rpc_url, f"dependency {key}")
        require(observed == manifest["dependencyRuntimeCodeHashes"][key].lower(), f"dependency {key} runtime hash differs")

    for key in sorted(CONTRACT_KEYS):
        item = manifest["contracts"][key]
        target = item["address"].lower()
        require(live_code_hash(target, rpc_url, key) == item["runtimeCodeHash"].lower(), f"{key} runtime hash differs")
        receipt(item["deploymentTxHash"], rpc_url, item["deploymentBlock"], key)

    smoke = manifest["smokeAccount"]
    require(
        live_code_hash(smoke["address"], rpc_url, "smoke account") == smoke["runtimeCodeHash"].lower(),
        "smoke account runtime hash differs",
    )
    receipt(smoke["deploymentTxHash"], rpc_url, smoke["deploymentBlock"], "smoke account")

    contracts = manifest["contracts"]
    factory = contracts["BossFactory"]["address"].lower()
    registry = contracts["BossAdapterRegistry"]["address"].lower()
    resource_adapter = contracts["FWSSPDPResourceAdapter"]["address"].lower()
    account = smoke["address"].lower()

    require(cast_address(factory, "bundles()(address)", rpc_url) == contracts["BossBundles"]["address"].lower(), "factory bundles mismatch")
    require(cast_hash(factory, "accountCreationCodeHash()(bytes32)", rpc_url) == manifest["accountCreationCodeHash"].lower(), "account creation code hash mismatch")
    require(cast_address(registry, "governance()(address)", rpc_url) == manifest["governance"].lower(), "adapter governance mismatch")
    require(cast_address(resource_adapter, "pdpVerifier()(address)", rpc_url) == manifest["dependencies"]["pdpVerifier"].lower(), "resource adapter PDP mismatch")
    require(cast_address(resource_adapter, "fwssService()(address)", rpc_url) == manifest["dependencies"]["fwssService"].lower(), "resource adapter FWSS service mismatch")
    require(cast_address(resource_adapter, "fwssStateView()(address)", rpc_url) == manifest["dependencies"]["fwssStateView"].lower(), "resource adapter FWSS state view mismatch")
    require(cast_address(account, "owner()(address)", rpc_url) == smoke["owner"].lower(), "smoke owner mismatch")
    require(cast_address(account, "payer()(address)", rpc_url) == smoke["owner"].lower(), "smoke payer mismatch")
    require(cast_address(account, "filecoinPay()(address)", rpc_url) == manifest["dependencies"]["filecoinPay"].lower(), "smoke Filecoin Pay mismatch")
    require(cast_address(account, "serviceRegistry()(address)", rpc_url) == contracts["BossServiceRegistry"]["address"].lower(), "smoke service registry mismatch")
    require(cast_address(account, "adapterRegistry()(address)", rpc_url) == registry, "smoke adapter registry mismatch")
    require(cast_address(account, "factory()(address)", rpc_url) == factory, "smoke factory mismatch")
    require(cast_uint(account, "accountVersion()(uint64)", rpc_url) == 1, "smoke account version mismatch")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--rpc-url")
    parser.add_argument("--expected-network")
    parser.add_argument("--expected-deployment-commit")
    args = parser.parse_args()

    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError(f"cannot read manifest {args.manifest}: {exc}") from exc
    require(isinstance(manifest, dict), "manifest root must be an object")
    validate_static(manifest)
    if args.expected_network is not None:
        require(manifest["network"] == args.expected_network, "manifest network differs from expectation")
    if args.expected_deployment_commit is not None:
        require(manifest["deploymentCommit"] == args.expected_deployment_commit, "manifest deploymentCommit differs from expectation")
    if args.rpc_url is not None:
        validate_live(manifest, args.rpc_url)
    print(f"validated {args.manifest}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as exc:
        print(f"manifest validation failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
