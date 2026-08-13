// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossAccount} from "../../src/BossAccount.sol";
import {BossFactory} from "../../src/BossFactory.sol";

interface VmFactoryLogs {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}

contract FactoryActor {
    function execute(address target, bytes calldata callData) external returns (bool success, bytes memory result) {
        return target.call(callData);
    }
}

contract BossFactoryTest {
    VmFactoryLogs internal constant vm =
        VmFactoryLogs(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant OWNER = address(0xA11CE);
    address internal constant FILECOIN_PAY = address(0xF11E);
    address internal constant SERVICE_REGISTRY = address(0x5100);
    address internal constant ADAPTER_REGISTRY = address(0xADA7);
    uint64 internal constant VERSION = 1;

    function testPredictionDeploymentMappingAndEventAreDeterministic() public {
        BossFactory factory = new BossFactory();
        bytes32 expectedKey = factory.accountKey(
            OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION
        );
        address predicted = factory.predictAccount(
            OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION
        );
        require(predicted.code.length == 0, "predicted address initially empty");

        vm.recordLogs();
        address account = factory.createAccount(
            OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION
        );
        VmFactoryLogs.Log[] memory logs = vm.getRecordedLogs();

        require(account == predicted, "prediction parity");
        require(account.code.length != 0, "account deployed");
        require(factory.accountFor(expectedKey) == account, "account mapping");
        require(logs.length == 1, "creation log count");
        require(logs[0].emitter == address(factory), "creation emitter");
        require(logs[0].topics.length == 4, "creation topics");
        require(
            logs[0].topics[0]
                == keccak256("BossAccountCreated(address,address,address,address,address,uint64,bytes32)"),
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

    function testCreateIsIdempotent() public {
        BossFactory factory = new BossFactory();
        address first = factory.createAccount(
            OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION
        );
        address second = factory.createAccount(
            OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION
        );

        require(first == second, "idempotent address");
        require(first.code.length != 0, "idempotent code");
    }

    function testEveryAuthorityAndConfigurationInputAffectsAddress() public view {
        BossFactory factory = new BossFactory();
        address base = factory.predictAccount(
            OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION
        );

        require(
            base
                != factory.predictAccount(
                    address(0xB0B), FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION
                ),
            "owner affects address"
        );
        require(
            base
                != factory.predictAccount(
                    OWNER, address(0xF22E), SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION
                ),
            "pay affects address"
        );
        require(
            base
                != factory.predictAccount(
                    OWNER, FILECOIN_PAY, address(0x5200), ADAPTER_REGISTRY, VERSION
                ),
            "service registry affects address"
        );
        require(
            base
                != factory.predictAccount(
                    OWNER, FILECOIN_PAY, SERVICE_REGISTRY, address(0xADA8), VERSION
                ),
            "adapter registry affects address"
        );
        require(
            base
                != factory.predictAccount(
                    OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION + 1
                ),
            "version affects address"
        );
    }

    function testAnyoneMayDeployButCannotAcquireOwnerAuthority() public {
        BossFactory factory = new BossFactory();
        FactoryActor deployer = new FactoryActor();

        (bool success, bytes memory result) = deployer.execute(
            address(factory),
            abi.encodeCall(
                BossFactory.createAccount,
                (OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION)
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

        _mustFail(
            caller,
            address(factory),
            abi.encodeCall(
                BossFactory.createAccount,
                (address(0), FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION)
            )
        );
        _mustFail(
            caller,
            address(factory),
            abi.encodeCall(
                BossFactory.createAccount,
                (OWNER, address(0), SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION)
            )
        );
        _mustFail(
            caller,
            address(factory),
            abi.encodeCall(
                BossFactory.createAccount,
                (OWNER, FILECOIN_PAY, address(0), ADAPTER_REGISTRY, VERSION)
            )
        );
        _mustFail(
            caller,
            address(factory),
            abi.encodeCall(
                BossFactory.createAccount,
                (OWNER, FILECOIN_PAY, SERVICE_REGISTRY, address(0), VERSION)
            )
        );
        _mustFail(
            caller,
            address(factory),
            abi.encodeCall(
                BossFactory.createAccount,
                (OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, uint64(0))
            )
        );
    }

    function testAccountHasNoInitializationOwnershipTransferOrUpgradeSurface() public {
        BossFactory factory = new BossFactory();
        address account = factory.createAccount(
            OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION
        );

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

    function _mustFail(FactoryActor actor, address target, bytes memory callData) private {
        (bool success,) = actor.execute(target, callData);
        require(!success, "expected failure");
    }

    function _mustFailRaw(address target, bytes memory callData) private {
        (bool success,) = target.call(callData);
        require(!success, "unexpected selector surface");
    }
}
