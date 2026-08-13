// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossAdapterRegistry} from "../../src/BossAdapterRegistry.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";

interface VmAdapterRegistry {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
    function etch(address target, bytes calldata newRuntimeBytecode) external;
}

contract AdapterRegistryActor {
    function execute(address target, bytes calldata callData) external returns (bool success, bytes memory result) {
        return target.call(callData);
    }
}

contract DummyResourceAdapter {
    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }
}

contract DummyPricingAdapter {
    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }
}

contract BossAdapterRegistryTest {
    VmAdapterRegistry internal constant vm = VmAdapterRegistry(address(uint160(uint256(keccak256("hevm cheat code")))));

    function testGovernanceRegistersPinnedAdapterAndCompleteEvent() public {
        AdapterRegistryActor governance = new AdapterRegistryActor();
        BossAdapterRegistry registry = new BossAdapterRegistry(address(governance));
        DummyResourceAdapter adapter = new DummyResourceAdapter();
        bytes32 expectedCodeHash = address(adapter).codehash;

        vm.recordLogs();
        _mustExecute(
            governance,
            address(registry),
            abi.encodeCall(
                BossAdapterRegistry.registerAdapter,
                (address(adapter), BossTypes.AdapterKind.RESOURCE, uint64(1), "ipfs://resource-adapter-v1")
            )
        );
        VmAdapterRegistry.Log[] memory logs = vm.getRecordedLogs();

        require(logs.length == 1, "registration log count");
        require(logs[0].emitter == address(registry), "registration emitter");
        require(logs[0].topics.length == 2, "registration topics");
        require(
            logs[0].topics[0] == keccak256("AdapterRegistered(address,uint8,uint64,bytes32,string)"),
            "registration signature"
        );
        require(address(uint160(uint256(logs[0].topics[1]))) == address(adapter), "registration adapter");
        (uint8 kind, uint64 interfaceVersion, bytes32 codeHash, string memory metadataURI) =
            abi.decode(logs[0].data, (uint8, uint64, bytes32, string));
        require(kind == uint8(BossTypes.AdapterKind.RESOURCE), "registration kind");
        require(interfaceVersion == 1, "registration version");
        require(codeHash == expectedCodeHash, "registration codehash");
        require(keccak256(bytes(metadataURI)) == keccak256("ipfs://resource-adapter-v1"), "registration metadata");

        BossTypes.AdapterRecord memory record = registry.getAdapter(address(adapter));
        require(registry.isRegistered(address(adapter)), "registered");
        require(record.kind == BossTypes.AdapterKind.RESOURCE, "record kind");
        require(record.interfaceVersion == 1, "record version");
        require(record.codeHash == expectedCodeHash, "record codehash");
        require(record.activeForNewSubscriptions, "record active");
        require(keccak256(bytes(record.metadataURI)) == keccak256("ipfs://resource-adapter-v1"), "record metadata");
        require(registry.isActive(address(adapter), BossTypes.AdapterKind.RESOURCE, 1), "active lookup");
    }

    function testUnauthorizedZeroCodeDuplicateWrongKindAndWrongVersionFailClosed() public {
        AdapterRegistryActor governance = new AdapterRegistryActor();
        AdapterRegistryActor outsider = new AdapterRegistryActor();
        BossAdapterRegistry registry = new BossAdapterRegistry(address(governance));
        DummyResourceAdapter adapter = new DummyResourceAdapter();

        _mustFail(
            outsider,
            address(registry),
            abi.encodeCall(
                BossAdapterRegistry.registerAdapter,
                (address(adapter), BossTypes.AdapterKind.RESOURCE, uint64(1), "ipfs://unauthorized")
            )
        );
        _mustFail(
            governance,
            address(registry),
            abi.encodeCall(
                BossAdapterRegistry.registerAdapter,
                (address(0xBEEF), BossTypes.AdapterKind.RESOURCE, uint64(1), "ipfs://no-code")
            )
        );
        _mustFail(
            governance,
            address(registry),
            abi.encodeCall(
                BossAdapterRegistry.registerAdapter,
                (address(adapter), BossTypes.AdapterKind.RESOURCE, uint64(0), "ipfs://zero-version")
            )
        );
        _mustExecute(
            governance,
            address(registry),
            abi.encodeCall(
                BossAdapterRegistry.registerAdapter,
                (address(adapter), BossTypes.AdapterKind.RESOURCE, uint64(1), "ipfs://resource")
            )
        );
        _mustFail(
            governance,
            address(registry),
            abi.encodeCall(
                BossAdapterRegistry.registerAdapter,
                (address(adapter), BossTypes.AdapterKind.RESOURCE, uint64(1), "ipfs://duplicate")
            )
        );

        require(!registry.isActive(address(adapter), BossTypes.AdapterKind.PRICING, 1), "wrong kind false");
        require(!registry.isActive(address(adapter), BossTypes.AdapterKind.RESOURCE, 2), "wrong version false");
        require(!registry.isActive(address(0xBEEF), BossTypes.AdapterKind.RESOURCE, 1), "unregistered false");
    }

    function testDisableAndChangedRuntimeCodeHashFailClosed() public {
        AdapterRegistryActor governance = new AdapterRegistryActor();
        BossAdapterRegistry registry = new BossAdapterRegistry(address(governance));
        DummyPricingAdapter adapter = new DummyPricingAdapter();

        _mustExecute(
            governance,
            address(registry),
            abi.encodeCall(
                BossAdapterRegistry.registerAdapter,
                (address(adapter), BossTypes.AdapterKind.PRICING, uint64(1), "ipfs://pricing")
            )
        );
        require(registry.isActive(address(adapter), BossTypes.AdapterKind.PRICING, 1), "initially active");

        vm.etch(address(adapter), hex"00");
        require(!registry.isActive(address(adapter), BossTypes.AdapterKind.PRICING, 1), "changed codehash false");

        _mustExecute(
            governance,
            address(registry),
            abi.encodeCall(BossAdapterRegistry.setAdapterActive, (address(adapter), false))
        );
        require(!registry.getAdapter(address(adapter)).activeForNewSubscriptions, "disabled record");
        _mustFail(
            governance,
            address(registry),
            abi.encodeCall(BossAdapterRegistry.setAdapterActive, (address(adapter), true))
        );
    }

    function testGovernanceTransferRemovesOldAuthority() public {
        AdapterRegistryActor oldGovernance = new AdapterRegistryActor();
        AdapterRegistryActor newGovernance = new AdapterRegistryActor();
        BossAdapterRegistry registry = new BossAdapterRegistry(address(oldGovernance));
        DummyResourceAdapter adapter = new DummyResourceAdapter();

        _mustExecute(
            oldGovernance,
            address(registry),
            abi.encodeCall(BossAdapterRegistry.transferGovernance, (address(newGovernance)))
        );
        require(registry.governance() == address(newGovernance), "new governance");

        bytes memory registration = abi.encodeCall(
            BossAdapterRegistry.registerAdapter,
            (address(adapter), BossTypes.AdapterKind.RESOURCE, uint64(1), "ipfs://resource")
        );
        _mustFail(oldGovernance, address(registry), registration);
        _mustExecute(newGovernance, address(registry), registration);
    }

    function _mustExecute(AdapterRegistryActor actor, address target, bytes memory callData) private {
        (bool success,) = actor.execute(target, callData);
        require(success, "expected success");
    }

    function _mustFail(AdapterRegistryActor actor, address target, bytes memory callData) private {
        (bool success,) = actor.execute(target, callData);
        require(!success, "expected failure");
    }
}
