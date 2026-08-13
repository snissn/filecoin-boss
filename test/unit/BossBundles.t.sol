// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossBundles} from "../../src/BossBundles.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";

contract MockBundleAccount {
    address public immutable owner;
    mapping(bytes32 => BossTypes.Subscription) private _subscriptions;

    constructor(address owner_) {
        owner = owner_;
    }

    function setSubscription(bytes32 subscriptionId, bytes32 resourceKey, uint256 railId) external {
        BossTypes.Subscription storage subscription = _subscriptions[subscriptionId];
        subscription.resourceKey = resourceKey;
        subscription.railId = railId;
        subscription.state = BossTypes.SubscriptionState.ACTIVE;
    }

    function getSubscription(bytes32 subscriptionId)
        external
        view
        returns (BossTypes.Subscription memory subscription)
    {
        return _subscriptions[subscriptionId];
    }
}

contract BossBundlesTest {
    bytes32 private constant RESOURCE = keccak256("resource");
    bytes32 private constant OTHER_RESOURCE = keccak256("other-resource");
    bytes32 private constant MANIFEST = keccak256("manifest");
    bytes32 private constant SUBSCRIPTION_A = keccak256("subscription-a");
    bytes32 private constant SUBSCRIPTION_B = keccak256("subscription-b");

    function testCreatesImmutableUserOwnedBundleAndPaginates() public {
        BossBundles bundles = new BossBundles();
        MockBundleAccount account = new MockBundleAccount(address(this));
        account.setSubscription(SUBSCRIPTION_A, RESOURCE, 1);
        account.setSubscription(SUBSCRIPTION_B, RESOURCE, 2);

        bytes32[] memory subscriptionIds = new bytes32[](2);
        subscriptionIds[0] = SUBSCRIPTION_A;
        subscriptionIds[1] = SUBSCRIPTION_B;

        bytes32 bundleId = bundles.createBundle(address(account), MANIFEST, 1, subscriptionIds);
        (BossTypes.Bundle memory bundle, address bundleAccount, uint256 componentCount) = bundles.getBundle(bundleId);

        require(bundle.bundleId == bundleId, "bundle id");
        require(bundle.owner == address(this), "bundle owner");
        require(bundle.resourceKey == RESOURCE, "bundle resource");
        require(bundle.manifestHash == MANIFEST, "bundle manifest");
        require(bundle.version == 1, "bundle version");
        require(bundleAccount == address(account), "bundle account");
        require(componentCount == 2, "component count");
        require(bundles.componentAt(bundleId, 0) == SUBSCRIPTION_A, "component zero");
        require(bundles.componentAt(bundleId, 1) == SUBSCRIPTION_B, "component one");

        bytes32[] memory first = bundles.components(bundleId, 0, 1);
        bytes32[] memory second = bundles.components(bundleId, 1, 10);
        bytes32[] memory pastEnd = bundles.components(bundleId, 2, 1);
        require(first.length == 1 && first[0] == SUBSCRIPTION_A, "first page");
        require(second.length == 1 && second[0] == SUBSCRIPTION_B, "second page");
        require(pastEnd.length == 0, "past-end page");

        _mustFail(
            address(bundles),
            abi.encodeCall(BossBundles.createBundle, (address(account), MANIFEST, 1, subscriptionIds))
        );
    }

    function testRejectsForeignAccountCrossResourceDuplicateAndOversizedBundles() public {
        BossBundles bundles = new BossBundles();
        MockBundleAccount foreignAccount = new MockBundleAccount(address(0xBEEF));
        foreignAccount.setSubscription(SUBSCRIPTION_A, RESOURCE, 1);
        bytes32[] memory one = new bytes32[](1);
        one[0] = SUBSCRIPTION_A;
        _mustFail(
            address(bundles), abi.encodeCall(BossBundles.createBundle, (address(foreignAccount), MANIFEST, 1, one))
        );

        MockBundleAccount account = new MockBundleAccount(address(this));
        account.setSubscription(SUBSCRIPTION_A, RESOURCE, 1);
        account.setSubscription(SUBSCRIPTION_B, OTHER_RESOURCE, 2);
        bytes32[] memory mixed = new bytes32[](2);
        mixed[0] = SUBSCRIPTION_A;
        mixed[1] = SUBSCRIPTION_B;
        _mustFail(address(bundles), abi.encodeCall(BossBundles.createBundle, (address(account), MANIFEST, 1, mixed)));

        account.setSubscription(SUBSCRIPTION_B, RESOURCE, 2);
        bytes32[] memory duplicate = new bytes32[](2);
        duplicate[0] = SUBSCRIPTION_A;
        duplicate[1] = SUBSCRIPTION_A;
        _mustFail(
            address(bundles), abi.encodeCall(BossBundles.createBundle, (address(account), MANIFEST, 1, duplicate))
        );

        bytes32[] memory oversized = new bytes32[](bundles.MAX_COMPONENTS() + 1);
        for (uint256 i; i < oversized.length; ++i) oversized[i] = bytes32(i + 1);
        _mustFail(
            address(bundles), abi.encodeCall(BossBundles.createBundle, (address(account), MANIFEST, 1, oversized))
        );
    }

    function testRejectsUnknownSubscriptionAndInvalidManifestOrVersion() public {
        BossBundles bundles = new BossBundles();
        MockBundleAccount account = new MockBundleAccount(address(this));
        bytes32[] memory one = new bytes32[](1);
        one[0] = SUBSCRIPTION_A;

        _mustFail(address(bundles), abi.encodeCall(BossBundles.createBundle, (address(account), MANIFEST, 1, one)));
        account.setSubscription(SUBSCRIPTION_A, RESOURCE, 1);
        _mustFail(address(bundles), abi.encodeCall(BossBundles.createBundle, (address(account), bytes32(0), 1, one)));
        _mustFail(address(bundles), abi.encodeCall(BossBundles.createBundle, (address(account), MANIFEST, 0, one)));
        _mustFail(address(bundles), abi.encodeCall(BossBundles.components, (bytes32(uint256(123)), 0, 1)));
    }

    function _mustFail(address target, bytes memory callData) private {
        (bool success,) = target.call(callData);
        require(!success, "expected failure");
    }
}
