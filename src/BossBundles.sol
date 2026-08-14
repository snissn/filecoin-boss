// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {BossTypes} from "./libraries/BossTypes.sol";

interface IBossBundleFactory {
    function accountKey(
        address owner,
        address filecoinPay,
        address serviceRegistry,
        address adapterRegistry,
        uint64 accountVersion
    ) external pure returns (bytes32);

    function accountFor(bytes32 accountKey_) external view returns (address account);
}

interface IBossBundleAccount {
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
}

/// @notice Immutable user-owned grouping records for subscriptions from one approved Boss factory.
/// @dev Bundles confer no account, rail, or data-access authority. `manifestHash` is an opaque,
/// unverified off-chain pointer and is not bound to `componentIds`; component events are authoritative.
contract BossBundles {
    uint256 public constant MAX_COMPONENTS = BossTypes.MAX_BUNDLE_COMPONENTS;

    error InvalidFactory();
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
    error ReentrantBundleCreation();

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

    address public immutable factory;
    mapping(bytes32 bundleId => StoredBundle bundle) private _bundles;
    bool private _creating;

    /// @dev `BossFactory` deploys this contract from its constructor, while its own runtime code is not installed yet.
    /// Account registration is authenticated against the completed factory in `_requireAccount`.
    constructor(address factory_) {
        if (factory_ == address(0)) revert InvalidFactory();
        factory = factory_;
    }

    function createBundle(address account, bytes32 manifestHash, uint64 version, bytes32[] calldata subscriptionIds)
        external
        returns (bytes32 bundleId)
    {
        if (_creating) revert ReentrantBundleCreation();
        _creating = true;
        if (manifestHash == bytes32(0)) revert InvalidManifest();
        if (version == 0) revert InvalidVersion();
        uint256 count = subscriptionIds.length;
        if (count == 0 || count > MAX_COMPONENTS) revert InvalidComponentCount(count);

        (IBossBundleAccount account_, address accountOwner) = _requireAccount(account);
        if (msg.sender != accountOwner && msg.sender != account) {
            revert UnauthorizedOwner(accountOwner, msg.sender);
        }

        BossTypes.Subscription memory first = account_.getSubscription(subscriptionIds[0]);
        if (first.state == BossTypes.SubscriptionState.NONE) revert UnknownSubscription(subscriptionIds[0]);
        bytes32 resourceKey = first.resourceKey;
        if (resourceKey == bytes32(0)) revert ResourceMismatch(bytes32(0), resourceKey);

        bundleId =
            keccak256(abi.encode("FILECOIN_BOSS_BUNDLE_V1", accountOwner, account, resourceKey, manifestHash, version));
        if (_bundles[bundleId].bundle.bundleId != bytes32(0)) revert BundleAlreadyExists(bundleId);

        for (uint256 i; i < count; ++i) {
            bytes32 subscriptionId = subscriptionIds[i];
            BossTypes.Subscription memory subscription = account_.getSubscription(subscriptionId);
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
            owner: accountOwner,
            resourceKey: resourceKey,
            manifestHash: manifestHash,
            version: version
        });
        stored.account = account;
        for (uint256 i; i < count; ++i) {
            stored.componentIds.push(subscriptionIds[i]);
            emit BundleComponentAdded(bundleId, subscriptionIds[i], i);
        }
        emit BundleCreated(bundleId, accountOwner, account, resourceKey, manifestHash, version, count);
        _creating = false;
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
        for (uint256 i = offset; i < end; ++i) {
            subscriptionIds[i - offset] = stored.componentIds[i];
        }
    }

    function _requireAccount(address account)
        private
        view
        returns (IBossBundleAccount account_, address accountOwner)
    {
        if (account == address(0) || account.code.length == 0) revert InvalidAccount();
        account_ = IBossBundleAccount(account);
        if (account_.factory() != factory) revert InvalidAccount();

        accountOwner = account_.owner();
        if (accountOwner == address(0) || account_.payer() != accountOwner) revert InvalidAccount();
        bytes32 key = IBossBundleFactory(factory).accountKey(
            accountOwner,
            account_.filecoinPay(),
            account_.serviceRegistry(),
            account_.adapterRegistry(),
            account_.accountVersion()
        );
        if (IBossBundleFactory(factory).accountFor(key) != account) revert InvalidAccount();
    }

    function _requireBundle(bytes32 bundleId) private view returns (StoredBundle storage stored) {
        stored = _bundles[bundleId];
        if (stored.bundle.bundleId == bytes32(0)) revert UnknownBundle(bundleId);
    }
}
