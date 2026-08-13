// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {BossTypes} from "./libraries/BossTypes.sol";

interface IBossBundleAccount {
    function owner() external view returns (address);

    function getSubscription(bytes32 subscriptionId)
        external
        view
        returns (BossTypes.Subscription memory subscription);
}

/// @notice Immutable user-owned grouping records for existing Boss subscriptions.
/// @dev Bundles confer no account, rail, or data-access authority.
contract BossBundles {
    uint256 public constant MAX_COMPONENTS = 32;

    error InvalidAccount();
    error InvalidManifest();
    error InvalidVersion();
    error InvalidComponentCount(uint256 count);
    error UnauthorizedOwner(address expected, address caller);
    error UnknownSubscription(bytes32 subscriptionId);
    error ResourceMismatch(bytes32 expected, bytes32 observed);
    error DuplicateComponent(bytes32 subscriptionId);
    error BundleAlreadyExists(bytes32 bundleId);
    error UnknownBundle(bytes32 bundleId);
    error InvalidPage(uint256 limit);
    error InvalidComponentIndex(uint256 index);

    event BundleCreated(
        bytes32 indexed bundleId,
        address indexed owner,
        address indexed account,
        bytes32 resourceKey,
        bytes32 manifestHash,
        uint64 version,
        uint256 componentCount
    );
    event BundleComponentAdded(bytes32 indexed bundleId, bytes32 indexed subscriptionId, uint256 index);

    struct StoredBundle {
        BossTypes.Bundle bundle;
        address account;
        bytes32[] componentIds;
    }

    mapping(bytes32 bundleId => StoredBundle bundle) private _bundles;

    function createBundle(
        address account,
        bytes32 manifestHash,
        uint64 version,
        bytes32[] calldata subscriptionIds
    ) external returns (bytes32 bundleId) {
        if (account == address(0) || account.code.length == 0) revert InvalidAccount();
        if (manifestHash == bytes32(0)) revert InvalidManifest();
        if (version == 0) revert InvalidVersion();
        uint256 count = subscriptionIds.length;
        if (count == 0 || count > MAX_COMPONENTS) revert InvalidComponentCount(count);

        address accountOwner = IBossBundleAccount(account).owner();
        if (accountOwner != msg.sender) revert UnauthorizedOwner(accountOwner, msg.sender);

        BossTypes.Subscription memory first = IBossBundleAccount(account).getSubscription(subscriptionIds[0]);
        if (first.state == BossTypes.SubscriptionState.NONE) revert UnknownSubscription(subscriptionIds[0]);
        bytes32 resourceKey = first.resourceKey;
        if (resourceKey == bytes32(0)) revert ResourceMismatch(bytes32(0), resourceKey);

        bundleId = keccak256(
            abi.encode("FILECOIN_BOSS_BUNDLE_V1", msg.sender, account, resourceKey, manifestHash, version)
        );
        if (_bundles[bundleId].bundle.bundleId != bytes32(0)) revert BundleAlreadyExists(bundleId);

        for (uint256 i; i < count; ++i) {
            bytes32 subscriptionId = subscriptionIds[i];
            BossTypes.Subscription memory subscription =
                IBossBundleAccount(account).getSubscription(subscriptionId);
            if (subscription.state == BossTypes.SubscriptionState.NONE) revert UnknownSubscription(subscriptionId);
            if (subscription.resourceKey != resourceKey) {
                revert ResourceMismatch(resourceKey, subscription.resourceKey);
            }
            // ponytail: O(n²) duplicate detection is bounded by MAX_COMPONENTS=32 and avoids another storage index.
            for (uint256 j; j < i; ++j) {
                if (subscriptionIds[j] == subscriptionId) revert DuplicateComponent(subscriptionId);
            }
        }

        StoredBundle storage stored = _bundles[bundleId];
        stored.bundle = BossTypes.Bundle({
            bundleId: bundleId,
            owner: msg.sender,
            resourceKey: resourceKey,
            manifestHash: manifestHash,
            version: version
        });
        stored.account = account;
        for (uint256 i; i < count; ++i) {
            stored.componentIds.push(subscriptionIds[i]);
            emit BundleComponentAdded(bundleId, subscriptionIds[i], i);
        }
        emit BundleCreated(bundleId, msg.sender, account, resourceKey, manifestHash, version, count);
    }

    function getBundle(bytes32 bundleId)
        external
        view
        returns (BossTypes.Bundle memory bundle, address account, uint256 componentCount)
    {
        StoredBundle storage stored = _requireBundle(bundleId);
        return (stored.bundle, stored.account, stored.componentIds.length);
    }

    function componentAt(bytes32 bundleId, uint256 index) external view returns (bytes32 subscriptionId) {
        StoredBundle storage stored = _requireBundle(bundleId);
        if (index >= stored.componentIds.length) revert InvalidComponentIndex(index);
        return stored.componentIds[index];
    }

    function components(bytes32 bundleId, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory subscriptionIds)
    {
        if (limit == 0 || limit > MAX_COMPONENTS) revert InvalidPage(limit);
        StoredBundle storage stored = _requireBundle(bundleId);
        uint256 count = stored.componentIds.length;
        if (offset >= count) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > count) end = count;
        subscriptionIds = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; ++i) subscriptionIds[i - offset] = stored.componentIds[i];
    }

    function _requireBundle(bytes32 bundleId) private view returns (StoredBundle storage stored) {
        stored = _bundles[bundleId];
        if (stored.bundle.bundleId == bytes32(0)) revert UnknownBundle(bundleId);
    }
}
