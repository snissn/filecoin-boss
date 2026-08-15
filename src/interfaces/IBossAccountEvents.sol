// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

/// @notice Canonical Boss account lifecycle event ABI shared by production contracts and reconstruction tests.
interface IBossAccountEvents {
    /// @notice Complete accepted subscription terms, reconstructable without a later state read.
    /// @dev `policyWord`: billing, assurance, dependency, activation, and termination kinds in
    /// successive 8-bit lanes from bit 0; pauseAllowed at bit 40.
    /// `capEpochs`: chargeWindowEpochs, notAfterEpoch, maxLockupPeriod in successive 64-bit lanes.
    /// `acceptanceEpochs`: acceptedEpoch, quoteValidThroughEpoch, quoteTtlEpochs in 64-bit lanes.
    event SubscriptionAccepted(
        bytes32 indexed subscriptionId,
        address indexed account,
        bytes32 indexed offerHash,
        bytes32 resourceKey,
        uint256 railId,
        address beneficiary,
        address token,
        uint256 initialFixedBudget,
        address provider,
        address reporter,
        address resourceAdapter,
        address pricingAdapter,
        bytes32 resourceDataHash,
        bytes32 pricingDataHash,
        bytes32 accessGrantHash,
        uint256 policyWord,
        uint256 maxRatePerEpoch,
        uint256 maxFixedLockup,
        uint256 maxSingleCharge,
        uint256 maxChargePerWindow,
        uint256 lifetimeCapGross,
        uint256 capEpochs,
        uint256 acceptedRatePerEpoch,
        uint256 acceptanceEpochs
    );
    event ProviderActivationAcknowledged(bytes32 indexed subscriptionId, bytes32 provisioningHash);
    event SubscriptionActivated(bytes32 indexed subscriptionId, uint64 activatedEpoch);
    event RateSynchronized(
        bytes32 indexed subscriptionId,
        uint256 oldRate,
        uint256 newRate,
        uint64 quoteEpoch,
        uint64 validThroughEpoch,
        bytes32 resourceStatusHash
    );
    event SubscriptionPaused(bytes32 indexed subscriptionId, uint64 pausedEpoch);
    event PauseRateUpdateDeferred(bytes32 indexed subscriptionId, bytes reason);
    event SubscriptionResumed(bytes32 indexed subscriptionId, uint64 resumedEpoch);
    event SubscriptionTerminationRequested(bytes32 indexed subscriptionId, uint64 requestEpoch);
    event SubscriptionPayTerminationObserved(bytes32 indexed subscriptionId, uint256 indexed railId, uint256 endEpoch);
    event SubscriptionEnded(bytes32 indexed subscriptionId, uint64 endedEpoch);
    event AccessGrantCommitted(bytes32 indexed subscriptionId, bytes32 accessGrantHash);
    event UsageClaimCharged(
        bytes32 indexed subscriptionId,
        bytes32 indexed claimId,
        bytes32 claimHash,
        uint256 units,
        uint256 rawGross,
        uint256 chargedGross,
        bytes32 evidenceHash
    );
    event FixedBudgetToppedUp(bytes32 indexed subscriptionId, uint256 oldBudget, uint256 newBudget);
}
