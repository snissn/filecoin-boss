// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

/// @notice Canonical Boss account lifecycle event ABI shared by production contracts and reconstruction tests.
interface IBossAccountEvents {
    event SubscriptionAccepted(
        bytes32 indexed subscriptionId,
        address indexed account,
        bytes32 indexed offerHash,
        bytes32 resourceKey,
        uint256 railId,
        address beneficiary,
        address token,
        uint256 initialRate,
        uint256 initialFixedBudget
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
