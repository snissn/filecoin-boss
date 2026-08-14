// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {BossAdapterRegistry} from "./BossAdapterRegistry.sol";
import {IBossPricingAdapter} from "./interfaces/IBossPricingAdapter.sol";
import {IBossResourceAdapter} from "./interfaces/IBossResourceAdapter.sol";
import {IFilecoinPayV1} from "./interfaces/IFilecoinPayV1.sol";
import {BossHashes} from "./libraries/BossHashes.sol";
import {BossTypes} from "./libraries/BossTypes.sol";

interface IBossAccountRead {
    function owner() external view returns (address);
    function payer() external view returns (address);
    function filecoinPay() external view returns (address);
    function serviceRegistry() external view returns (address);
    function adapterRegistry() external view returns (address);
    function factory() external view returns (address);
    function accountVersion() external view returns (uint64);

    function getSubscription(bytes32 subscriptionId)
        external
        view
        returns (BossTypes.Subscription memory subscription);

    function subscriptionForRail(uint256 railId) external view returns (bytes32);
    function activationAcknowledged(bytes32 subscriptionId) external view returns (bool);

    function usageClaimState(bytes32 subscriptionId, bytes32 claimId, uint256 window)
        external
        view
        returns (bool claimConsumed, uint256 windowGross);
}

