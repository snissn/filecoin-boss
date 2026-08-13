// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossAccount} from "../../src/BossAccount.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";

contract BossAccountFlatLifecycleRedTest {
    function testFlatOfferLifecycleSurfaceExists() public {
        BossAccount account = new BossAccount(address(this), address(0xF11E), address(0x5100), address(0xADA7), 1);
        BossTypes.AcceptanceInput memory input;

        account.acceptOffer(input);
    }
}
