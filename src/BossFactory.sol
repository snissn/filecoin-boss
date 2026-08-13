// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {BossAccount} from "./BossAccount.sol";

/// @notice Deterministically deploys one immutable Boss account per payer/configuration.
contract BossFactory {
    error InvalidOwner();
    error InvalidFilecoinPay();
    error InvalidServiceRegistry();
    error InvalidAdapterRegistry();
    error InvalidAccountVersion();
    error InvalidAccountCreationCode(bytes32 expected, bytes32 observed);
    error AccountDeploymentFailed(bytes32 accountKey);
    error UnexpectedDeploymentAddress(address predicted, address deployed);

    event BossAccountCreated(
        address indexed owner,
        address indexed account,
        address indexed filecoinPay,
        address serviceRegistry,
        address adapterRegistry,
        uint64 accountVersion,
        bytes32 accountKey
    );

    bytes32 public immutable accountCreationCodeHash;
    mapping(bytes32 accountKey_ => address account) public accountFor;

    constructor() {
        accountCreationCodeHash = keccak256(type(BossAccount).creationCode);
    }

    function accountKey(
        address owner,
        address filecoinPay,
        address serviceRegistry,
        address adapterRegistry,
        uint64 accountVersion
    ) public pure returns (bytes32) {
        _validate(owner, filecoinPay, serviceRegistry, adapterRegistry, accountVersion);
        return keccak256(
            abi.encode("FILECOIN_BOSS_ACCOUNT_V1", owner, filecoinPay, serviceRegistry, adapterRegistry, accountVersion)
        );
    }

    function predictAccount(
        address owner,
        address filecoinPay,
        address serviceRegistry,
        address adapterRegistry,
        uint64 accountVersion,
        bytes calldata accountCreationCode
    ) external view returns (address account) {
        bytes32 key = accountKey(owner, filecoinPay, serviceRegistry, adapterRegistry, accountVersion);
        bytes memory initCode = _accountInitCode(
            accountCreationCode, owner, filecoinPay, serviceRegistry, adapterRegistry, accountVersion
        );
        account = _predict(key, keccak256(initCode));
    }

    function createAccount(
        address owner,
        address filecoinPay,
        address serviceRegistry,
        address adapterRegistry,
        uint64 accountVersion,
        bytes calldata accountCreationCode
    ) external returns (address account) {
        bytes32 key = accountKey(owner, filecoinPay, serviceRegistry, adapterRegistry, accountVersion);
        _requireCanonicalCreationCode(accountCreationCode);

        account = accountFor[key];
        if (account != address(0)) return account;

        bytes memory initCode = abi.encodePacked(
            accountCreationCode,
            abi.encode(owner, filecoinPay, serviceRegistry, adapterRegistry, accountVersion)
        );
        address predicted = _predict(key, keccak256(initCode));
        assembly ("memory-safe") {
            account := create2(0, add(initCode, 0x20), mload(initCode), key)
        }
        if (account == address(0)) revert AccountDeploymentFailed(key);
        if (account != predicted) revert UnexpectedDeploymentAddress(predicted, account);

        accountFor[key] = account;
        emit BossAccountCreated(owner, account, filecoinPay, serviceRegistry, adapterRegistry, accountVersion, key);
    }

    function _accountInitCode(
        bytes calldata accountCreationCode,
        address owner,
        address filecoinPay,
        address serviceRegistry,
        address adapterRegistry,
        uint64 accountVersion
    ) private view returns (bytes memory initCode) {
        _requireCanonicalCreationCode(accountCreationCode);
        initCode = abi.encodePacked(
            accountCreationCode,
            abi.encode(owner, filecoinPay, serviceRegistry, adapterRegistry, accountVersion)
        );
    }

    function _requireCanonicalCreationCode(bytes calldata accountCreationCode) private view {
        bytes32 observed = keccak256(accountCreationCode);
        bytes32 expected = accountCreationCodeHash;
        if (observed != expected) revert InvalidAccountCreationCode(expected, observed);
    }

    function _predict(bytes32 key, bytes32 initCodeHash) private view returns (address account) {
        account = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), key, initCodeHash)))));
    }

    function _validate(
        address owner,
        address filecoinPay,
        address serviceRegistry,
        address adapterRegistry,
        uint64 accountVersion
    ) private pure {
        if (owner == address(0)) revert InvalidOwner();
        if (filecoinPay == address(0)) revert InvalidFilecoinPay();
        if (serviceRegistry == address(0)) revert InvalidServiceRegistry();
        if (adapterRegistry == address(0)) revert InvalidAdapterRegistry();
        if (accountVersion != 1) revert InvalidAccountVersion();
    }
}
