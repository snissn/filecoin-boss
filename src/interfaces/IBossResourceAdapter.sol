// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {BossTypes} from "../libraries/BossTypes.sol";

interface IBossResourceAdapter {
    function interfaceVersion() external pure returns (uint64);

    function inspect(BossTypes.ResourceRef calldata resource, address expectedPayer, bytes calldata resourceData)
        external
        view
        returns (BossTypes.ResourceStatus memory status);
}
