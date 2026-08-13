// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBossPricingAdapter} from "../../interfaces/IBossPricingAdapter.sol";
import {BossTypes} from "../../libraries/BossTypes.sol";

/// @notice Quotes prospective streaming rates from validated approximate raw capacity.
contract PDPCapacityAdapter is IBossPricingAdapter {
    uint256 private constant BYTES_PER_TIB = 1 << 40;

    error InvalidPricingData();
    error InvalidPrice();
    error InvalidPeriod();
    error InvalidQuoteTtl();
    error QuoteEpochOverflow();
    error UsageUnsupported();

    struct CapacityTerms {
        uint256 grossPricePerTiBPerPeriod;
        uint64 periodEpochs;
        uint64 quoteTtlEpochs;
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function quoteRate(BossTypes.ResourceStatus calldata resource, bytes calldata pricingData)
        external
        view
        returns (BossTypes.RateQuote memory quote)
    {
        CapacityTerms memory terms = _terms(pricingData);
        bool billable = resource.exists && resource.attachable && resource.billable;

        uint256 validThrough = billable ? block.number + terms.quoteTtlEpochs : block.number;
        if (validThrough > type(uint64).max) revert QuoteEpochOverflow();

        uint256 ratePerEpoch;
        if (billable) {
            uint256 denominator = BYTES_PER_TIB * uint256(terms.periodEpochs);
            ratePerEpoch = Math.mulDiv(resource.sizeInBytes, terms.grossPricePerTiBPerPeriod, denominator);
        }

        bytes32 quoteHash = keccak256(
            abi.encode(
                "FILECOIN_BOSS_PDP_CAPACITY_QUOTE_V1",
                resource.resourceKey,
                resource.statusHash,
                resource.sizeInBytes,
                keccak256(pricingData),
                ratePerEpoch,
                uint64(validThrough),
                billable
            )
        );
        quote = BossTypes.RateQuote({
            ratePerEpoch: ratePerEpoch,
            validThroughEpoch: uint64(validThrough),
            billable: billable,
            quoteHash: quoteHash,
            note: "approximate raw bytes; prospective capacity rate"
        });
    }

    function quoteUsage(uint256, bytes calldata) external pure returns (uint256) {
        revert UsageUnsupported();
    }

    function _terms(bytes calldata pricingData) private pure returns (CapacityTerms memory terms) {
        if (pricingData.length != 96) revert InvalidPricingData();
        terms = abi.decode(pricingData, (CapacityTerms));
        if (terms.grossPricePerTiBPerPeriod == 0) revert InvalidPrice();
        if (terms.periodEpochs == 0) revert InvalidPeriod();
        if (terms.quoteTtlEpochs == 0) revert InvalidQuoteTtl();
    }
}
