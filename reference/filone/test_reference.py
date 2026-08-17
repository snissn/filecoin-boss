import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from reference import document_sha256, load_product, quote_rate_per_epoch, render_offer, validate_evidence

ADDRESS = lambda digit: f"0x{digit * 40}"
HASH = lambda digit: f"0x{digit * 64}"

CONFIG = {
    "chainId": 314159,
    "provider": ADDRESS("1"),
    "signingKey": ADDRESS("2"),
    "beneficiary": ADDRESS("3"),
    "token": ADDRESS("4"),
    "resourceAdapter": ADDRESS("5"),
    "pricingAdapter": ADDRESS("6"),
    "offerVersion": 1,
    "validAfterEpoch": 100,
    "validUntilEpoch": 200000,
    "nonce": 7,
    "providerMaxRatePerEpoch": "1000000000000000000",
}

TRANSACTION_STAGES = (
    "fund",
    "approveOperator",
    "createAccount",
    "acceptOffer",
    "syncRate",
    "settle",
    "pause",
    "terminate",
)
OBSERVATION_STAGES = (
    "deployment",
    "bossState",
    "payRail",
    "baseFwss",
    "subgraph",
    "synapseSdk",
    "filecoinPin",
    "explorer",
)


def valid_evidence(rendered):
    transactions = {}
    for index, stage in enumerate(TRANSACTION_STAGES, 1):
        transaction_hash = HASH(format(index % 16, "x"))
        transactions[stage] = {
            "transactionHash": transaction_hash,
            "from": ADDRESS("a"),
            "to": ADDRESS("b"),
            "receipt": {
                "transactionHash": transaction_hash,
                "blockNumber": 1000 + index,
                "status": 1,
            },
        }

    observations = {
        stage: {
            "artifactSha256": format(index, "064x"),
            "assertions": [f"{stage}-checked"],
        }
        for index, stage in enumerate(OBSERVATION_STAGES, 1)
    }
    return {
        "schemaVersion": 1,
        "productId": "filone-managed-storage-v1",
        "chainId": rendered["chainId"],
        "renderedOfferSha256": document_sha256(rendered),
        "deploymentManifestSha256": "f" * 64,
        "transactions": transactions,
        "observations": observations,
    }


