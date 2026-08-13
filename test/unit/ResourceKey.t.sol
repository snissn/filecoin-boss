// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossTypes} from "../../src/libraries/BossTypes.sol";
import {BossHashes} from "../../src/libraries/BossHashes.sol";

contract ResourceKeyTest {
    function testFwssPdpResourceKeyVector() public pure {
        BossTypes.ResourceRef memory resource = BossTypes.ResourceRef({
            kind: BossTypes.ResourceKind.FWSS_PDP_DATASET,
            chainId: 314159,
            anchor: 0x1111111111111111111111111111111111111111,
            resourceId: 42,
            context: bytes32(0)
        });

        require(
            BossHashes.hashResource(resource)
                == 0x2491bd8df43b21fcd186b46f8a5819bf773a751fa244818318c81b362a003920,
            "resource key"
        );
    }

    function testSubscriptionIdVector() public pure {
        bytes32 offerHash = 0x79a282dc16a82c88b59ba0afceb6a41a1964073787b68241da04a8054d900716;
        bytes32 resourceKey = 0x2491bd8df43b21fcd186b46f8a5819bf773a751fa244818318c81b362a003920;

        require(
            BossHashes.deriveSubscriptionId(
                0x7777777777777777777777777777777777777777,
                offerHash,
                resourceKey
            ) == 0xaccd1ea0e51657c2cdf3530b81983d215c7d39c28679fdaa63bb692298795b11,
            "subscription id"
        );
    }
}
