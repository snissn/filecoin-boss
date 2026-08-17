#!/usr/bin/env python3
"""Render the fixed Filone offer and validate bounded release evidence."""

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")
HASH = re.compile(r"^0x[0-9a-fA-F]{64}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
PRICING_DATA = re.compile(r"^0x[0-9a-f]{128}$")
ZERO_ADDRESS = "0x" + "0" * 40
ZERO_HASH = "0x" + "0" * 64
UINT64_MAX = (1 << 64) - 1
UINT256_MAX = (1 << 256) - 1
TIB = 1 << 40
REFERENCE_DIR = Path(__file__).resolve().parent

PRODUCT_POLICY = {
    "schemaVersion": 1,
    "productId": "filone-managed-storage-v1",
    "serviceName": "Filone Managed Storage",
    "serviceType": "managed-storage",
    "billingKind": "STREAM_CAPACITY",
    "billingKindCode": 1,
    "assuranceKind": "CANCELLABLE_ONLY",
    "assuranceKindCode": 0,
    "dependencyKind": "HARD",
    "dependencyKindCode": 2,
    "activationKind": "IMMEDIATE",
    "activationKindCode": 0,
    "terminationBillingKind": "ZERO_AFTER_REQUEST",
    "terminationBillingKindCode": 1,
    "commissionBps": 0,
    "pauseAllowed": True,
    "dataAccess": "NONE",
    "baseStorage": "UNCHANGED_FWSS_RAIL",
}
PRODUCT_NUMBERS = {"grossPricePerTiBPerPeriod", "periodEpochs", "requiredLockupPeriod", "quoteTtlEpochs"}
PRODUCT_NUMBER_POLICY = {
    "grossPricePerTiBPerPeriod": "2490000000000000000",
    "periodEpochs": 86400,
    "requiredLockupPeriod": 2880,
    "quoteTtlEpochs": 2880,
}
CONFIG_KEYS = {
    "chainId",
    "provider",
    "signingKey",
    "beneficiary",
    "token",
    "resourceAdapter",
    "pricingAdapter",
    "offerVersion",
    "validAfterEpoch",
    "validUntilEpoch",
    "nonce",
    "providerMaxRatePerEpoch",
}
RENDERED_KEYS = {"schemaVersion", "productId", "chainId", "pricingData", "termsSha256", "serviceOffer"}
SERVICE_OFFER_KEYS = {
    "serviceId",
    "offerVersion",
    "provider",
    "signingKey",
    "beneficiary",
    "reporter",
    "token",
    "resourceAdapter",
    "pricingAdapter",
    "serviceType",
    "billingKind",
    "assuranceKind",
    "dependencyKind",
    "activationKind",
    "terminationBillingKind",
    "pricingDataHash",
    "termsHash",
    "accessScopeHash",
    "validAfterEpoch",
    "validUntilEpoch",
    "requiredLockupPeriod",
    "quoteTtlEpochs",
    "commissionBps",
    "commissionRecipient",
    "pauseAllowed",
    "providerMaxRatePerEpoch",
    "providerMaxFixedLockup",
    "nonce",
}
TRANSACTIONS = {
    "fund",
    "approveOperator",
    "createAccount",
    "acceptOffer",
    "syncRate",
    "settle",
    "pause",
    "terminate",
}
OBSERVATIONS = {
    "deployment",
    "bossState",
    "payRail",
    "baseFwss",
    "subgraph",
    "synapseSdk",
    "filecoinPin",
    "explorer",
}
EVIDENCE_KEYS = {
    "schemaVersion",
    "productId",
    "chainId",
    "renderedOfferSha256",
    "deploymentManifestSha256",
    "transactions",
    "observations",
}


def exact_keys(value, expected, label):
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    missing, unknown = expected - value.keys(), value.keys() - expected
    if missing or unknown:
        details = []
        if missing:
            details.append("missing " + ", ".join(sorted(missing)))
        if unknown:
            details.append("unexpected " + ", ".join(sorted(unknown)))
        raise ValueError(f"{label}: {'; '.join(details)}")


def uint(value, label, *, positive=False):
    if isinstance(value, bool):
        raise ValueError(f"{label} must be an unsigned integer")
    if isinstance(value, str):
        if not value or not value.isdecimal():
            raise ValueError(f"{label} must be a decimal unsigned integer")
        number = int(value)
    elif isinstance(value, int):
        number = value
    else:
        raise ValueError(f"{label} must be an unsigned integer")
    if number < 0 or number > UINT256_MAX or (positive and number == 0):
        raise ValueError(f"{label} is outside uint256 bounds")
    return number


def uint64(value, label, *, positive=False):
    number = uint(value, label, positive=positive)
    if number > UINT64_MAX:
        raise ValueError(f"{label} is outside uint64 bounds")
    return number


def canonical_uint_text(value, label, *, bits=256, positive=False):
    if not isinstance(value, str):
        raise ValueError(f"{label} must be canonical decimal text")
    number = uint64(value, label, positive=positive) if bits == 64 else uint(value, label, positive=positive)
    if value != str(number):
        raise ValueError(f"{label} must be canonical decimal text")
    return number


def address(value, label):
    if not isinstance(value, str) or not ADDRESS.fullmatch(value):
        raise ValueError(f"{label} must be an EVM address")
    value = value.lower()
    if value == ZERO_ADDRESS:
        raise ValueError(f"{label} must be nonzero")
    return value


def bytes32_hex(value, label):
    if not isinstance(value, str) or not HASH.fullmatch(value):
        raise ValueError(f"{label} must be a bytes32 value")
    normalized = value.lower()
    if value != normalized:
        raise ValueError(f"{label} must use lowercase hexadecimal")
    return normalized


def tx_hash(value, label):
    if not isinstance(value, str) or not HASH.fullmatch(value):
        raise ValueError(f"{label} must be a bytes32 transaction hash")
    return value.lower()


def sha256_hex(value, label):
    if not isinstance(value, str) or not SHA256.fullmatch(value):
        raise ValueError(f"{label} must be a lowercase SHA-256 hex digest")
    return value


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def document_sha256(document):
    if isinstance(document, bytes):
        try:
            document = json.loads(document)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError("document bytes must contain valid JSON") from error
    return hashlib.sha256(canonical_json(document)).hexdigest()


def keccak(payload):
    try:
        result = subprocess.run(
            ["cast", "keccak", "0x" + payload.hex()], check=True, capture_output=True, text=True
        ).stdout.strip().lower()
    except FileNotFoundError as error:
        raise RuntimeError("Foundry cast is required to compute Ethereum Keccak-256") from error
    except subprocess.CalledProcessError as error:
        raise RuntimeError(error.stderr.strip() or error.stdout.strip() or "cast keccak failed") from error
    if not HASH.fullmatch(result):
        raise RuntimeError("cast keccak returned an invalid bytes32 value")
    return result


def load_product(path):
    product = json.loads(Path(path).read_text(encoding="utf-8"))
    exact_keys(product, set(PRODUCT_POLICY) | PRODUCT_NUMBERS, "product")
    for key, expected in PRODUCT_POLICY.items():
        actual = product[key]
        if type(actual) is not type(expected) or actual != expected:
            raise ValueError(f"product.{key} must equal {expected!r} with the exact JSON type")
    for key, expected in PRODUCT_NUMBER_POLICY.items():
        actual = product[key]
        if type(actual) is not type(expected) or actual != expected:
            raise ValueError(f"product.{key} must equal {expected!r} with the exact JSON type")
    price = uint(product["grossPricePerTiBPerPeriod"], "product.grossPricePerTiBPerPeriod", positive=True)
    if product["grossPricePerTiBPerPeriod"] != str(price):
        raise ValueError("product.grossPricePerTiBPerPeriod must use canonical decimal form")
    uint64(product["periodEpochs"], "product.periodEpochs", positive=True)
    uint64(product["requiredLockupPeriod"], "product.requiredLockupPeriod", positive=True)
    uint64(product["quoteTtlEpochs"], "product.quoteTtlEpochs", positive=True)
    return product


def capacity_pricing_bytes(product):
    price = uint(product["grossPricePerTiBPerPeriod"], "grossPricePerTiBPerPeriod", positive=True)
    period = uint64(product["periodEpochs"], "periodEpochs", positive=True)
    return price.to_bytes(32, "big") + period.to_bytes(32, "big")


def quote_rate_per_epoch(product, size_bytes):
    pricing = capacity_pricing_bytes(product)
    price = int.from_bytes(pricing[:32], "big")
    period = int.from_bytes(pricing[32:], "big")
    return uint(size_bytes, "sizeBytes") * price // (TIB * period)


def render_offer(product, terms, config):
    if not isinstance(terms, bytes) or not terms:
        raise ValueError("terms must be nonempty raw bytes")
    if terms != (REFERENCE_DIR / "terms.md").read_bytes():
        raise ValueError("terms must match the committed Filone v1 terms")
    exact_keys(config, CONFIG_KEYS, "config")
    chain_id = uint64(config["chainId"], "chainId", positive=True)
    offer_version = uint64(config["offerVersion"], "offerVersion", positive=True)
    valid_after = uint64(config["validAfterEpoch"], "validAfterEpoch")
    valid_until = uint64(config["validUntilEpoch"], "validUntilEpoch", positive=True)
    nonce = uint(config["nonce"], "nonce")
    max_rate = uint(config["providerMaxRatePerEpoch"], "providerMaxRatePerEpoch", positive=True)
    if valid_until < valid_after:
        raise ValueError("validUntilEpoch must not precede validAfterEpoch")
    if config["providerMaxRatePerEpoch"] != str(max_rate):
        raise ValueError("providerMaxRatePerEpoch must use canonical decimal form")

    lockup_period = uint64(product["requiredLockupPeriod"], "requiredLockupPeriod", positive=True)
    quote_ttl = uint64(product["quoteTtlEpochs"], "quoteTtlEpochs", positive=True)
    commission_bps = uint(product["commissionBps"], "commissionBps")
    pricing_bytes = capacity_pricing_bytes(product)
    offer = {
        "serviceId": keccak(product["productId"].encode()),
        "offerVersion": str(offer_version),
        "provider": address(config["provider"], "provider"),
        "signingKey": address(config["signingKey"], "signingKey"),
        "beneficiary": address(config["beneficiary"], "beneficiary"),
        "reporter": ZERO_ADDRESS,
        "token": address(config["token"], "token"),
        "resourceAdapter": address(config["resourceAdapter"], "resourceAdapter"),
        "pricingAdapter": address(config["pricingAdapter"], "pricingAdapter"),
        "serviceType": keccak(product["serviceType"].encode()),
        "billingKind": product["billingKindCode"],
        "assuranceKind": product["assuranceKindCode"],
        "dependencyKind": product["dependencyKindCode"],
        "activationKind": product["activationKindCode"],
        "terminationBillingKind": product["terminationBillingKindCode"],
        "pricingDataHash": keccak(pricing_bytes),
        "termsHash": keccak(terms),
        "accessScopeHash": ZERO_HASH,
        "validAfterEpoch": str(valid_after),
        "validUntilEpoch": str(valid_until),
        "requiredLockupPeriod": str(lockup_period),
        "quoteTtlEpochs": str(quote_ttl),
        "commissionBps": str(commission_bps),
        "commissionRecipient": ZERO_ADDRESS,
        "pauseAllowed": product["pauseAllowed"],
        "providerMaxRatePerEpoch": str(max_rate),
        "providerMaxFixedLockup": "0",
        "nonce": str(nonce),
    }
    return {
        "schemaVersion": 1,
        "productId": product["productId"],
        "chainId": str(chain_id),
        "pricingData": "0x" + pricing_bytes.hex(),
        "termsSha256": hashlib.sha256(terms).hexdigest(),
        "serviceOffer": offer,
    }


def validate_rendered_offer(rendered):
    exact_keys(rendered, RENDERED_KEYS, "rendered offer")
    if type(rendered["schemaVersion"]) is not int or rendered["schemaVersion"] != 1:
        raise ValueError("rendered offer.schemaVersion must be the integer 1")
    if rendered["productId"] != PRODUCT_POLICY["productId"]:
        raise ValueError("rendered offer.productId does not match the Filone reference")
    chain_id = canonical_uint_text(rendered["chainId"], "rendered offer.chainId", bits=64, positive=True)

    product = load_product(REFERENCE_DIR / "product.json")
    terms = (REFERENCE_DIR / "terms.md").read_bytes()
    pricing_bytes = capacity_pricing_bytes(product)
    expected_pricing_data = "0x" + pricing_bytes.hex()
    if not isinstance(rendered["pricingData"], str) or not PRICING_DATA.fullmatch(rendered["pricingData"]):
        raise ValueError("rendered offer.pricingData must be 64 lowercase bytes")
    if rendered["pricingData"] != expected_pricing_data:
        raise ValueError("rendered offer.pricingData does not match the fixed Filone capacity terms")
    if sha256_hex(rendered["termsSha256"], "rendered offer.termsSha256") != hashlib.sha256(terms).hexdigest():
        raise ValueError("rendered offer.termsSha256 does not match local raw terms")

    offer = rendered["serviceOffer"]
    exact_keys(offer, SERVICE_OFFER_KEYS, "rendered offer.serviceOffer")
    for field in ("provider", "signingKey", "beneficiary", "token", "resourceAdapter", "pricingAdapter"):
        if offer[field] != address(offer[field], f"serviceOffer.{field}"):
            raise ValueError(f"serviceOffer.{field} must use lowercase hexadecimal")
    if offer["reporter"] != ZERO_ADDRESS:
        raise ValueError("serviceOffer.reporter must be zero for the capacity reference")
    if offer["commissionRecipient"] != ZERO_ADDRESS:
        raise ValueError("serviceOffer.commissionRecipient must be zero")
    if offer["accessScopeHash"] != ZERO_HASH:
        raise ValueError("serviceOffer.accessScopeHash must be zero")

    expected_hashes = {
        "serviceId": keccak(product["productId"].encode()),
        "serviceType": keccak(product["serviceType"].encode()),
        "pricingDataHash": keccak(pricing_bytes),
        "termsHash": keccak(terms),
    }
    for field, expected in expected_hashes.items():
        if bytes32_hex(offer[field], f"serviceOffer.{field}") != expected:
            raise ValueError(f"serviceOffer.{field} does not match the fixed Filone reference")

    fixed_values = {
        "billingKind": product["billingKindCode"],
        "assuranceKind": product["assuranceKindCode"],
        "dependencyKind": product["dependencyKindCode"],
        "activationKind": product["activationKindCode"],
        "terminationBillingKind": product["terminationBillingKindCode"],
        "pauseAllowed": product["pauseAllowed"],
    }
    for field, expected in fixed_values.items():
        if type(offer[field]) is not type(expected) or offer[field] != expected:
            raise ValueError(f"serviceOffer.{field} does not match the fixed Filone policy")

    canonical_uint_text(offer["offerVersion"], "serviceOffer.offerVersion", bits=64, positive=True)
    valid_after = canonical_uint_text(offer["validAfterEpoch"], "serviceOffer.validAfterEpoch", bits=64)
    valid_until = canonical_uint_text(offer["validUntilEpoch"], "serviceOffer.validUntilEpoch", bits=64, positive=True)
    if valid_until < valid_after:
        raise ValueError("serviceOffer.validUntilEpoch must not precede validAfterEpoch")
    canonical_uint_text(offer["nonce"], "serviceOffer.nonce")
    canonical_uint_text(offer["providerMaxRatePerEpoch"], "serviceOffer.providerMaxRatePerEpoch", positive=True)

    expected_text = {
        "requiredLockupPeriod": str(uint64(product["requiredLockupPeriod"], "requiredLockupPeriod", positive=True)),
        "quoteTtlEpochs": str(uint64(product["quoteTtlEpochs"], "quoteTtlEpochs", positive=True)),
        "commissionBps": str(uint(product["commissionBps"], "commissionBps")),
        "providerMaxFixedLockup": "0",
    }
    for field, expected in expected_text.items():
        bits = 64 if field in {"requiredLockupPeriod", "quoteTtlEpochs"} else 256
        canonical_uint_text(offer[field], f"serviceOffer.{field}", bits=bits)
        if offer[field] != expected:
            raise ValueError(f"serviceOffer.{field} does not match the fixed Filone policy")

    return {"chainId": chain_id}


def validate_evidence(rendered, evidence):
    rendered_state = validate_rendered_offer(rendered)
    exact_keys(evidence, EVIDENCE_KEYS, "evidence")
    if type(evidence["schemaVersion"]) is not int or evidence["schemaVersion"] != 1:
        raise ValueError("evidence.schemaVersion must be the integer 1")
    if evidence["productId"] != "filone-managed-storage-v1" or evidence["productId"] != rendered["productId"]:
        raise ValueError("evidence.productId does not match the Filone reference")
    evidence_chain_id = canonical_uint_text(evidence["chainId"], "evidence.chainId", bits=64, positive=True)
    if evidence_chain_id != rendered_state["chainId"]:
        raise ValueError("evidence.chainId does not match the rendered offer")
    if sha256_hex(evidence["renderedOfferSha256"], "evidence.renderedOfferSha256") != document_sha256(rendered):
        raise ValueError("evidence.renderedOfferSha256 does not match the rendered offer")
    sha256_hex(evidence["deploymentManifestSha256"], "evidence.deploymentManifestSha256")

    transactions, observations = evidence["transactions"], evidence["observations"]
    exact_keys(transactions, TRANSACTIONS, "evidence.transactions")
    exact_keys(observations, OBSERVATIONS, "evidence.observations")
    for stage in sorted(TRANSACTIONS):
        transaction = transactions[stage]
        exact_keys(transaction, {"transactionHash", "from", "to", "receipt"}, stage)
        expected_hash = tx_hash(transaction["transactionHash"], f"{stage}.transactionHash")
        address(transaction["from"], f"{stage}.from")
        address(transaction["to"], f"{stage}.to")
        receipt = transaction["receipt"]
        exact_keys(receipt, {"transactionHash", "blockNumber", "status"}, f"{stage}.receipt")
        if tx_hash(receipt["transactionHash"], f"{stage}.receipt.transactionHash") != expected_hash:
            raise ValueError(f"{stage}: receipt transaction hash does not match")
        uint64(receipt["blockNumber"], f"{stage}.receipt.blockNumber", positive=True)
        if type(receipt["status"]) is not int or receipt["status"] != 1:
            raise ValueError(f"{stage}: receipt status must be the integer 1")

    for stage in sorted(OBSERVATIONS):
        observation = observations[stage]
        exact_keys(observation, {"artifactSha256", "assertions"}, stage)
        sha256_hex(observation["artifactSha256"], f"{stage}.artifactSha256")
        assertions = observation["assertions"]
        if not isinstance(assertions, list) or not assertions or any(not isinstance(item, str) or not item for item in assertions):
            raise ValueError(f"{stage}: assertions must contain nonempty strings")

    return {
        "eligibleForIndependentVerification": True,
        "requiresIndependentRpcVerification": True,
        "releaseClaimAuthorized": False,
    }


def read_json(path):
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    render = commands.add_parser("render")
    render.add_argument("--product", default=str(REFERENCE_DIR / "product.json"))
    render.add_argument("--terms", default=str(REFERENCE_DIR / "terms.md"))
    render.add_argument("--config", required=True)
    render.add_argument("--output", required=True)
    validate = commands.add_parser("validate-evidence")
    validate.add_argument("--offer", required=True)
    validate.add_argument("--evidence", required=True)
    args = parser.parse_args()
    if args.command == "render":
        result = render_offer(load_product(args.product), Path(args.terms).read_bytes(), read_json(args.config))
        Path(args.output).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    else:
        print(json.dumps(validate_evidence(read_json(args.offer), read_json(args.evidence)), sort_keys=True))


if __name__ == "__main__":
    main()
