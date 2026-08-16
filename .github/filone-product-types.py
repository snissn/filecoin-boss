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
    """    for key, expected in PRODUCT_POLICY.items():
        if product[key] != expected:
            raise ValueError(f"product.{key} must equal {expected!r}")
""",
    """    for key, expected in PRODUCT_POLICY.items():
        actual = product[key]
        if type(actual) is not type(expected) or actual != expected:
            raise ValueError(f"product.{key} must equal {expected!r} with the exact JSON type")
""",
    "type-sensitive product policy",
)
replace_once(
    "reference/filone/test_reference.py",
    """import sys
import unittest
from pathlib import Path
""",
    """import sys
import tempfile
import unittest
from pathlib import Path
""",
    "tempfile import",
)
replace_once(
    "reference/filone/test_reference.py",
    """        self.assertEqual(quote_rate_per_epoch(self.product, 1 << 40), 28_819_444_444_444)
        self.assertEqual(quote_rate_per_epoch(self.product, 2 << 40), 57_638_888_888_888)

    def test_rendered_offer_binds_exact_terms_pricing_and_authority(self):
""",
    """        self.assertEqual(quote_rate_per_epoch(self.product, 1 << 40), 28_819_444_444_444)
        self.assertEqual(quote_rate_per_epoch(self.product, 2 << 40), 57_638_888_888_888)

    def test_product_policy_rejects_boolean_integer_aliases(self):
        product = json.loads((HERE / "product.json").read_text(encoding="utf-8"))
        for field, invalid in (
            ("schemaVersion", True),
            ("billingKindCode", True),
            ("assuranceKindCode", False),
            ("commissionBps", False),
            ("pauseAllowed", 1),
        ):
            mutated = copy.deepcopy(product)
            mutated[field] = invalid
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "product.json"
                path.write_text(json.dumps(mutated), encoding="utf-8")
                with self.assertRaisesRegex(ValueError, field):
                    load_product(path)

    def test_rendered_offer_binds_exact_terms_pricing_and_authority(self):
""",
    "product type regression",
)
