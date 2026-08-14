// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossBundles} from "../../src/BossBundles.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";
import {MockBundleAccount} from "../mocks/MockBundleAccount.sol";
import {RevertAssertions} from "../utils/RevertAssertions.sol";

contract BossBundlesTest is RevertAssertions {
    bytes32 private constant RESOURCE = keccak256("resource");
    bytes32 private constant OTHER_RESOURCE = keccak256("other-resource");
    bytes32 private constant MANIFEST = keccak256("manifest");
    bytes32 private constant SUBSCRIPTION_A = keccak256("subscription-a");
    bytes32 private constant SUBSCRIPTION_B = keccak256("subscription-b");

    function testCreatesImmutableUserOwnedBundleAndPaginates() public {
        BossBundles bundles = new BossBundles();
        MockBundleAccount account = _accountWithTwoSubscriptions();
        bytes32[] memory subscriptionIds = _pair(SUBSCRIPTION_A, SUBSCRIPTION_B);

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

        uint256 gasBefore = gasleft();
        bytes32[] memory first = bundles.components(bundleId, 0, 1);
        uint256 pageGas = gasBefore - gasleft();
        bytes32[] memory second = bundles.components(bundleId, 1, 10);
        bytes32[] memory pastEnd = bundles.components(bundleId, 2, 1);
        require(first.length == 1 && first[0] == SUBSCRIPTION_A, "first page");
        require(second.length == 1 && second[0] == SUBSCRIPTION_B, "second page");
        require(pastEnd.length == 0, "past-end page");
        require(pageGas < 150_000, "bundle page gas");

        _mustRevertWith(
            address(bundles),
            abi.encodeCall(BossBundles.createBundle, (address(account), MANIFEST, 1, subscriptionIds)),
            BossBundles.BundleAlreadyExists.selector
        );
    }

    function testPaginationRejectsInvalidLimitsAndCoversExactMaximum() public {
        BossBundles bundles = new BossBundles();
        MockBundleAccount account = new MockBundleAccount(address(this));
        uint256 maximum = bundles.MAX_COMPONENTS();
        bytes32[] memory subscriptionIds = new bytes32[](maximum);
        for (uint256 i; i < maximum; ++i) {
            bytes32 subscriptionId = bytes32(i + 1);
            subscriptionIds[i] = subscriptionId;
            account.setSubscription(subscriptionId, RESOURCE, i + 1);
        }

        bytes32 bundleId = bundles.createBundle(address(account), MANIFEST, 1, subscriptionIds);
        bytes32[] memory full = bundles.components(bundleId, 0, maximum);
        bytes32[] memory finalPage = bundles.components(bundleId, maximum - 1, maximum);
        require(full.length == maximum, "maximum page length");
        require(full[0] == bytes32(uint256(1)) && full[maximum - 1] == bytes32(maximum), "maximum page values");
        require(finalPage.length == 1 && finalPage[0] == bytes32(maximum), "final boundary page");

        _mustRevertWith(
            address(bundles), abi.encodeCall(BossBundles.components, (bundleId, 0, 0)), BossBundles.InvalidPage.selector
        );
        _mustRevertWith(
            address(bundles),
            abi.encodeCall(BossBundles.components, (bundleId, 0, maximum + 1)),
            BossBundles.InvalidPage.selector
        );
    }

    function testRejectsForeignAccountCrossResourceDuplicateAndOversizedBundles() public {
        BossBundles bundles = new BossBundles();
        MockBundleAccount foreignAccount = new MockBundleAccount(address(0xBEEF));
        foreignAccount.setSubscription(SUBSCRIPTION_A, RESOURCE, 1);
        bytes32[] memory one = _single(SUBSCRIPTION_A);
        _mustRevertWith(
            address(bundles),
            abi.encodeCall(BossBundles.createBundle, (address(foreignAccount), MANIFEST, 1, one)),
            BossBundles.UnauthorizedOwner.selector
        );

        MockBundleAccount account = new MockBundleAccount(address(this));
        account.setSubscription(SUBSCRIPTION_A, RESOURCE, 1);
        account.setSubscription(SUBSCRIPTION_B, OTHER_RESOURCE, 2);
        bytes32[] memory mixed = _pair(SUBSCRIPTION_A, SUBSCRIPTION_B);
        _mustRevertWith(
            address(bundles),
            abi.encodeCall(BossBundles.createBundle, (address(account), MANIFEST, 1, mixed)),
            BossBundles.ResourceMismatch.selector
        );

        account.setSubscription(SUBSCRIPTION_B, RESOURCE, 2);
        bytes32[] memory duplicate = _pair(SUBSCRIPTION_A, SUBSCRIPTION_A);
        _mustRevertWith(
            address(bundles),
            abi.encodeCall(BossBundles.createBundle, (address(account), MANIFEST, 1, duplicate)),
            BossBundles.DuplicateComponent.selector
        );

        bytes32[] memory oversized = new bytes32[](bundles.MAX_COMPONENTS() + 1);
        _mustRevertWith(
            address(bundles),
            abi.encodeCall(BossBundles.createBundle, (address(account), MANIFEST, 1, oversized)),
            BossBundles.InvalidComponentCount.selector
        );
    }

    function testBundleUsesOnlyReadSelectorsAndCannotMutateSubscriptionOrRailAuthority() public {
        BossBundles bundles = new BossBundles();
        MockBundleAccount account = new MockBundleAccount(address(this));
        account.setSubscription(SUBSCRIPTION_A, RESOURCE, 77);
        bytes32 bundleId = bundles.createBundle(address(account), MANIFEST, 1, _single(SUBSCRIPTION_A));

        // MockBundleAccount's fallback rejects every selector other than owner/getSubscription.
        // Successful creation therefore proves the bundle path used no mutation or execution call.
        BossTypes.Subscription memory subscription = account.getSubscription(SUBSCRIPTION_A);
        require(subscription.resourceKey == RESOURCE, "bundle changed resource");
        require(subscription.railId == 77, "bundle changed rail");
        require(subscription.state == BossTypes.SubscriptionState.ACTIVE, "bundle changed lifecycle");
        require(bundles.componentAt(bundleId, 0) == SUBSCRIPTION_A, "bundle membership mutated");
    }

    function testRejectsUnknownSubscriptionInvalidInputsAndUnknownBundle() public {
        BossBundles bundles = new BossBundles();
        MockBundleAccount account = new MockBundleAccount(address(this));
        bytes32[] memory one = _single(SUBSCRIPTION_A);

        _mustRevertWith(
            address(bundles),
            abi.encodeCall(BossBundles.createBundle, (address(account), MANIFEST, 1, one)),
            BossBundles.UnknownSubscription.selector
        );
        account.setSubscription(SUBSCRIPTION_A, RESOURCE, 1);
        _mustRevertWith(
            address(bundles),
            abi.encodeCall(BossBundles.createBundle, (address(account), bytes32(0), 1, one)),
            BossBundles.InvalidManifest.selector
        );
        _mustRevertWith(
            address(bundles),
            abi.encodeCall(BossBundles.createBundle, (address(account), MANIFEST, 0, one)),
            BossBundles.InvalidVersion.selector
        );
        _mustRevertWith(
            address(bundles),
            abi.encodeCall(BossBundles.createBundle, (address(account), MANIFEST, 1, new bytes32[](0))),
            BossBundles.InvalidComponentCount.selector
        );
        _mustRevertWith(
            address(bundles),
            abi.encodeCall(BossBundles.createBundle, (address(0), MANIFEST, 1, one)),
            BossBundles.InvalidAccount.selector
        );
        _mustRevertWith(
            address(bundles),
            abi.encodeCall(BossBundles.components, (bytes32(uint256(123)), 0, 1)),
            BossBundles.UnknownBundle.selector
        );
    }

    function _accountWithTwoSubscriptions() private returns (MockBundleAccount account) {
        account = new MockBundleAccount(address(this));
        account.setSubscription(SUBSCRIPTION_A, RESOURCE, 1);
        account.setSubscription(SUBSCRIPTION_B, RESOURCE, 2);
    }

    function _single(bytes32 value) private pure returns (bytes32[] memory values) {
        values = new bytes32[](1);
        values[0] = value;
    }

    function _pair(bytes32 first, bytes32 second) private pure returns (bytes32[] memory values) {
        values = new bytes32[](2);
        values[0] = first;
        values[1] = second;
    }
}
