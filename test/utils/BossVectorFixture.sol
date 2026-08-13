// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossTypes} from "../../src/libraries/BossTypes.sol";

interface VmVectorFile {
    function readFile(string calldata path) external view returns (string memory data);
    function parseJsonAddress(string calldata json, string calldata key) external pure returns (address);
    function parseJsonBool(string calldata json, string calldata key) external pure returns (bool);
    function parseJsonBytes32(string calldata json, string calldata key) external pure returns (bytes32);
    function parseJsonString(string calldata json, string calldata key) external pure returns (string memory);
    function parseUint(string calldata stringifiedValue) external pure returns (uint256 parsedValue);
}

abstract contract BossVectorFixture {
    VmVectorFile internal constant vm =
        VmVectorFile(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant VECTOR_PATH = "test/vectors/boss-v1.json";

    function _vectorJson() internal view returns (string memory) {
        return vm.readFile(VECTOR_PATH);
    }

    function _address(string memory json, string memory path) internal view returns (address) {
        return vm.parseJsonAddress(json, path);
    }

    function _bool(string memory json, string memory path) internal view returns (bool) {
        return vm.parseJsonBool(json, path);
    }

    function _bytes32(string memory json, string memory path) internal view returns (bytes32) {
        return vm.parseJsonBytes32(json, path);
    }

    function _string(string memory json, string memory path) internal view returns (string memory) {
        return vm.parseJsonString(json, path);
    }

    function _uint(string memory json, string memory path) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, path));
    }

    function _resource(string memory json) internal view returns (BossTypes.ResourceRef memory) {
        return BossTypes.ResourceRef({
            kind: BossTypes.ResourceKind(_uint(json, ".inputs.resource.kind")),
            chainId: uint64(_uint(json, ".inputs.resource.chainId")),
            anchor: _address(json, ".inputs.resource.anchor"),
            resourceId: _uint(json, ".inputs.resource.resourceId"),
            context: _bytes32(json, ".inputs.resource.context")
        });
    }

    function _offer(string memory json) internal view returns (BossTypes.ServiceOffer memory) {
        return BossTypes.ServiceOffer({
            serviceId: _bytes32(json, ".inputs.offer.serviceId"),
            offerVersion: uint64(_uint(json, ".inputs.offer.offerVersion")),
            provider: _address(json, ".inputs.offer.provider"),
            signingKey: _address(json, ".inputs.offer.signingKey"),
            beneficiary: _address(json, ".inputs.offer.beneficiary"),
            reporter: _address(json, ".inputs.offer.reporter"),
            token: _address(json, ".inputs.offer.token"),
            resourceAdapter: _address(json, ".inputs.offer.resourceAdapter"),
            pricingAdapter: _address(json, ".inputs.offer.pricingAdapter"),
            serviceType: _bytes32(json, ".inputs.offer.serviceType"),
            billingKind: BossTypes.BillingKind(_uint(json, ".inputs.offer.billingKind")),
            assuranceKind: BossTypes.AssuranceKind(_uint(json, ".inputs.offer.assuranceKind")),
            dependencyKind: BossTypes.DependencyKind(_uint(json, ".inputs.offer.dependencyKind")),
            activationKind: BossTypes.ActivationKind(_uint(json, ".inputs.offer.activationKind")),
            terminationBillingKind: BossTypes.TerminationBillingKind(
                _uint(json, ".inputs.offer.terminationBillingKind")
            ),
            pricingDataHash: _bytes32(json, ".inputs.offer.pricingDataHash"),
            termsHash: _bytes32(json, ".inputs.offer.termsHash"),
            accessScopeHash: _bytes32(json, ".inputs.offer.accessScopeHash"),
            validAfterEpoch: uint64(_uint(json, ".inputs.offer.validAfterEpoch")),
            validUntilEpoch: uint64(_uint(json, ".inputs.offer.validUntilEpoch")),
            requiredLockupPeriod: uint64(_uint(json, ".inputs.offer.requiredLockupPeriod")),
            quoteTtlEpochs: uint64(_uint(json, ".inputs.offer.quoteTtlEpochs")),
            commissionBps: uint16(_uint(json, ".inputs.offer.commissionBps")),
            commissionRecipient: _address(json, ".inputs.offer.commissionRecipient"),
            pauseAllowed: _bool(json, ".inputs.offer.pauseAllowed"),
            providerMaxRatePerEpoch: _uint(json, ".inputs.offer.providerMaxRatePerEpoch"),
            providerMaxFixedLockup: _uint(json, ".inputs.offer.providerMaxFixedLockup"),
            nonce: _uint(json, ".inputs.offer.nonce")
        });
    }

    function _caps(string memory json) internal view returns (BossTypes.CapPolicy memory) {
        return BossTypes.CapPolicy({
            maxRatePerEpoch: _uint(json, ".inputs.caps.maxRatePerEpoch"),
            maxFixedLockup: _uint(json, ".inputs.caps.maxFixedLockup"),
            maxSingleCharge: _uint(json, ".inputs.caps.maxSingleCharge"),
            maxChargePerWindow: _uint(json, ".inputs.caps.maxChargePerWindow"),
            lifetimeCapGross: _uint(json, ".inputs.caps.lifetimeCapGross"),
            chargeWindowEpochs: uint64(_uint(json, ".inputs.caps.chargeWindowEpochs")),
            notAfterEpoch: uint64(_uint(json, ".inputs.caps.notAfterEpoch")),
            maxLockupPeriod: uint64(_uint(json, ".inputs.caps.maxLockupPeriod"))
        });
    }

    function _usageClaim(string memory json) internal view returns (BossTypes.UsageClaim memory) {
        return BossTypes.UsageClaim({
            claimId: _bytes32(json, ".inputs.usageClaim.claimId"),
            fromEpoch: uint64(_uint(json, ".inputs.usageClaim.fromEpoch")),
            toEpoch: uint64(_uint(json, ".inputs.usageClaim.toEpoch")),
            units: _uint(json, ".inputs.usageClaim.units"),
            evidenceHash: _bytes32(json, ".inputs.usageClaim.evidenceHash"),
            evidenceURI: _string(json, ".inputs.usageClaim.evidenceURI"),
            nonce: _uint(json, ".inputs.usageClaim.nonce")
        });
    }
}
