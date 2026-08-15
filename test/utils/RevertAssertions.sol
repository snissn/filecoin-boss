// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

abstract contract RevertAssertions {
    function _mustRevertWith(address target, bytes memory callData, bytes4 expectedSelector) internal {
        (bool success, bytes memory returnData) = target.call(callData);
        require(!success, "expected revert");
        require(returnData.length >= 4, "missing revert selector");
        bytes4 observedSelector;
        assembly ("memory-safe") {
            observedSelector := mload(add(returnData, 0x20))
        }
        require(observedSelector == expectedSelector, "wrong revert selector");
    }
}
