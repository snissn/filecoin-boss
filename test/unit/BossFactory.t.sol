// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossAccount} from "../../src/BossAccount.sol";
import {BossFactory} from "../../src/BossFactory.sol";

interface VmFactory {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
    function getCode(string calldata artifactPath) external returns (bytes memory creationCode);
}

contract FactoryActor {
    function execute(address target, bytes calldata callData) external returns (bool success, bytes memory result) {
        return target.call(callData);
    }
}

contract BossFactoryTest {
    VmFactory internal constant vm = VmFactory(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant OWNER = address(0xA11CE);
    address internal constant FILECOIN_PAY = address(0xF11E);
    address internal constant SERVICE_REGISTRY = address(0x5100);
    address internal constant ADAPTER_REGISTRY = address(0xADA7);
    uint64 internal constant VERSION = 1;

    function testFactoryPinsCanonicalCreationCodeAndKeepsRuntimeMargin() public {
        BossFactory factory = new BossFactory();
        bytes memory creationCode = _creationCode();

        require(factory.accountCreationCodeHash() == keccak256(creationCode), "creation-code hash");
        require(address(factory).code.length <= 20_480, "factory has less than 4 KiB EIP-170 margin");
    }

    function testPredictionDeploymentMappingAndEventAreDeterministic() public {
        BossFactory factory = new BossFactory();
        bytes memory creationCode = _creationCode();
        bytes32 expectedKey = factory.accountKey(OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION);
        address predicted =
            factory.predictAccount(OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION, creationCode);
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(creationCode, abi.encode(OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION))
        );
        address manuallyPredicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), expectedKey, initCodeHash))))
        );
        require(predicted == manuallyPredicted, "manual CREATE2 parity");
        require(predicted.code.length == 0, "predicted address initially empty");

        vm.recordLogs();
        address account =
            factory.createAccount(OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION, creationCode);
        VmFactory.Log[] memory logs = vm.getRecordedLogs();

        require(account == predicted, "prediction parity");
        require(account.code.length != 0, "account deployed");
        require(factory.accountFor(expectedKey) == account, "account mapping");
        require(logs.length == 1, "creation log count");
        require(logs[0].emitter == address(factory), "creation emitter");
        require(logs[0].topics.length == 4, "creation topics");
        require(
            logs[0].topics[0] == keccak256("BossAccountCreated(address,address,address,address,address,uint64,bytes32)"),
            "creation signature"
        );
        require(address(uint160(uint256(logs[0].topics[1]))) == OWNER, "creation owner");
        require(address(uint160(uint256(logs[0].topics[2]))) == account, "creation account");
        require(address(uint160(uint256(logs[0].topics[3]))) == FILECOIN_PAY, "creation pay");
        (address serviceRegistry, address adapterRegistry, uint64 accountVersion, bytes32 accountKey_) =
            abi.decode(logs[0].data, (address, address, uint64, bytes32));
        require(serviceRegistry == SERVICE_REGISTRY, "creation service registry");
        require(adapterRegistry == ADAPTER_REGISTRY, "creation adapter registry");
        require(accountVersion == VERSION, "creation version");
        require(accountKey_ == expectedKey, "creation key");
    }

    function testWrongEmptyTruncatedAndArgumentInjectedCreationCodeFailClosed() public {
        BossFactory factory = new BossFactory();
        bytes memory creationCode = _creationCode();

        _mustFailPredict(factory, bytes(""));
        _mustFailCreate(factory, bytes(""));

        bytes memory truncated = _creationCode();
        assembly ("memory-safe") {
            mstore(truncated, sub(mload(truncated), 1))
        }
        _mustFailPredict(factory, truncated);
        _mustFailCreate(factory, truncated);

        bytes memory argumentInjected = abi.encodePacked(
            creationCode, abi.encode(address(0xBAD), FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION)
        );
        _mustFailPredict(factory, argumentInjected);
        _mustFailCreate(factory, argumentInjected);
    }

    function testCreateIsIdempotent() public {
        BossFactory factory = new BossFactory();
        bytes memory creationCode = _creationCode();
        address first =
            factory.createAccount(OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION, creationCode);
        address second =
            factory.createAccount(OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION, creationCode);

        require(first == second, "idempotent address");
        require(first.code.length != 0, "idempotent code");
    }

    function testEveryAuthorityAndRegistryInputAffectsAddress() public {
        BossFactory factory = new BossFactory();
        bytes memory creationCode = _creationCode();
        address base =
            factory.predictAccount(OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION, creationCode);

        require(
            base
                != factory.predictAccount(
                    address(0xB0B), FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION, creationCode
                ),
            "owner affects address"
        );
        require(
            base
                != factory.predictAccount(OWNER, address(0xF22E), SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION, creationCode),
            "pay affects address"
        );
        require(
            base
                != factory.predictAccount(OWNER, FILECOIN_PAY, address(0x5200), ADAPTER_REGISTRY, VERSION, creationCode),
            "service registry affects address"
        );
        require(
            base
                != factory.predictAccount(OWNER, FILECOIN_PAY, SERVICE_REGISTRY, address(0xADA8), VERSION, creationCode),
            "adapter registry affects address"
        );
    }

    function testUnsupportedAccountVersionsFailClosed() public {
        BossFactory factory = new BossFactory();
        FactoryActor caller = new FactoryActor();
        bytes memory creationCode = _creationCode();
        uint64 unsupportedVersion = VERSION + 1;

        _mustFail(
            caller,
            address(factory),
            abi.encodeCall(
                BossFactory.accountKey, (OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, unsupportedVersion)
            )
        );
        _mustFail(
            caller,
            address(factory),
            abi.encodeCall(
                BossFactory.predictAccount,
                (OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, unsupportedVersion, creationCode)
            )
        );
        _mustFail(
            caller,
            address(factory),
            abi.encodeCall(
                BossFactory.createAccount,
                (OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, unsupportedVersion, creationCode)
            )
        );

        try new BossAccount(OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, unsupportedVersion) returns (
            BossAccount
        ) {
            revert("unsupported account version deployed");
        } catch {}
    }

    function testAnyoneMayDeployButCannotAcquireOwnerAuthority() public {
        BossFactory factory = new BossFactory();
        FactoryActor deployer = new FactoryActor();
        bytes memory creationCode = _creationCode();

        (bool success, bytes memory result) = deployer.execute(
            address(factory),
            abi.encodeCall(
                BossFactory.createAccount,
                (OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION, creationCode)
            )
        );
        require(success, "permissionless deploy");
        address accountAddress = abi.decode(result, (address));
        BossAccount account = BossAccount(accountAddress);

        require(account.owner() == OWNER, "owner pinned");
        require(account.payer() == OWNER, "payer equals owner");
        require(account.owner() != address(deployer), "deployer not owner");
        require(account.filecoinPay() == FILECOIN_PAY, "pay pinned");
        require(account.serviceRegistry() == SERVICE_REGISTRY, "service registry pinned");
        require(account.adapterRegistry() == ADAPTER_REGISTRY, "adapter registry pinned");
        require(account.accountVersion() == VERSION, "version pinned");
        require(account.factory() == address(factory), "factory pinned");
    }

    function testZeroAuthorityAndConfigurationInputsFailClosed() public {
        BossFactory factory = new BossFactory();
        FactoryActor caller = new FactoryActor();
        bytes memory creationCode = _creationCode();

        _mustFail(
            caller,
            address(factory),
            abi.encodeCall(
                BossFactory.createAccount,
                (address(0), FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION, creationCode)
            )
        );
        _mustFail(
            caller,
            address(factory),
            abi.encodeCall(
                BossFactory.createAccount,
                (OWNER, address(0), SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION, creationCode)
            )
        );
        _mustFail(
            caller,
            address(factory),
            abi.encodeCall(
                BossFactory.createAccount, (OWNER, FILECOIN_PAY, address(0), ADAPTER_REGISTRY, VERSION, creationCode)
            )
        );
        _mustFail(
            caller,
            address(factory),
            abi.encodeCall(
                BossFactory.createAccount, (OWNER, FILECOIN_PAY, SERVICE_REGISTRY, address(0), VERSION, creationCode)
            )
        );
        _mustFail(
            caller,
            address(factory),
            abi.encodeCall(
                BossFactory.createAccount,
                (OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, uint64(0), creationCode)
            )
        );
    }

    function testAccountHasNoInitializationOwnershipTransferOrUpgradeSurface() public {
        BossFactory factory = new BossFactory();
        address account =
            factory.createAccount(OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION, _creationCode());

        _mustFailRaw(
            account,
            abi.encodeWithSignature(
                "initialize(address,address,address,address,uint64)",
                address(this),
                FILECOIN_PAY,
                SERVICE_REGISTRY,
                ADAPTER_REGISTRY,
                VERSION
            )
        );
        _mustFailRaw(account, abi.encodeWithSignature("transferOwnership(address)", address(this)));
        _mustFailRaw(account, abi.encodeWithSignature("upgradeTo(address)", address(this)));
        _mustFailRaw(account, abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(this), bytes("")));
        _mustFailRaw(account, abi.encodeWithSignature("implementation()"));
    }

    function _creationCode() private returns (bytes memory creationCode) {
        return vm.getCode("src/BossAccount.sol:BossAccount");
    }

    function _mustFailPredict(BossFactory factory, bytes memory creationCode) private {
        (bool success,) = address(factory).call(
            abi.encodeCall(
                BossFactory.predictAccount,
                (OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION, creationCode)
            )
        );
        require(!success, "invalid creation code predicted");
    }

    function _mustFailCreate(BossFactory factory, bytes memory creationCode) private {
        (bool success,) = address(factory).call(
            abi.encodeCall(
                BossFactory.createAccount,
                (OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION, creationCode)
            )
        );
        require(!success, "invalid creation code deployed");
    }

    function _mustFail(FactoryActor actor, address target, bytes memory callData) private {
        (bool success,) = actor.execute(target, callData);
        require(!success, "expected failure");
    }

    function _mustFailRaw(address target, bytes memory callData) private {
        (bool success,) = target.call(callData);
        require(!success, "unexpected selector surface");
    }
}
