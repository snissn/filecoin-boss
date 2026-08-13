// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossTypes} from "../../src/libraries/BossTypes.sol";
import {BossHashes} from "../../src/libraries/BossHashes.sol";

contract OfferHashingTest {
    function testServiceOfferTypehashVector() public pure {
        require(
            BossHashes.serviceOfferTypehash()
                == 0x61bf5420969c320cfb7ce504f65256abc945d0989a42c04d94c792b9ba45f830,
            "service offer typehash"
        );
    }

    function testCapPolicyTypehashVector() public pure {
        require(
            BossHashes.capPolicyTypehash()
                == 0x756a867c1261ed3605a2b661112ea5f8ee157e9c9184a885859941ac56d8cecc,
            "cap policy typehash"
        );
    }

    function testOfferAndCapHashVectors() public pure {
        BossTypes.ServiceOffer memory offer = _offer();
        BossTypes.CapPolicy memory caps = _caps();

        require(
            BossHashes.hashServiceOffer(offer)
                == 0x79a282dc16a82c88b59ba0afceb6a41a1964073787b68241da04a8054d900716,
            "offer hash"
        );
        require(
            BossHashes.hashCapPolicy(caps)
                == 0xb1a02d892b7e418b8df34c3c87238c36f0d59e203c47040ee4783a9234c97151,
            "cap hash"
        );
    }

    function testAcceptanceCommitmentVector() public pure {
        bytes32 offerHash = BossHashes.hashServiceOffer(_offer());
        bytes32 resourceKey = BossHashes.hashResource(_resource());
        bytes32 capsHash = BossHashes.hashCapPolicy(_caps());

        require(
            BossHashes.hashAcceptance(
                offerHash,
                resourceKey,
                0xf46c482831e58d08de9222eda752d1fdb1e01193fcd597d34e93d37a832eba40,
                0x2bab01bf7bf5ace39e6d17c93c5cc64dbd4bee54768b329988cd15f6621573d9,
                capsHash,
                0,
                bytes32(0)
            ) == 0x47f3729d559ae1e49b2d29a7738eaa4fa559941b8cda90af69176c4f1dccf30c,
            "acceptance hash"
        );
    }

    function testEip712OfferDigestVector() public pure {
        bytes32 domainSeparator = BossHashes.domainSeparator(
            314159,
            0x7777777777777777777777777777777777777777
        );
        bytes32 offerHash = BossHashes.hashServiceOffer(_offer());

        require(
            domainSeparator == 0x170b18a58f0508dd9afa228ec9cdcc6bc943e8cca92cda399085c305c6236298,
            "domain separator"
        );
        require(
            BossHashes.hashTypedData(domainSeparator, offerHash)
                == 0xe1760f0ab2c945ba1a364c5cf1399eb5d13876ae0953205b89ed59ab69ffc182,
            "offer digest"
        );
    }

    function testUsageClaimHashAndDigestVectors() public pure {
        bytes32 subscriptionId = 0xaccd1ea0e51657c2cdf3530b81983d215c7d39c28679fdaa63bb692298795b11;
        BossTypes.UsageClaim memory claim = BossTypes.UsageClaim({
            claimId: 0x32716d4060423b0169a8fcaec280e4cd71a68feb8e0d1bf1539fb1d254d33b5c,
            fromEpoch: 1000,
            toEpoch: 1100,
            units: 1 << 40,
            evidenceHash: 0x038702c9ab6a8a7dd47ee2cfe1088c97a003446c3965c4fbf1f85f9f9700f81a,
            evidenceURI: "ipfs://evidence/claim-1",
            nonce: 1
        });
        bytes32 claimHash = BossHashes.hashUsageClaim(subscriptionId, claim);
        bytes32 domainSeparator = BossHashes.domainSeparator(
            314159,
            0x7777777777777777777777777777777777777777
        );

        require(
            claimHash == 0x77bb1cfdde88a78d6e025654f2198b007f9271b766f05d78a75e8dadf369f7f4,
            "claim hash"
        );
        require(
            BossHashes.hashTypedData(domainSeparator, claimHash)
                == 0xc9c9a4ba9f1c8b164cf49058ab260737f48a29de6860d5b88431ca0746e92559,
            "claim digest"
        );
    }

    function _resource() private pure returns (BossTypes.ResourceRef memory) {
        return BossTypes.ResourceRef({
            kind: BossTypes.ResourceKind.FWSS_PDP_DATASET,
            chainId: 314159,
            anchor: 0x1111111111111111111111111111111111111111,
            resourceId: 42,
            context: bytes32(0)
        });
    }

    function _offer() private pure returns (BossTypes.ServiceOffer memory) {
        return BossTypes.ServiceOffer({
            serviceId: 0x658d14a92e6293d4f3f07ae2cd6eb0f83553bc332e408ceba8e226a77ada5cbd,
            offerVersion: 7,
            provider: 0x1111111111111111111111111111111111111111,
            signingKey: 0x2222222222222222222222222222222222222222,
            beneficiary: 0x3333333333333333333333333333333333333333,
            reporter: address(0),
            token: 0x4444444444444444444444444444444444444444,
            resourceAdapter: 0x5555555555555555555555555555555555555555,
            pricingAdapter: 0x6666666666666666666666666666666666666666,
            serviceType: 0x6ad4074b2bf322f30c9e731a0a75fdf837fd41c92bc15eab6b4ed5f486c63259,
            billingKind: BossTypes.BillingKind.STREAM_CAPACITY,
            assuranceKind: BossTypes.AssuranceKind.CANCELLABLE_ONLY,
            dependencyKind: BossTypes.DependencyKind.HARD,
            activationKind: BossTypes.ActivationKind.IMMEDIATE,
            terminationBillingKind: BossTypes.TerminationBillingKind.ZERO_AFTER_REQUEST,
            pricingDataHash: 0x2bab01bf7bf5ace39e6d17c93c5cc64dbd4bee54768b329988cd15f6621573d9,
            termsHash: 0x859eb08b835e7770b0e7ba9fa0896ac430b3a5dc1c8ef2d2d7d6b405a71aa552,
            accessScopeHash: bytes32(0),
            validAfterEpoch: 100,
            validUntilEpoch: 200000,
            requiredLockupPeriod: 2880,
            quoteTtlEpochs: 2880,
            commissionBps: 0,
            commissionRecipient: address(0),
            pauseAllowed: true,
            providerMaxRatePerEpoch: 1 ether,
            providerMaxFixedLockup: 2.5 ether,
            nonce: 9
        });
    }

    function _caps() private pure returns (BossTypes.CapPolicy memory) {
        return BossTypes.CapPolicy({
            maxRatePerEpoch: 11_574_074_074_074,
            maxFixedLockup: 2 ether,
            maxSingleCharge: 0,
            maxChargePerWindow: 0,
            lifetimeCapGross: 12 ether,
            chargeWindowEpochs: 0,
            notAfterEpoch: 1_234_567,
            maxLockupPeriod: 2880
        });
    }
}
