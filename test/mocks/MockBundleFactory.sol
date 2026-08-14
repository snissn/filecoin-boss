// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IMockBundleAccountConfig {
    function owner() external view returns (address);
    function payer() external view returns (address);
    function filecoinPay() external view returns (address);
    function serviceRegistry() external view returns (address);
    function adapterRegistry() external view returns (address);
    function accountVersion() external view returns (uint64);
}

contract MockBundleFactory {
    mapping(bytes32 accountKey_ => address account) public accountFor;

    function accountKey(
        address owner,
        address filecoinPay,
        address serviceRegistry,
        address adapterRegistry,
        uint64 accountVersion
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode("FILECOIN_BOSS_ACCOUNT_V1", owner, filecoinPay, serviceRegistry, adapterRegistry, accountVersion)
        );
    }

    function register(address account) external {
        IMockBundleAccountConfig configured = IMockBundleAccountConfig(account);
        bytes32 key = accountKey(
            configured.owner(),
            configured.filecoinPay(),
            configured.serviceRegistry(),
            configured.adapterRegistry(),
            configured.accountVersion()
        );
        require(configured.payer() == configured.owner(), "payer mismatch");
        accountFor[key] = account;
    }
}
