from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    return text.replace(old, new)


path = Path("reference/filone/reference.py")
text = path.read_text()
text = replace_once(
    text,
    'SHA256 = re.compile(r"^[0-9a-f]{64}$")\nZERO_ADDRESS =',
    'SHA256 = re.compile(r"^[0-9a-f]{64}$")\n'
    'PRICING_DATA = re.compile(r"^0x[0-9a-f]{128}$")\n'
    'ZERO_ADDRESS =',
    "pricing-data pattern",
)
text = replace_once(
    text,
    'TIB = 1 << 40\n\nPRODUCT_POLICY = {',
    'TIB = 1 << 40\nREFERENCE_DIR = Path(__file__).resolve().parent\n\nPRODUCT_POLICY = {',
    "reference directory",
)
config_anchor = '''CONFIG_KEYS = {
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
'''
rendered_schema = config_anchor + '''RENDERED_KEYS = {"schemaVersion", "productId", "chainId", "pricingData", "termsSha256", "serviceOffer"}
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
'''
text = replace_once(text, config_anchor, rendered_schema, "rendered schemas")
uint64_anchor = '''def uint64(value, label, *, positive=False):
    number = uint(value, label, positive=positive)
    if number > UINT64_MAX:
        raise ValueError(f"{label} is outside uint64 bounds")
    return number


'''
uint64_addition = uint64_anchor + '''def canonical_uint_text(value, label, *, bits=256, positive=False):
    if not isinstance(value, str):
        raise ValueError(f"{label} must be canonical decimal text")
    number = uint64(value, label, positive=positive) if bits == 64 else uint(value, label, positive=positive)
    if value != str(number):
        raise ValueError(f"{label} must be canonical decimal text")
    return number


'''
text = replace_once(text, uint64_anchor, uint64_addition, "canonical integer text")
address_anchor = '''def address(value, label):
    if not isinstance(value, str) or not ADDRESS.fullmatch(value):
        raise ValueError(f"{label} must be an EVM address")
    value = value.lower()
    if value == ZERO_ADDRESS:
        raise ValueError(f"{label} must be nonzero")
    return value


'''
address_addition = address_anchor + '''def bytes32_hex(value, label):
    if not isinstance(value, str) or not HASH.fullmatch(value):
        raise ValueError(f"{label} must be a bytes32 value")
    normalized = value.lower()
    if value != normalized:
        raise ValueError(f"{label} must use lowercase hexadecimal")
    return normalized


'''
text = replace_once(text, address_anchor, address_addition, "bytes32 validation")
quote_anchor = '''def quote_rate_per_epoch(product, size_bytes):
    price = uint(product["grossPricePerTiBPerPeriod"], "grossPricePerTiBPerPeriod", positive=True)
    period = uint64(product["periodEpochs"], "periodEpochs", positive=True)
    return uint(size_bytes, "sizeBytes") * price // (TIB * period)


'''
quote_replacement = '''def capacity_pricing_bytes(product):
    price = uint(product["grossPricePerTiBPerPeriod"], "grossPricePerTiBPerPeriod", positive=True)
    period = uint64(product["periodEpochs"], "periodEpochs", positive=True)
    return price.to_bytes(32, "big") + period.to_bytes(32, "big")


def quote_rate_per_epoch(product, size_bytes):
    pricing = capacity_pricing_bytes(product)
    price = int.from_bytes(pricing[:32], "big")
    period = int.from_bytes(pricing[32:], "big")
    return uint(size_bytes, "sizeBytes") * price // (TIB * period)


'''
text = replace_once(text, quote_anchor, quote_replacement, "capacity pricing bytes")
render_terms_anchor = '''    price = uint(product["grossPricePerTiBPerPeriod"], "grossPricePerTiBPerPeriod", positive=True)
    period = uint64(product["periodEpochs"], "periodEpochs", positive=True)
    lockup_period = uint64(product["requiredLockupPeriod"], "requiredLockupPeriod", positive=True)
    quote_ttl = uint64(product["quoteTtlEpochs"], "quoteTtlEpochs", positive=True)
    commission_bps = uint(product["commissionBps"], "commissionBps")
    pricing_bytes = price.to_bytes(32, "big") + period.to_bytes(32, "big")
'''
render_terms_replacement = '''    lockup_period = uint64(product["requiredLockupPeriod"], "requiredLockupPeriod", positive=True)
    quote_ttl = uint64(product["quoteTtlEpochs"], "quoteTtlEpochs", positive=True)
    commission_bps = uint(product["commissionBps"], "commissionBps")
    pricing_bytes = capacity_pricing_bytes(product)
'''
text = replace_once(text, render_terms_anchor, render_terms_replacement, "render pricing tuple")
text = replace_once(
    text,
    '        "chainId": chain_id,\n',
    '        "chainId": str(chain_id),\n',
    "BigInt-safe rendered chain ID",
)
validate_anchor = '''def validate_evidence(rendered, evidence):
    exact_keys(evidence, EVIDENCE_KEYS, "evidence")
    if type(evidence["schemaVersion"]) is not int or evidence["schemaVersion"] != 1:
        raise ValueError("evidence.schemaVersion must be the integer 1")
    if evidence["productId"] != "filone-managed-storage-v1" or evidence["productId"] != rendered.get("productId"):
        raise ValueError("evidence.productId does not match the Filone reference")
    if uint64(evidence["chainId"], "evidence.chainId", positive=True) != rendered.get("chainId"):
        raise ValueError("evidence.chainId does not match the rendered offer")
'''
validate_replacement = '''def validate_rendered_offer(rendered):
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
'''
text = replace_once(text, validate_anchor, validate_replacement, "complete rendered offer validation")
text = replace_once(
    text,
    '    render.add_argument("--product", default=str(Path(__file__).with_name("product.json")))\n'
    '    render.add_argument("--terms", default=str(Path(__file__).with_name("terms.md")))\n',
    '    render.add_argument("--product", default=str(REFERENCE_DIR / "product.json"))\n'
    '    render.add_argument("--terms", default=str(REFERENCE_DIR / "terms.md"))\n',
    "reference defaults",
)
path.write_text(text)

readme_path = Path("reference/filone/README.md")
readme = readme_path.read_text()
readme = replace_once(
    readme,
    'The renderer signs and broadcasts nothing. It commits the raw `terms.md` bytes and the exact 64-byte capacity-pricing tuple using Ethereum Keccak-256 from the repository\'s existing Foundry `cast` tool.\n\n',
    'The renderer signs and broadcasts nothing. It commits the raw `terms.md` bytes and the exact 64-byte capacity-pricing tuple using Ethereum Keccak-256 from the repository\'s existing Foundry `cast` tool. The rendered envelope serializes `chainId` as canonical decimal text so every valid uint64 value remains exact in JavaScript and other JSON consumers. The evidence document uses the same representation.\n\n',
    "README chain identity",
)
readme = replace_once(
    readme,
    'A successful result means only that the bounded document is eligible for an independent verifier. It always returns:\n',
    'Before evidence is admitted, the validator reloads the committed product and raw terms, validates the complete rendered envelope and service-offer key set, and recomputes the service, pricing, and terms commitments. A truncated offer or a document whose digest was merely recomputed is rejected.\n\nA successful result means only that the bounded document is eligible for an independent verifier. It always returns:\n',
    "README complete-envelope boundary",
)
readme_path.write_text(readme)
