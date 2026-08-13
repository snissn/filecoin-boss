// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossAccount} from "../../src/BossAccount.sol";
import {FlatRateAdapter} from "../../src/adapters/pricing/FlatRateAdapter.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";

contract BossAccountFlatLifecycleTest {
    function testEmptyOfferFailsClosed() public {
        BossAccount account = new BossAccount(address(this), address(0xF11E), address(0x5100), address(0xADA7), 1);
        BossTypes.AcceptanceInput memory input;

        try account.acceptOffer(input) returns (bytes32, uint256) {
            revert("empty offer accepted");
        } catch {}
    }

    function testFlatRateUsesFloorDivision() public {
        FlatRateAdapter adapter = new FlatRateAdapter();
        BossTypes.ResourceStatus memory resource;
        bytes memory pricingData = abi.encode(
            FlatRateAdapter.FlatRateTerms({grossPricePerPeriod: 1_000, periodEpochs: 30})
        );

        BossTypes.RateQuote memory quote = adapter.quoteRate(resource, pricingData);
        require(quote.ratePerEpoch == 33, "floor rate");
        require(quote.billable, "flat quote billable");
        require(quote.quoteHash == keccak256(pricingData), "quote binding");
    }
}
