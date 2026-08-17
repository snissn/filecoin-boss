import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from reference import document_sha256


class DocumentHashTest(unittest.TestCase):
    def test_json_bytes_use_the_same_canonical_digest_as_the_decoded_document(self):
        document = {
            "chainId": "314159",
            "productId": "filone-managed-storage-v1",
            "nested": {"enabled": True, "count": 2},
        }
        pretty = (json.dumps(document, indent=2, sort_keys=False) + "\n").encode("utf-8")
        reordered = b'{"nested":{"count":2,"enabled":true},"productId":"filone-managed-storage-v1","chainId":"314159"}'

        expected = document_sha256(document)
        self.assertEqual(document_sha256(pretty), expected)
        self.assertEqual(document_sha256(reordered), expected)

    def test_invalid_json_bytes_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "valid JSON"):
            document_sha256(b'{"chainId":')


if __name__ == "__main__":
    unittest.main()
