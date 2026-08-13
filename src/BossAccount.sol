// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

/// @notice Immutable authority/configuration shell for one payer-owned Boss account version.
/// @dev Lifecycle and payment behavior are added directly to this version before deployment;
///      migration to new behavior uses a new account version and address, not an upgrade hook.
contract BossAccount {
    error InvalidOwner();
    error InvalidFilecoinPay();
    error InvalidServiceRegistry();
    error InvalidAdapterRegistry();
    error InvalidAccountVersion();

    address public immutable owner;
    address public immutable payer;
    address public immutable filecoinPay;
    address public immutable serviceRegistry;
    address public immutable adapterRegistry;
    address public immutable factory;
    uint64 public immutable accountVersion;

    constructor(
        address owner_,
        address filecoinPay_,
        address serviceRegistry_,
        address adapterRegistry_,
        uint64 accountVersion_
    ) {
        if (owner_ == address(0)) revert InvalidOwner();
        if (filecoinPay_ == address(0)) revert InvalidFilecoinPay();
        if (serviceRegistry_ == address(0)) revert InvalidServiceRegistry();
        if (adapterRegistry_ == address(0)) revert InvalidAdapterRegistry();
        if (accountVersion_ == 0) revert InvalidAccountVersion();

        owner = owner_;
        payer = owner_;
        filecoinPay = filecoinPay_;
        serviceRegistry = serviceRegistry_;
        adapterRegistry = adapterRegistry_;
        accountVersion = accountVersion_;
        factory = msg.sender;
    }
}
