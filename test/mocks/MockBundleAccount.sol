// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossTypes} from "../../src/libraries/BossTypes.sol";

contract MockBundleAccount {
    error DisallowedAccountCall(bytes4 selector);

    address public immutable owner;
    mapping(bytes32 subscriptionId => BossTypes.Subscription subscription) private _subscriptions;

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

    fallback() external {
        revert DisallowedAccountCall(msg.sig);
    }
}
