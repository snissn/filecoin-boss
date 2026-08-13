// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

interface IFWSSStateView {
    enum DataSetStatus {
        Inactive,
        Active
    }

    struct DataSetInfoView {
        uint256 pdpRailId;
        uint256 cacheMissRailId;
        uint256 cdnRailId;
        address payer;
        address payee;
        address serviceProvider;
        uint256 commissionBps;
        uint256 clientDataSetId;
        uint256 pdpEndEpoch;
        uint256 providerId;
        uint96 pendingOneTimePayments;
        uint96 lifecycleReserveBalance;
        uint256 dataSetId;
    }

    function service() external view returns (address);
    function getDataSet(uint256 dataSetId) external view returns (DataSetInfoView memory info);
    function getDataSetSizeInBytes(uint256 leafCount) external pure returns (uint256);
    function getDataSetStatus(uint256 dataSetId) external view returns (DataSetStatus status);
}
