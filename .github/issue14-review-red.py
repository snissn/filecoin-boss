from pathlib import Path

path = Path("reference/filone/test_reference.py")
text = path.read_text()
anchor = '''    def test_rendered_offer_binds_exact_terms_pricing_and_authority(self):
'''
addition = '''    def test_product_policy_pins_numeric_v1_terms(self):
        product = json.loads((HERE / "product.json").read_text(encoding="utf-8"))
        for field, invalid in (
            ("grossPricePerTiBPerPeriod", "1"),
            ("periodEpochs", 1),
            ("requiredLockupPeriod", 1),
            ("quoteTtlEpochs", 1),
        ):
            mutated = copy.deepcopy(product)
            mutated[field] = invalid
            with tempfile.TemporaryDirectory() as directory:
                candidate = Path(directory) / "product.json"
                candidate.write_text(json.dumps(mutated), encoding="utf-8")
                with self.assertRaisesRegex(ValueError, field):
                    load_product(candidate)

''' + anchor
if "def test_product_policy_pins_numeric_v1_terms" not in text:
    count = text.count(anchor)
    if count != 1:
        raise SystemExit(f"numeric terms test: expected one anchor, found {count}")
    text = text.replace(anchor, addition)
path.write_text(text)
