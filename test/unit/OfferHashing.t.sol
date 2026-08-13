// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossHashes} from "../../src/libraries/BossHashes.sol";
import {BossVectorFixture} from "../utils/BossVectorFixture.sol";

contract OfferHashingTest is BossVectorFixture {
    function testCanonicalTypeStringsAndTypehashes() public view {
        string memory json = _vectorJson();

        require(
            keccak256(bytes(_string(json, ".types.ServiceOffer.canonical"))) == BossHashes.serviceOfferTypehash(),
            "service offer canonical type"
        );
        require(
            BossHashes.serviceOfferTypehash() == _bytes32(json, ".types.ServiceOffer.typeHash"),
            "service offer typehash"
        );
        require(
            keccak256(bytes(_string(json, ".types.CapPolicy.canonical"))) == BossHashes.capPolicyTypehash(),
            "cap policy canonical type"
        );
        require(
            BossHashes.capPolicyTypehash() == _bytes32(json, ".types.CapPolicy.typeHash"),
            "cap policy typehash"
        );
        require(
            keccak256(bytes(_string(json, ".types.Acceptance.canonical"))) == BossHashes.acceptanceTypehash(),
            "acceptance canonical type"
        );
        require(
            BossHashes.acceptanceTypehash() == _bytes32(json, ".types.Acceptance.typeHash"),
            "acceptance typehash"
        );
        require(
            keccak256(bytes(_string(json, ".types.UsageClaim.canonical"))) == BossHashes.usageClaimTypehash(),
            "usage claim canonical type"
        );
        require(
            BossHashes.usageClaimTypehash() == _bytes32(json, ".types.UsageClaim.typeHash"),
            "usage claim typehash"
        );
    }

    function testOfferAndCapHashVectors() public view {
        string memory json = _vectorJson();

        require(BossHashes.hashServiceOffer(_offer(json)) == _bytes32(json, ".vectors.serviceOfferHash"), "offer hash");
        require(BossHashes.hashCapPolicy(_caps(json)) == _bytes32(json, ".vectors.capPolicyHash"), "cap hash");
    }

    function testAcceptanceCommitmentVector() public view {
        string memory json = _vectorJson();
        bytes32 offerHash = BossHashes.hashServiceOffer(_offer(json));
        bytes32 resourceKey = BossHashes.hashResource(_resource(json));
        bytes32 capsHash = BossHashes.hashCapPolicy(_caps(json));

        require(
            BossHashes.hashAcceptance(
                offerHash,
                resourceKey,
                _bytes32(json, ".inputs.acceptance.resourceDataHash"),
                _bytes32(json, ".inputs.acceptance.pricingDataHash"),
                capsHash,
                _uint(json, ".inputs.acceptance.initialFixedBudget"),
                _bytes32(json, ".inputs.acceptance.accessGrantHash")
            ) == _bytes32(json, ".vectors.acceptanceHash"),
            "acceptance hash"
        );
    }

    function testEip712OfferDigestVector() public view {
        string memory json = _vectorJson();
        bytes32 domainSeparator = BossHashes.domainSeparator(
            _uint(json, ".domain.chainId"), _address(json, ".domain.verifyingContract")
        );
        bytes32 offerHash = BossHashes.hashServiceOffer(_offer(json));

        require(domainSeparator == _bytes32(json, ".vectors.domainSeparator"), "domain separator");
        require(
            BossHashes.hashTypedData(domainSeparator, offerHash) == _bytes32(json, ".vectors.offerDigest"),
            "offer digest"
        );
    }

    function testUsageClaimHashAndDigestVectors() public view {
        string memory json = _vectorJson();
        bytes32 offerHash = BossHashes.hashServiceOffer(_offer(json));
        bytes32 resourceKey = BossHashes.hashResource(_resource(json));
        bytes32 subscriptionId = BossHashes.deriveSubscriptionId(
            _address(json, ".inputs.subscription.account"), offerHash, resourceKey
        );
        bytes32 claimHash = BossHashes.hashUsageClaim(subscriptionId, _usageClaim(json));
        bytes32 domainSeparator = BossHashes.domainSeparator(
            _uint(json, ".domain.chainId"), _address(json, ".domain.verifyingContract")
        );

        require(subscriptionId == _bytes32(json, ".vectors.subscriptionId"), "subscription id");
        require(claimHash == _bytes32(json, ".vectors.usageClaimHash"), "claim hash");
        require(
            BossHashes.hashTypedData(domainSeparator, claimHash) == _bytes32(json, ".vectors.usageClaimDigest"),
            "claim digest"
        );
    }
}
