import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from reference import load_product, render_offer, validate_evidence
from test_reference import CONFIG, valid_evidence

ZERO_HASH = "0x" + "0" * 64


class ZeroTransactionHashTest(unittest.TestCase):
    def test_evidence_rejects_zero_transaction_and_receipt_hash_placeholders(self):
        product = load_product(HERE / "product.json")
        terms = (HERE / "terms.md").read_bytes()
        rendered = render_offer(product, terms, CONFIG)
        evidence = valid_evidence(rendered)
        evidence["transactions"]["acceptOffer"]["transactionHash"] = ZERO_HASH
        evidence["transactions"]["acceptOffer"]["receipt"]["transactionHash"] = ZERO_HASH

        with self.assertRaisesRegex(ValueError, "acceptOffer.transactionHash must be nonzero"):
            validate_evidence(rendered, evidence)


if __name__ == "__main__":
    unittest.main()