/// @notice Stateless bounded read model for Boss accounts, subscriptions, resources, quotes, and Pay rails.
contract BossStateView {
    uint256 public constant MAX_BATCH = 32;

    error InvalidAccount();
    error InvalidBatch(uint256 count);
    error UnknownSubscription(bytes32 subscriptionId);
    error ResourceMismatch();
    error ResourceDataMismatch();
    error PricingDataMismatch();
    error AdapterCodeMismatch(address adapter);

    struct AccountSnapshot {
        address owner;
        address payer;
        address filecoinPay;
        address serviceRegistry;
        address adapterRegistry;
        address factory;
        uint64 accountVersion;
    }

    struct SubscriptionSnapshot {
        bool exists;
        bytes32 subscriptionId;
        BossTypes.Subscription subscription;
        IFilecoinPayV1.RailView rail;
        bool activationAcknowledged;
        bool railAssociationValid;
        uint256 grossSpent;
        uint256 remainingLifetimeGross;
    }

    struct QuoteSnapshot {
        BossTypes.ResourceStatus resource;
        BossTypes.RateQuote quote;
    }

    struct ClaimSnapshot {
        bool subscriptionExists;
        bool windowValid;
        bytes32 subscriptionId;
        bytes32 claimHash;
        bytes32 digest;
        address reporter;
        bool claimConsumed;
        uint256 window;
        uint256 windowGross;
        uint256 remainingWindowGross;
        uint256 remainingLifetimeGross;
    }

    function account(address accountAddress) external view returns (AccountSnapshot memory snapshot) {
        IBossAccountRead account_ = _account(accountAddress);
        snapshot = AccountSnapshot({
            owner: account_.owner(),
            payer: account_.payer(),
            filecoinPay: account_.filecoinPay(),
            serviceRegistry: account_.serviceRegistry(),
            adapterRegistry: account_.adapterRegistry(),
            factory: account_.factory(),
            accountVersion: account_.accountVersion()
        });
    }

    function subscription(address accountAddress, bytes32 subscriptionId)
        external
        view
        returns (SubscriptionSnapshot memory snapshot)
    {
        return _subscription(_account(accountAddress), accountAddress, subscriptionId);
    }

    function subscriptions(address accountAddress, bytes32[] calldata subscriptionIds)
        external
        view
        returns (SubscriptionSnapshot[] memory snapshots)
    {
        uint256 count = subscriptionIds.length;
        if (count == 0 || count > MAX_BATCH) revert InvalidBatch(count);
        IBossAccountRead account_ = _account(accountAddress);
        snapshots = new SubscriptionSnapshot[](count);
        for (uint256 i; i < count; ++i) {
            snapshots[i] = _subscription(account_, accountAddress, subscriptionIds[i]);
        }
    }

    function quote(
        address accountAddress,
        bytes32 subscriptionId,
        BossTypes.ResourceRef calldata resource,
        bytes calldata resourceData,
        bytes calldata pricingData
    ) external view returns (QuoteSnapshot memory snapshot) {
        IBossAccountRead account_ = _account(accountAddress);
        BossTypes.Subscription memory subscription_ = account_.getSubscription(subscriptionId);
        if (subscription_.state == BossTypes.SubscriptionState.NONE) revert UnknownSubscription(subscriptionId);
        if (BossHashes.hashResource(resource) != subscription_.resourceKey) revert ResourceMismatch();
        if (keccak256(resourceData) != subscription_.resourceDataHash) revert ResourceDataMismatch();
        if (keccak256(pricingData) != subscription_.pricingDataHash) revert PricingDataMismatch();

        address registryAddress = account_.adapterRegistry();
        _requirePinnedAdapter(registryAddress, subscription_.resourceAdapter, BossTypes.AdapterKind.RESOURCE);
        _requirePinnedAdapter(registryAddress, subscription_.pricingAdapter, BossTypes.AdapterKind.PRICING);

        snapshot.resource =
            IBossResourceAdapter(subscription_.resourceAdapter).inspect(resource, account_.payer(), resourceData);
        if (snapshot.resource.resourceKey != subscription_.resourceKey) revert ResourceMismatch();
        snapshot.quote = IBossPricingAdapter(subscription_.pricingAdapter).quoteRate(snapshot.resource, pricingData);
    }

    function claim(address accountAddress, bytes32 subscriptionId, BossTypes.UsageClaim calldata usageClaim)
        external
        view
        returns (ClaimSnapshot memory snapshot)
    {
        IBossAccountRead account_ = _account(accountAddress);
        BossTypes.Subscription memory subscription_ = account_.getSubscription(subscriptionId);
        snapshot.subscriptionId = subscriptionId;
        if (subscription_.state == BossTypes.SubscriptionState.NONE) return snapshot;

        snapshot.subscriptionExists = true;
        snapshot.claimHash = BossHashes.hashUsageClaim(subscriptionId, usageClaim);
        snapshot.digest =
            BossHashes.hashTypedData(BossHashes.domainSeparator(block.chainid, accountAddress), snapshot.claimHash);
        snapshot.reporter = subscription_.reporter;
        uint256 grossSpent = subscription_.settledGross + subscription_.oneTimeChargedGross;
        snapshot.remainingLifetimeGross = BossTypes.remainingCap(subscription_.caps.lifetimeCapGross, grossSpent);

        uint256 windowSize = subscription_.caps.chargeWindowEpochs;
        if (
            windowSize == 0 || usageClaim.toEpoch <= usageClaim.fromEpoch
                || usageClaim.fromEpoch < subscription_.acceptedEpoch
        ) return snapshot;

        uint256 startWindow = (uint256(usageClaim.fromEpoch) - subscription_.acceptedEpoch) / windowSize;
        uint256 endWindow = (uint256(usageClaim.toEpoch) - 1 - subscription_.acceptedEpoch) / windowSize;
        if (startWindow != endWindow) return snapshot;

        snapshot.windowValid = true;
        snapshot.window = startWindow;
        (snapshot.claimConsumed, snapshot.windowGross) =
            account_.usageClaimState(subscriptionId, usageClaim.claimId, startWindow);
        snapshot.remainingWindowGross =
            BossTypes.remainingCap(subscription_.caps.maxChargePerWindow, snapshot.windowGross);
    }

    function _subscription(IBossAccountRead account_, address accountAddress, bytes32 subscriptionId)
        private
        view
        returns (SubscriptionSnapshot memory snapshot)
    {
        snapshot.subscriptionId = subscriptionId;
        snapshot.subscription = account_.getSubscription(subscriptionId);
        if (snapshot.subscription.state == BossTypes.SubscriptionState.NONE) return snapshot;

        snapshot.exists = true;
        snapshot.activationAcknowledged = account_.activationAcknowledged(subscriptionId);
        snapshot.grossSpent = snapshot.subscription.settledGross + snapshot.subscription.oneTimeChargedGross;
        snapshot.remainingLifetimeGross =
            BossTypes.remainingCap(snapshot.subscription.caps.lifetimeCapGross, snapshot.grossSpent);
        snapshot.rail = IFilecoinPayV1(account_.filecoinPay()).getRail(snapshot.subscription.railId);
        snapshot.railAssociationValid = account_.subscriptionForRail(snapshot.subscription.railId) == subscriptionId
            && snapshot.rail.from == account_.payer() && snapshot.rail.to == snapshot.subscription.beneficiary
            && snapshot.rail.operator == accountAddress && snapshot.rail.validator == accountAddress
            && snapshot.rail.token == snapshot.subscription.token;
    }

    function _account(address accountAddress) private view returns (IBossAccountRead account_) {
        if (accountAddress == address(0) || accountAddress.code.length == 0) revert InvalidAccount();
        account_ = IBossAccountRead(accountAddress);
    }

    function _requirePinnedAdapter(address registryAddress, address adapter, BossTypes.AdapterKind kind) private view {
        BossTypes.AdapterRecord memory record = BossAdapterRegistry(registryAddress).getAdapter(adapter);
        if (
            record.kind != kind || record.interfaceVersion != 1 || record.codeHash == bytes32(0)
                || adapter.code.length == 0 || adapter.codehash != record.codeHash
        ) revert AdapterCodeMismatch(adapter);
    }
}
