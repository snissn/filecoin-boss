// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {CappedMeteredAdapter} from "../../src/adapters/pricing/CappedMeteredAdapter.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";

contract CappedMeteredAdapterTest {
    uint256 private constant TIB = 1 << 40;

    function testQuotesZeroStreamingRateAndExactUsageFloor() public view {
        CappedMeteredAdapter adapter = new CappedMeteredAdapter();
        bytes memory pricingData = abi.encode(
            CappedMeteredAdapter.MeteredTerms({grossPricePerTiB: 7 ether})
        );
        BossTypes.ResourceStatus memory resource;

        BossTypes.RateQuote memory quote = adapter.quoteRate(resource, pricingData);
        require(adapter.interfaceVersion() == 1, "interface version");
        require(quote.ratePerEpoch == 0, "zero streaming rate");
        require(quote.billable, "billable metering");
        require(quote.validThroughEpoch == type(uint64).max, "quote validity");
        require(quote.quoteHash == keccak256(pricingData), "quote hash");

        require(adapter.quoteUsage(0, pricingData) == 0, "zero bytes");
        require(adapter.quoteUsage(TIB / 2, pricingData) == 3.5 ether, "half TiB");
        require(adapter.quoteUsage(TIB, pricingData) == 7 ether, "one TiB");
        require(adapter.quoteUsage(TIB + 1, pricingData) == 7 ether + 6_366_462, "floor remainder");
    }

    function testMalformedOrZeroPriceDataFailsClosed() public {
        CappedMeteredAdapter adapter = new CappedMeteredAdapter();
        BossTypes.ResourceStatus memory resource;

        _mustFailRate(adapter, resource, hex"");
        _mustFailUsage(adapter, 1, hex"");
        bytes memory zeroPrice = abi.encode(CappedMeteredAdapter.MeteredTerms({grossPricePerTiB: 0}));
        _mustFailRate(adapter, resource, zeroPrice);
        _mustFailUsage(adapter, 1, zeroPrice);
    }

    function testFullPrecisionUsageDoesNotOverflowIntermediateProduct() public view {
        CappedMeteredAdapter adapter = new CappedMeteredAdapter();
        bytes memory pricingData = abi.encode(
            CappedMeteredAdapter.MeteredTerms({grossPricePerTiB: type(uint128).max})
        );

        uint256 units = type(uint128).max;
        uint256 charged = adapter.quoteUsage(units, pricingData);
        require(charged != 0, "large quote");
        require(charged == units * (type(uint128).max / TIB) + units * (type(uint128).max % TIB) / TIB, "full precision");
    }

    function _mustFailRate(
        CappedMeteredAdapter adapter,
        BossTypes.ResourceStatus memory resource,
        bytes memory pricingData
    ) private {
        try adapter.quoteRate(resource, pricingData) returns (BossTypes.RateQuote memory) {
            revert("invalid rate terms accepted");
        } catch {}
    }

    function _mustFailUsage(CappedMeteredAdapter adapter, uint256 units, bytes memory pricingData) private {
        try adapter.quoteUsage(units, pricingData) returns (uint256) {
            revert("invalid usage terms accepted");
        } catch {}
    }
}
