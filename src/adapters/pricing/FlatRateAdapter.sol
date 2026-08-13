// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {IBossPricingAdapter} from "../../interfaces/IBossPricingAdapter.sol";
import {BossTypes} from "../../libraries/BossTypes.sol";

/// @notice Quotes one constant per-epoch rate by flooring a gross period price.
contract FlatRateAdapter is IBossPricingAdapter {
    error InvalidPricingData();
    error InvalidPeriod();
    error UsageUnsupported();

    struct FlatRateTerms {
        uint256 grossPricePerPeriod;
        uint64 periodEpochs;
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    /// @dev The remainder is disclosed in `note`; v1 schedules no correction payment.
    function quoteRate(BossTypes.ResourceStatus calldata, bytes calldata pricingData)
        external
        pure
        returns (BossTypes.RateQuote memory quote)
    {
        if (pricingData.length != 64) revert InvalidPricingData();

        FlatRateTerms memory terms = abi.decode(pricingData, (FlatRateTerms));
        if (terms.periodEpochs == 0) revert InvalidPeriod();

        uint256 ratePerEpoch = terms.grossPricePerPeriod / terms.periodEpochs;
        uint256 remainder = terms.grossPricePerPeriod % terms.periodEpochs;
        quote = BossTypes.RateQuote({
            ratePerEpoch: ratePerEpoch,
            validThroughEpoch: type(uint64).max,
            billable: true,
            quoteHash: keccak256(pricingData),
            note: string.concat("floor remainder=", _toString(remainder))
        });
    }

    function quoteUsage(uint256, bytes calldata) external pure returns (uint256) {
        revert UsageUnsupported();
    }

    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";

        uint256 digits;
        uint256 cursor = value;
        while (cursor != 0) {
            ++digits;
            cursor /= 10;
        }

        bytes memory output = new bytes(digits);
        while (value != 0) {
            output[--digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(output);
    }
}
