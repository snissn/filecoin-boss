// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

/// @notice Local-only PDP dependency with code at a deterministic deployment address.
contract LocalMockPDPVerifier {
    function dataSetLive(uint256) external pure returns (bool) {
        return false;
    }

    function getDataSetListener(uint256) external pure returns (address) {
        return address(0);
    }
}

/// @notice Local-only FWSS service marker.
contract LocalMockFWSSService {}

/// @notice Local-only FWSS state view that binds exactly one service address.
contract LocalMockFWSSStateView {
    address public immutable service;

    constructor(address service_) {
        require(service_ != address(0), "service");
        service = service_;
    }
}

/// @notice Local-only token marker. No balances or approvals are used by deployment smoke.
contract LocalMockToken {}
