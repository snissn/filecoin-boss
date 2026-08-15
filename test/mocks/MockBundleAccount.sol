// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossTypes} from "../../src/libraries/BossTypes.sol";

contract MockBundleAccount {
    error DisallowedAccountCall(bytes4 selector);

    address public immutable owner;
    address public immutable payer;
    address public immutable factory;
    address public constant filecoinPay = address(0xF11E);
    address public constant serviceRegistry = address(0x5100);
    address public constant adapterRegistry = address(0xADA7);
    uint64 public constant accountVersion = 1;

    mapping(bytes32 subscriptionId => BossTypes.Subscription subscription) private _subscriptions;

    constructor(address owner_, address factory_) {
        owner = owner_;
        payer = owner_;
        factory = factory_;
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
