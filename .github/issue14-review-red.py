from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    return text.replace(old, new)


path = Path("reference/filone/test_reference.py")
text = path.read_text()
text = replace_once(
    text,
    'HASH = lambda digit: f"0x{digit * 64}"\n\nCONFIG = {',
    'HASH = lambda digit: f"0x{digit * 64}"\nUINT64_MAX = (1 << 64) - 1\n\nCONFIG = {',
    "uint64 test constant",
)
text = replace_once(
    text,
    '        "chainId": 314159,\n        "renderedOfferSha256": document_sha256(rendered),',
    '        "chainId": rendered["chainId"],\n        "renderedOfferSha256": document_sha256(rendered),',
    "evidence chain binding",
)
text = replace_once(
    text,
    '        self.assertEqual(rendered["chainId"], 314159)\n',
    '        self.assertEqual(rendered["chainId"], "314159")\n',
    "rendered chain text",
)
text = replace_once(
    text,
    '        too_large = dict(CONFIG)\n',
    '        large_chain = dict(CONFIG)\n'
    '        large_chain["chainId"] = UINT64_MAX\n'
    '        self.assertEqual(render_offer(self.product, self.terms, large_chain)["chainId"], str(UINT64_MAX))\n\n'
    '        too_large = dict(CONFIG)\n',
    "large chain regression",
)
text = replace_once(
    text,
    '    def test_evidence_is_fail_closed_and_never_self_authorizes_release(self):\n',
    '    def test_evidence_validates_complete_rendered_offer_and_never_self_authorizes_release(self):\n',
    "evidence test name",
)
anchor = '''        self.assertEqual(
            result,
            {
                "eligibleForIndependentVerification": True,
                "requiresIndependentRpcVerification": True,
                "releaseClaimAuthorized": False,
            },
        )

'''
addition = anchor + '''        incomplete = {"productId": "filone-managed-storage-v1", "chainId": "314159"}
        with self.assertRaisesRegex(ValueError, "rendered offer"):
            validate_evidence(incomplete, valid_evidence(incomplete))

        tampered_pricing = copy.deepcopy(rendered)
        tampered_pricing["pricingData"] = "0x" + "00" * 64
        with self.assertRaisesRegex(ValueError, "pricingData"):
            validate_evidence(tampered_pricing, valid_evidence(tampered_pricing))

        tampered_policy = copy.deepcopy(rendered)
        tampered_policy["serviceOffer"]["billingKind"] = 0
        with self.assertRaisesRegex(ValueError, "billingKind"):
            validate_evidence(tampered_policy, valid_evidence(tampered_policy))

        numeric_chain = copy.deepcopy(evidence)
        numeric_chain["chainId"] = 314159
        with self.assertRaisesRegex(ValueError, "canonical decimal text"):
            validate_evidence(rendered, numeric_chain)

'''
text = replace_once(text, anchor, addition, "complete rendered envelope regressions")
path.write_text(text)
