from pathlib import Path


def replace_once(path: str, old: str, new: str, label: str) -> None:
    file_path = Path(path)
    text = file_path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    file_path.write_text(text.replace(old, new))


replace_once(
    "reference/filone/reference.py",
    """    if evidence[\"schemaVersion\"] != 1:\n        raise ValueError(\"evidence.schemaVersion must equal 1\")\n""",
    """    if type(evidence[\"schemaVersion\"]) is not int or evidence[\"schemaVersion\"] != 1:\n        raise ValueError(\"evidence.schemaVersion must be the integer 1\")\n""",
    "strict evidence schema version",
)
replace_once(
    "reference/filone/reference.py",
    """        if receipt[\"status\"] != 1:\n            raise ValueError(f\"{stage}: receipt status must equal 1\")\n""",
    """        if type(receipt[\"status\"]) is not int or receipt[\"status\"] != 1:\n            raise ValueError(f\"{stage}: receipt status must be the integer 1\")\n""",
    "strict receipt status",
)
replace_once(
    "reference/filone/test_reference.py",
    """        mismatch = copy.deepcopy(evidence)\n        mismatch[\"transactions\"][\"acceptOffer\"][\"receipt\"][\"transactionHash\"] = HASH(\"e\")\n""",
    """        boolean_schema = copy.deepcopy(evidence)\n        boolean_schema[\"schemaVersion\"] = True\n        with self.assertRaisesRegex(ValueError, \"schemaVersion\"):\n            validate_evidence(rendered, boolean_schema)\n\n        boolean_status = copy.deepcopy(evidence)\n        boolean_status[\"transactions\"][\"acceptOffer\"][\"receipt\"][\"status\"] = True\n        with self.assertRaisesRegex(ValueError, \"receipt status\"):\n            validate_evidence(rendered, boolean_status)\n\n        mismatch = copy.deepcopy(evidence)\n        mismatch[\"transactions\"][\"acceptOffer\"][\"receipt\"][\"transactionHash\"] = HASH(\"e\")\n""",
    "boolean evidence regressions",
)
replace_once(
    "reference/filone/README.md",
    """The renderer signs and broadcasts nothing. It commits the raw `terms.md` bytes and the exact 64-byte capacity-pricing tuple using Ethereum Keccak-256 from the repository's existing Foundry `cast` tool.\n\n## Validate evidence shape\n""",
    """The renderer signs and broadcasts nothing. It commits the raw `terms.md` bytes and the exact 64-byte capacity-pricing tuple using Ethereum Keccak-256 from the repository's existing Foundry `cast` tool.\n\n`renderedOfferSha256` is the SHA-256 digest of canonical JSON: keys sorted, UTF-8 encoded, and no insignificant whitespace. It is deliberately independent of pretty-printing. Compute it with the package's `document_sha256` helper rather than `sha256sum` over the rendered file bytes.\n\n## Validate evidence shape\n""",
    "canonical offer digest documentation",
)
