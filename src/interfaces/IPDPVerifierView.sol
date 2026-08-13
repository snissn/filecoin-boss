// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

interface IPDPVerifierView {
    function dataSetLive(uint256 setId) external view returns (bool);
    function getDataSetLeafCount(uint256 setId) external view returns (uint256);
    function getDataSetListener(uint256 setId) external view returns (address);
    function getDataSetStorageProvider(uint256 setId) external view returns (address serviceProvider, address proposedProvider);
    function getDataSetLastProvenEpoch(uint256 setId) external view returns (uint256);
}