class FiloneReferenceTest(unittest.TestCase):
    def setUp(self):
        self.product = load_product(HERE / "product.json")
        self.terms = (HERE / "terms.md").read_bytes()

    def test_fixed_product_and_capacity_vectors(self):
        self.assertEqual(self.product["productId"], "filone-managed-storage-v1")
        self.assertEqual(self.product["billingKind"], "STREAM_CAPACITY")
        self.assertEqual(self.product["assuranceKind"], "CANCELLABLE_ONLY")
        self.assertEqual(self.product["dataAccess"], "NONE")
        self.assertEqual(self.product["baseStorage"], "UNCHANGED_FWSS_RAIL")
        self.assertEqual(quote_rate_per_epoch(self.product, 1 << 40), 28_819_444_444_444)
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

    def test_product_policy_pins_numeric_v1_terms(self):
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

    def test_rendered_offer_binds_exact_terms_pricing_and_authority(self):
        rendered = render_offer(self.product, self.terms, CONFIG)
        offer = rendered["serviceOffer"]
        self.assertEqual(rendered["productId"], "filone-managed-storage-v1")
        self.assertEqual(rendered["chainId"], "314159")
        self.assertEqual(offer["billingKind"], 1)
        self.assertEqual(offer["assuranceKind"], 0)
        self.assertEqual(offer["activationKind"], 0)
        for field in (
            "offerVersion",
            "validAfterEpoch",
            "validUntilEpoch",
            "requiredLockupPeriod",
            "quoteTtlEpochs",
            "commissionBps",
            "providerMaxRatePerEpoch",
            "providerMaxFixedLockup",
            "nonce",
        ):
            self.assertRegex(offer[field], r"^[0-9]+$")
        self.assertEqual(offer["reporter"], ADDRESS("0"))
        self.assertEqual(offer["providerMaxFixedLockup"], "0")
        self.assertRegex(rendered["pricingData"], r"^0x[0-9a-f]{128}$")
        for field in ("serviceId", "serviceType", "pricingDataHash", "termsHash"):
            self.assertRegex(offer[field], r"^0x[0-9a-f]{64}$")

        max_chain = dict(CONFIG)
        max_chain["chainId"] = (1 << 64) - 1
        self.assertEqual(render_offer(self.product, self.terms, max_chain)["chainId"], "18446744073709551615")

        too_large = dict(CONFIG)
        too_large["validUntilEpoch"] = 1 << 64
        with self.assertRaisesRegex(ValueError, "uint64"):
            render_offer(self.product, self.terms, too_large)

        bad = dict(CONFIG)
        bad["beneficiary"] = ADDRESS("0")
        with self.assertRaisesRegex(ValueError, "beneficiary"):
            render_offer(self.product, self.terms, bad)

    def test_evidence_requires_canonical_text_chain_id(self):
        rendered = render_offer(self.product, self.terms, CONFIG)
        evidence = valid_evidence(rendered)

        numeric = copy.deepcopy(evidence)
        numeric["chainId"] = 314159
        with self.assertRaisesRegex(ValueError, "chainId"):
            validate_evidence(rendered, numeric)

        leading_zero = copy.deepcopy(evidence)
        leading_zero["chainId"] = "0314159"
        with self.assertRaisesRegex(ValueError, "chainId"):
            validate_evidence(rendered, leading_zero)

    def test_evidence_rejects_incomplete_or_tampered_rendered_offer(self):
        incomplete = {"productId": "filone-managed-storage-v1", "chainId": 314159}
        with self.assertRaisesRegex(ValueError, "rendered"):
            validate_evidence(incomplete, valid_evidence(incomplete))

        rendered = render_offer(self.product, self.terms, CONFIG)
        for label, mutate in (
            (
                "pricingData",
                lambda value: value.__setitem__("pricingData", "0x" + "00" * 64),
            ),
            (
                "billingKind",
                lambda value: value["serviceOffer"].__setitem__("billingKind", 2),
            ),
            (
                "termsHash",
                lambda value: value["serviceOffer"].__setitem__("termsHash", HASH("e")),
            ),
        ):
            tampered = copy.deepcopy(rendered)
            mutate(tampered)
            with self.subTest(label=label):
                with self.assertRaisesRegex(ValueError, label):
                    validate_evidence(tampered, valid_evidence(tampered))

    def test_evidence_is_fail_closed_and_never_self_authorizes_release(self):
        rendered = render_offer(self.product, self.terms, CONFIG)
        evidence = valid_evidence(rendered)
        result = validate_evidence(rendered, evidence)
        self.assertEqual(
            result,
            {
                "eligibleForIndependentVerification": True,
                "requiresIndependentRpcVerification": True,
                "releaseClaimAuthorized": False,
            },
        )

        boolean_schema = copy.deepcopy(evidence)
        boolean_schema["schemaVersion"] = True
        with self.assertRaisesRegex(ValueError, "schemaVersion"):
            validate_evidence(rendered, boolean_schema)

        boolean_status = copy.deepcopy(evidence)
        boolean_status["transactions"]["acceptOffer"]["receipt"]["status"] = True
        with self.assertRaisesRegex(ValueError, "receipt status"):
            validate_evidence(rendered, boolean_status)

        mismatch = copy.deepcopy(evidence)
        mismatch["transactions"]["acceptOffer"]["receipt"]["transactionHash"] = HASH("e")
        with self.assertRaisesRegex(ValueError, "acceptOffer"):
            validate_evidence(rendered, mismatch)

        impossible_activation = copy.deepcopy(evidence)
        impossible_activation["transactions"]["activate"] = copy.deepcopy(
            impossible_activation["transactions"]["acceptOffer"]
        )
        with self.assertRaisesRegex(ValueError, "activate"):
            validate_evidence(rendered, impossible_activation)

        unknown = copy.deepcopy(evidence)
        unknown["unexpected"] = True
        with self.assertRaisesRegex(ValueError, "unexpected"):
            validate_evidence(rendered, unknown)

        missing = copy.deepcopy(evidence)
        del missing["observations"]["explorer"]
        with self.assertRaisesRegex(ValueError, "explorer"):
            validate_evidence(rendered, missing)


if __name__ == "__main__":
    unittest.main()
