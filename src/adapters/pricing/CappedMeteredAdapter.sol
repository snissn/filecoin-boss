// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBossPricingAdapter} from "../../interfaces/IBossPricingAdapter.sol";
import {BossTypes} from "../../libraries/BossTypes.sol";

/// @notice Computes trusted-metering gross charges from accepted byte-price terms.
contract CappedMeteredAdapter is IBossPricingAdapter {
    uint256 private constant BYTES_PER_TIB = 1 << 40;

    error InvalidPricingData();
    error InvalidPrice();

    struct MeteredTerms {
        uint256 grossPricePerTiB;
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function quoteRate(BossTypes.ResourceStatus calldata, bytes calldata pricingData)
        external
        pure
        returns (BossTypes.RateQuote memory quote)
    {
        _terms(pricingData);
        quote = BossTypes.RateQuote({
            ratePerEpoch: 0,
            validThroughEpoch: type(uint64).max,
            billable: true,
            quoteHash: keccak256(pricingData),
            note: "trusted metering; prepaid caps"
        });
    }

    function quoteUsage(uint256 units, bytes calldata pricingData) external pure returns (uint256 grossCharge) {
        MeteredTerms memory terms = _terms(pricingData);
        grossCharge = Math.mulDiv(units, terms.grossPricePerTiB, BYTES_PER_TIB);
    }

    function _terms(bytes calldata pricingData) private pure returns (MeteredTerms memory terms) {
        if (pricingData.length != 32) revert InvalidPricingData();
        terms = abi.decode(pricingData, (MeteredTerms));
        if (terms.grossPricePerTiB == 0) revert InvalidPrice();
    }
}
