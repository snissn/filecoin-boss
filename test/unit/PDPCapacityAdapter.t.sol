// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PDPCapacityAdapter} from "../../src/adapters/pricing/PDPCapacityAdapter.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";

contract PDPCapacityAdapterTest {
    uint256 private constant TIB = 1 << 40;
    uint256 private constant PRICE_PER_TIB = 1 ether;
    uint64 private constant EPOCHS_PER_30_DAYS = 86_400;

    PDPCapacityAdapter private adapter;

    function setUp() public {
        adapter = new PDPCapacityAdapter();
    }

    function testExactCapacityRateVectors() public view {
        _assertRate(0, 0);
        _assertRate(TIB / 2, 5_787_037_037_037);
        _assertRate(TIB, 11_574_074_074_074);
        _assertRate(TIB * 7 / 2, 40_509_259_259_259);
        _assertRate(TIB * 10, 115_740_740_740_740);
    }

    function testQuoteCommitsResourceAndPricingStateWithoutChoosingTtl() public view {
        BossTypes.ResourceStatus memory resource = _resource(TIB, keccak256("state-1"), true);
        BossTypes.RateQuote memory first = adapter.quoteRate(resource, _pricingData());

        require(first.billable, "billable");
        require(first.validThroughEpoch == 0, "adapter validity is not neutral");
        require(first.quoteHash != bytes32(0), "quote hash");

        resource.statusHash = keccak256("state-2");
        BossTypes.RateQuote memory changedState = adapter.quoteRate(resource, _pricingData());
        require(changedState.quoteHash != first.quoteHash, "state hash not committed");

        resource.statusHash = keccak256("state-1");
        resource.sizeInBytes = TIB * 2;
        BossTypes.RateQuote memory changedSize = adapter.quoteRate(resource, _pricingData());
        require(changedSize.quoteHash != first.quoteHash, "size not committed");

        bytes memory changedPricing = abi.encode(
            PDPCapacityAdapter.CapacityTerms({
                grossPricePerTiBPerPeriod: PRICE_PER_TIB * 2,
                periodEpochs: EPOCHS_PER_30_DAYS
            })
        );
        BossTypes.RateQuote memory changedTerms = adapter.quoteRate(resource, changedPricing);
        require(changedTerms.quoteHash != changedSize.quoteHash, "pricing not committed");
    }

    function testUnavailableResourceQuotesZeroAndNonBillable() public view {
        BossTypes.ResourceStatus memory resource = _resource(0, bytes32(0), false);
        BossTypes.RateQuote memory quote = adapter.quoteRate(resource, _pricingData());

        require(!quote.billable, "unavailable billable");
        require(quote.ratePerEpoch == 0, "unavailable rate");
        require(quote.validThroughEpoch == 0, "unavailable adapter validity is not neutral");
        require(quote.quoteHash != bytes32(0), "unavailable quote hash");
    }

    function testMalformedZeroAndUnsupportedUsageFailClosed() public {
        _mustFailRate(hex"");
        _mustFailRate(abi.encode(PDPCapacityAdapter.CapacityTerms(0, EPOCHS_PER_30_DAYS)));
        _mustFailRate(abi.encode(PDPCapacityAdapter.CapacityTerms(PRICE_PER_TIB, 0)));

        (bool success,) = address(adapter).call(abi.encodeCall(PDPCapacityAdapter.quoteUsage, (TIB, _pricingData())));
        require(!success, "usage pricing supported");
    }

    function _assertRate(uint256 sizeInBytes, uint256 expectedRate) private view {
        BossTypes.RateQuote memory quote =
            adapter.quoteRate(_resource(sizeInBytes, keccak256(abi.encode(sizeInBytes)), true), _pricingData());
        require(quote.ratePerEpoch == expectedRate, "capacity vector");
        require(quote.billable, "capacity vector billable");
    }

    function _mustFailRate(bytes memory pricingData) private {
        (bool success,) = address(adapter).call(
            abi.encodeCall(PDPCapacityAdapter.quoteRate, (_resource(TIB, keccak256("state"), true), pricingData))
        );
        require(!success, "invalid capacity terms accepted");
    }

    function _pricingData() private pure returns (bytes memory) {
        return abi.encode(
            PDPCapacityAdapter.CapacityTerms({
                grossPricePerTiBPerPeriod: PRICE_PER_TIB,
                periodEpochs: EPOCHS_PER_30_DAYS
            })
        );
    }

    function _resource(uint256 sizeInBytes, bytes32 statusHash, bool available)
        private
        pure
        returns (BossTypes.ResourceStatus memory)
    {
        return BossTypes.ResourceStatus({
            resourceKey: keccak256("resource"),
            exists: available,
            attachable: available,
            billable: available,
            payer: available ? address(0xA11CE) : address(0),
            storageProvider: available ? address(0xB0B) : address(0),
            sizeInBytes: sizeInBytes,
            statusHash: statusHash
        });
    }
}
