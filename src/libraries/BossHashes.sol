// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {BossTypes} from "./BossTypes.sol";

/// @notice Canonical Filecoin Boss v1 identifiers and EIP-712 struct hashes.
library BossHashes {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("Filecoin Boss");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    bytes32 internal constant SERVICE_OFFER_TYPEHASH = keccak256(
        "ServiceOffer(bytes32 serviceId,uint64 offerVersion,address provider,address signingKey,address beneficiary,address reporter,address token,address resourceAdapter,address pricingAdapter,bytes32 serviceType,uint8 billingKind,uint8 assuranceKind,uint8 dependencyKind,uint8 activationKind,uint8 terminationBillingKind,bytes32 pricingDataHash,bytes32 termsHash,bytes32 accessScopeHash,uint64 validAfterEpoch,uint64 validUntilEpoch,uint64 requiredLockupPeriod,uint64 quoteTtlEpochs,uint16 commissionBps,address commissionRecipient,bool pauseAllowed,uint256 providerMaxRatePerEpoch,uint256 providerMaxFixedLockup,uint256 nonce)"
    );

    bytes32 internal constant CAP_POLICY_TYPEHASH = keccak256(
        "CapPolicy(uint256 maxRatePerEpoch,uint256 maxFixedLockup,uint256 maxSingleCharge,uint256 maxChargePerWindow,uint256 lifetimeCapGross,uint64 chargeWindowEpochs,uint64 notAfterEpoch,uint64 maxLockupPeriod)"
    );

    bytes32 internal constant ACCEPTANCE_TYPEHASH = keccak256(
        "Acceptance(bytes32 offerHash,bytes32 resourceKey,bytes32 resourceDataHash,bytes32 pricingDataHash,bytes32 capsHash,uint256 initialFixedBudget,bytes32 accessGrantHash)"
    );

    bytes32 internal constant USAGE_CLAIM_TYPEHASH = keccak256(
        "UsageClaim(bytes32 subscriptionId,bytes32 claimId,uint64 fromEpoch,uint64 toEpoch,uint256 units,bytes32 evidenceHash,bytes32 evidenceURIHash,uint256 nonce)"
    );

    function serviceOfferTypehash() internal pure returns (bytes32) {
        return SERVICE_OFFER_TYPEHASH;
    }

    function capPolicyTypehash() internal pure returns (bytes32) {
        return CAP_POLICY_TYPEHASH;
    }

    function acceptanceTypehash() internal pure returns (bytes32) {
        return ACCEPTANCE_TYPEHASH;
    }

    function usageClaimTypehash() internal pure returns (bytes32) {
        return USAGE_CLAIM_TYPEHASH;
    }

    function hashResource(BossTypes.ResourceRef memory resource) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                "FILECOIN_BOSS_RESOURCE_V1",
                resource.kind,
                resource.chainId,
                resource.anchor,
                resource.resourceId,
                resource.context
            )
        );
    }

    function hashServiceOffer(BossTypes.ServiceOffer memory offer) internal pure returns (bytes32) {
        return keccak256(abi.encode(SERVICE_OFFER_TYPEHASH, offer));
    }

    function hashCapPolicy(BossTypes.CapPolicy memory caps) internal pure returns (bytes32) {
        return keccak256(abi.encode(CAP_POLICY_TYPEHASH, caps));
    }

    function hashAcceptance(
        bytes32 offerHash,
        bytes32 resourceKey,
        bytes32 resourceDataHash,
        bytes32 pricingDataHash,
        bytes32 capsHash,
        uint256 initialFixedBudget,
        bytes32 accessGrantHash
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ACCEPTANCE_TYPEHASH,
                offerHash,
                resourceKey,
                resourceDataHash,
                pricingDataHash,
                capsHash,
                initialFixedBudget,
                accessGrantHash
            )
        );
    }

    function hashUsageClaim(bytes32 subscriptionId, BossTypes.UsageClaim memory claim)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                USAGE_CLAIM_TYPEHASH,
                subscriptionId,
                claim.claimId,
                claim.fromEpoch,
                claim.toEpoch,
                claim.units,
                claim.evidenceHash,
                keccak256(bytes(claim.evidenceURI)),
                claim.nonce
            )
        );
    }

    function domainSeparator(uint256 chainId, address verifyingContract) internal pure returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, chainId, verifyingContract));
    }

    function hashTypedData(bytes32 domainSeparator_, bytes32 structHash) internal pure returns (bytes32 digest) {
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, shl(240, 0x1901))
            mstore(add(pointer, 0x02), domainSeparator_)
            mstore(add(pointer, 0x22), structHash)
            digest := keccak256(pointer, 0x42)
        }
    }

    function deriveSubscriptionId(address account, bytes32 offerHash, bytes32 resourceKey)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("FILECOIN_BOSS_SUBSCRIPTION_V1", account, offerHash, resourceKey));
    }
}
