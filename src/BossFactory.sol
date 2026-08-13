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

    mapping(bytes32 accountKey_ => address account) public accountFor;

    function accountKey(
        address owner,
        address filecoinPay,
        address serviceRegistry,
        address adapterRegistry,
        uint64 accountVersion
    ) public pure returns (bytes32) {
        _validate(owner, filecoinPay, serviceRegistry, adapterRegistry, accountVersion);
        return keccak256(
            abi.encode(
                "FILECOIN_BOSS_ACCOUNT_V1",
                owner,
                filecoinPay,
                serviceRegistry,
                adapterRegistry,
                accountVersion
            )
        );
    }

    function predictAccount(
        address owner,
        address filecoinPay,
        address serviceRegistry,
        address adapterRegistry,
        uint64 accountVersion
    ) public view returns (address account) {
        bytes32 key = accountKey(owner, filecoinPay, serviceRegistry, adapterRegistry, accountVersion);
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(BossAccount).creationCode,
                abi.encode(owner, filecoinPay, serviceRegistry, adapterRegistry, accountVersion)
            )
        );
        account = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), key, initCodeHash))
                )
            )
        );
    }

    function createAccount(
        address owner,
        address filecoinPay,
        address serviceRegistry,
        address adapterRegistry,
        uint64 accountVersion
    ) external returns (address account) {
        bytes32 key = accountKey(owner, filecoinPay, serviceRegistry, adapterRegistry, accountVersion);
        account = accountFor[key];
        if (account != address(0)) return account;

        address predicted = predictAccount(
            owner, filecoinPay, serviceRegistry, adapterRegistry, accountVersion
        );
        account = address(
            new BossAccount{salt: key}(
                owner, filecoinPay, serviceRegistry, adapterRegistry, accountVersion
            )
        );
        if (account != predicted) revert UnexpectedDeploymentAddress(predicted, account);

        accountFor[key] = account;
        emit BossAccountCreated(
            owner,
            account,
            filecoinPay,
            serviceRegistry,
            adapterRegistry,
            accountVersion,
            key
        );
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
        if (accountVersion == 0) revert InvalidAccountVersion();
    }
}
