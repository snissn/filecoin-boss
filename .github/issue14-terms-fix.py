from pathlib import Path

path = Path("reference/filone/reference.py")
text = path.read_text()
anchor = '''PRODUCT_NUMBERS = {"grossPricePerTiBPerPeriod", "periodEpochs", "requiredLockupPeriod", "quoteTtlEpochs"}
'''
replacement = anchor + '''PRODUCT_NUMBER_POLICY = {
    "grossPricePerTiBPerPeriod": "2490000000000000000",
    "periodEpochs": 86400,
    "requiredLockupPeriod": 2880,
    "quoteTtlEpochs": 2880,
}
'''
if text.count(anchor) != 1:
    raise SystemExit(f"numeric policy declaration: expected one anchor, found {text.count(anchor)}")
text = text.replace(anchor, replacement)
loop_anchor = '''    for key, expected in PRODUCT_POLICY.items():
        actual = product[key]
        if type(actual) is not type(expected) or actual != expected:
            raise ValueError(f"product.{key} must equal {expected!r} with the exact JSON type")
'''
loop_replacement = loop_anchor + '''    for key, expected in PRODUCT_NUMBER_POLICY.items():
        actual = product[key]
        if type(actual) is not type(expected) or actual != expected:
            raise ValueError(f"product.{key} must equal {expected!r} with the exact JSON type")
'''
if text.count(loop_anchor) != 1:
    raise SystemExit(f"numeric policy validation: expected one anchor, found {text.count(loop_anchor)}")
path.write_text(text.replace(loop_anchor, loop_replacement))
