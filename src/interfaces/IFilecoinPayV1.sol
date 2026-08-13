// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

interface IFilecoinPayValidator {
    struct ValidationResult {
        uint256 modifiedAmount;
        uint256 settleUpto;
        string note;
    }

    function validatePayment(uint256 railId, uint256 proposedAmount, uint256 fromEpoch, uint256 toEpoch, uint256 rate)
        external
        returns (ValidationResult memory result);

    function railTerminated(uint256 railId, address terminator, uint256 endEpoch) external;
}

interface IFilecoinPayV1 {
    struct RailView {
        address token;
        address from;
        address to;
        address operator;
        address validator;
        uint256 paymentRate;
        uint256 lockupPeriod;
        uint256 lockupFixed;
        uint256 settledUpTo;
        uint256 endEpoch;
        uint256 commissionRateBps;
        address serviceFeeRecipient;
    }

    function createRail(
        address token,
        address from,
        address to,
        address validator,
        uint256 commissionRateBps,
        address serviceFeeRecipient
    ) external returns (uint256 railId);

    function modifyRailLockup(uint256 railId, uint256 period, uint256 lockupFixed) external;

    function modifyRailPayment(uint256 railId, uint256 newRate, uint256 oneTimePayment) external;

    function settleRail(uint256 railId, uint256 untilEpoch)
        external
        returns (
            uint256 totalSettledAmount,
            uint256 totalNetPayeeAmount,
            uint256 totalOperatorCommission,
            uint256 totalNetworkFee,
            uint256 finalSettledEpoch,
            string memory note
        );

    function terminateRail(uint256 railId) external;

    function getRail(uint256 railId) external view returns (RailView memory rail);

    function getAccountInfoIfSettled(address token, address owner)
        external
        view
        returns (uint256 fundedUntilEpoch, uint256 currentFunds, uint256 availableFunds, uint256 currentLockupRate);

    function operatorApprovals(address token, address client, address operator)
        external
        view
        returns (
            bool isApproved,
            uint256 rateAllowance,
            uint256 lockupAllowance,
            uint256 rateUsage,
            uint256 lockupUsage,
            uint256 maxLockupPeriod
        );
}
