// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {BossTypes} from "../libraries/BossTypes.sol";

interface IBossPricingAdapter {
    function interfaceVersion() external pure returns (uint64);

    function quoteRate(BossTypes.ResourceStatus calldata resource, bytes calldata pricingData)
        external
        view
        returns (BossTypes.RateQuote memory quote);

    function quoteUsage(uint256 units, bytes calldata pricingData) external view returns (uint256 grossCharge);
}
