// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossTypes} from "../../src/libraries/BossTypes.sol";

contract CapSemanticsTest {
    function testZeroCapAuthorizesZero() public pure {
        require(BossTypes.remainingCap(0, 0) == 0, "zero cap");
        require(BossTypes.remainingCap(0, 1) == 0, "zero cap used");
    }

    function testMaximumCapIsUnlimitedSentinel() public pure {
        require(BossTypes.isUnlimitedCap(type(uint256).max), "unlimited sentinel");
        require(
            BossTypes.remainingCap(type(uint256).max, type(uint256).max - 1) == type(uint256).max, "unlimited remaining"
        );
    }

    function testFiniteRemainingCapSaturatesAtZero() public pure {
        require(BossTypes.remainingCap(10, 3) == 7, "finite remaining");
        require(BossTypes.remainingCap(10, 10) == 0, "exact exhaustion");
        require(BossTypes.remainingCap(10, 11) == 0, "saturated exhaustion");
    }

    function testZeroExpiryMeansNoExpiry() public pure {
        require(BossTypes.isNoExpiry(0), "zero no-expiry");
        require(!BossTypes.isNoExpiry(1), "nonzero expiry");
    }

    function testEnumWireValuesAreStable() public pure {
        require(uint8(BossTypes.ResourceKind.FWSS_PDP_DATASET) == 0, "resource kind");
        require(uint8(BossTypes.BillingKind.STREAM_CAPACITY) == 1, "billing kind");
        require(uint8(BossTypes.AssuranceKind.TRUSTED_METERING) == 2, "assurance kind");
        require(uint8(BossTypes.DependencyKind.HARD) == 2, "dependency kind");
        require(uint8(BossTypes.SubscriptionState.TERMINATED) == 6, "state kind");
    }
}
