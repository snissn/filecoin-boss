from pathlib import Path

path = Path("src/BossAccount.sol")
text = path.read_text()
old = """        if (
            isCapacity
                && (offer.quoteTtlEpochs == 0 || offer.assuranceKind != BossTypes.AssuranceKind.ONCHAIN_DETERMINISTIC)
        ) revert InvalidOffer();
"""
new = """        if (isCapacity && offer.quoteTtlEpochs == 0) revert InvalidOffer();
"""
count = text.count(old)
if count != 1:
    raise SystemExit(f"capacity assurance predicate: expected one anchor, found {count}")
path.write_text(text.replace(old, new))
