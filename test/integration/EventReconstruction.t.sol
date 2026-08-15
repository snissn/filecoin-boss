// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossBundles} from "../../src/BossBundles.sol";
import {MockBundleAccount} from "../mocks/MockBundleAccount.sol";
import {MockBundleFactory} from "../mocks/MockBundleFactory.sol";

interface VmEventLogs {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}

contract EventReconstructionTest {
    VmEventLogs private constant VM = VmEventLogs(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant RESOURCE = keccak256("event-resource");
    bytes32 private constant MANIFEST = keccak256("event-manifest");
    bytes32 private constant SUBSCRIPTION_A = keccak256("event-subscription-a");
    bytes32 private constant SUBSCRIPTION_B = keccak256("event-subscription-b");

    function testBundleCanBeReconstructedFromEventsInOrder() public {
        MockBundleFactory factory = new MockBundleFactory();
        BossBundles bundles = new BossBundles(address(factory));
        MockBundleAccount account = new MockBundleAccount(address(this), address(factory));
        account.setSubscription(SUBSCRIPTION_A, RESOURCE, 1);
        account.setSubscription(SUBSCRIPTION_B, RESOURCE, 2);
        factory.register(address(account));

        bytes32[] memory subscriptionIds = new bytes32[](2);
        subscriptionIds[0] = SUBSCRIPTION_A;
        subscriptionIds[1] = SUBSCRIPTION_B;

        VM.recordLogs();
        bytes32 bundleId = bundles.createBundle(address(account), MANIFEST, 3, subscriptionIds);
        VmEventLogs.Log[] memory logs = VM.getRecordedLogs();

        bytes32 componentSignature = keccak256("BundleComponentAdded(bytes32,bytes32,uint256)");
        bytes32 createdSignature = keccak256("BundleCreated(bytes32,address,address,bytes32,bytes32,uint64,uint256)");
        bytes32[] memory reconstructed = new bytes32[](2);
        uint256 componentsSeen;
        uint256 lastComponentLogIndex;
        uint256 createdLogIndex;
        bool createdSeen;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(bundles) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == componentSignature) {
                require(logs[i].topics.length == 3, "component topics");
                require(logs[i].topics[1] == bundleId, "component bundle");
                uint256 index = abi.decode(logs[i].data, (uint256));
                require(index < reconstructed.length, "component index");
                require(index == componentsSeen, "component order");
                reconstructed[index] = logs[i].topics[2];
                lastComponentLogIndex = i;
                ++componentsSeen;
            } else if (logs[i].topics[0] == createdSignature) {
                require(logs[i].topics.length == 4, "created topics");
                require(logs[i].topics[1] == bundleId, "created bundle");
                require(address(uint160(uint256(logs[i].topics[2]))) == address(this), "created owner");
                require(address(uint160(uint256(logs[i].topics[3]))) == address(account), "created account");
                (bytes32 resourceKey, bytes32 manifestHash, uint64 version, uint256 componentCount) =
                    abi.decode(logs[i].data, (bytes32, bytes32, uint64, uint256));
                require(resourceKey == RESOURCE, "created resource");
                require(manifestHash == MANIFEST, "created manifest");
                require(version == 3, "created version");
                require(componentCount == 2, "created count");
                createdLogIndex = i;
                createdSeen = true;
            }
        }

        require(createdSeen, "missing created event");
        require(componentsSeen == 2, "missing component event");
        require(createdLogIndex > lastComponentLogIndex, "created event order");
        require(reconstructed[0] == SUBSCRIPTION_A, "reconstructed component zero");
        require(reconstructed[1] == SUBSCRIPTION_B, "reconstructed component one");

        bytes32[] memory stored = bundles.components(bundleId, 0, 2);
        require(stored.length == reconstructed.length, "stored length");
        require(stored[0] == reconstructed[0] && stored[1] == reconstructed[1], "event/state mismatch");
    }
}
