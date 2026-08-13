// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossHashes} from "../../src/libraries/BossHashes.sol";
import {BossVectorFixture} from "../utils/BossVectorFixture.sol";

contract ResourceKeyTest is BossVectorFixture {
    function testFwssPdpResourceKeyVector() public view {
        string memory json = _vectorJson();

        require(
            BossHashes.hashResource(_resource(json)) == _bytes32(json, ".vectors.resourceKey"), "resource key"
        );
    }

    function testSubscriptionIdVector() public view {
        string memory json = _vectorJson();
        bytes32 offerHash = BossHashes.hashServiceOffer(_offer(json));
        bytes32 resourceKey = BossHashes.hashResource(_resource(json));

        require(
            BossHashes.deriveSubscriptionId(
                _address(json, ".inputs.subscription.account"), offerHash, resourceKey
            ) == _bytes32(json, ".vectors.subscriptionId"),
            "subscription id"
        );
    }
}
