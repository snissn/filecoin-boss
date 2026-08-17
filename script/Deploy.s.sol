// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {BossAdapterRegistry} from "../src/BossAdapterRegistry.sol";
import {BossFactory} from "../src/BossFactory.sol";
import {BossDeployment} from "../src/deployment/BossDeployment.sol";
import {BossTypes} from "../src/libraries/BossTypes.sol";

abstract contract DeployBase is Script {
    error DeploymentFailed(string artifact);

    function _deploy(uint256 deployerPrivateKey, BossDeployment.Config memory config, address smokeOwner)
        internal
        returns (BossDeployment.Suite memory suite)
    {
        address deployer = vm.addr(deployerPrivateKey);
        if (smokeOwner == address(0)) smokeOwner = deployer;
        BossDeployment.validate(config);

        bytes memory accountCreationCode = vm.getCode("out/BossAccount.sol/BossAccount.json");
        bytes32 accountCreationCodeHash = keccak256(accountCreationCode);

        vm.startBroadcast(deployerPrivateKey);

        suite.serviceRegistry = _create("out/BossServiceRegistry.sol/BossServiceRegistry.json", "");
        suite.adapterRegistry = _create("out/BossAdapterRegistry.sol/BossAdapterRegistry.json", abi.encode(deployer));
        suite.factory = _create("out/BossFactory.sol/BossFactory.json", "");
        suite.bundles = BossFactory(suite.factory).bundles();
        suite.stateView = _create("out/BossStateView.sol/BossStateView.json", "");
        suite.flatRateAdapter = _create("out/FlatRateAdapter.sol/FlatRateAdapter.json", "");
        suite.pdpCapacityAdapter = _create("out/PDPCapacityAdapter.sol/PDPCapacityAdapter.json", "");
        suite.cappedMeteredAdapter = _create("out/CappedMeteredAdapter.sol/CappedMeteredAdapter.json", "");
        suite.fwssPdpResourceAdapter = _create(
            "out/FWSSPDPResourceAdapter.sol/FWSSPDPResourceAdapter.json",
            abi.encode(config.pdpVerifier.target, config.fwssService.target, config.fwssStateView.target)
        );

        BossAdapterRegistry registry = BossAdapterRegistry(suite.adapterRegistry);
        registry.registerAdapter(
            suite.flatRateAdapter, BossTypes.AdapterKind.PRICING, 1, "filecoin-boss://pricing/flat/v1"
        );
        registry.registerAdapter(
            suite.pdpCapacityAdapter, BossTypes.AdapterKind.PRICING, 1, "filecoin-boss://pricing/pdp-capacity/v1"
        );
        registry.registerAdapter(
            suite.cappedMeteredAdapter, BossTypes.AdapterKind.PRICING, 1, "filecoin-boss://pricing/capped-metered/v1"
        );
        registry.registerAdapter(
            suite.fwssPdpResourceAdapter, BossTypes.AdapterKind.RESOURCE, 1, "filecoin-boss://resource/fwss-pdp/v1"
        );
        if (config.governance != deployer) registry.transferGovernance(config.governance);

        suite.smokeOwner = smokeOwner;
        suite.smokeAccount = BossFactory(suite.factory).createAccount(
            smokeOwner, config.filecoinPay.target, suite.serviceRegistry, suite.adapterRegistry, 1, accountCreationCode
        );

        vm.stopBroadcast();

        BossDeployment.verify(config, suite, accountCreationCodeHash);
        _writeSuiteSummary(config, deployer, suite, accountCreationCodeHash);
        _logDeployment(config, deployer, suite);
    }

    function _create(string memory artifact, bytes memory constructorArguments) internal returns (address deployed) {
        bytes memory creationCode = vm.getCode(artifact);
        bytes memory initCode = abi.encodePacked(creationCode, constructorArguments);
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (deployed == address(0)) revert DeploymentFailed(artifact);
    }

    function _configFromEnvironment() internal view returns (BossDeployment.Config memory config) {
        config.chainId = vm.envUint("BOSS_CHAIN_ID");
        config.governance = vm.envAddress("BOSS_GOVERNANCE");
        config.filecoinPay = BossDeployment.Dependency({
            target: vm.envAddress("BOSS_FILECOIN_PAY"),
            runtimeCodeHash: vm.envBytes32("BOSS_FILECOIN_PAY_CODE_HASH")
        });
        config.pdpVerifier = BossDeployment.Dependency({
            target: vm.envAddress("BOSS_PDP_VERIFIER"),
            runtimeCodeHash: vm.envBytes32("BOSS_PDP_VERIFIER_CODE_HASH")
        });
        config.fwssService = BossDeployment.Dependency({
            target: vm.envAddress("BOSS_FWSS_SERVICE"),
            runtimeCodeHash: vm.envBytes32("BOSS_FWSS_SERVICE_CODE_HASH")
        });
        config.fwssStateView = BossDeployment.Dependency({
            target: vm.envAddress("BOSS_FWSS_STATE_VIEW"),
            runtimeCodeHash: vm.envBytes32("BOSS_FWSS_STATE_VIEW_CODE_HASH")
        });
        config.token = BossDeployment.Dependency({
            target: vm.envAddress("BOSS_TOKEN"),
            runtimeCodeHash: vm.envBytes32("BOSS_TOKEN_CODE_HASH")
        });
    }

    function _writeSuiteSummary(
        BossDeployment.Config memory config,
        address deployer,
        BossDeployment.Suite memory suite,
        bytes32 accountCreationCodeHash
    ) internal {
        string memory output = vm.envString("BOSS_SUITE_OUTPUT");
        string memory objectKey = "bossDeployment";

        vm.serializeUint(objectKey, "chainId", config.chainId);
        vm.serializeAddress(objectKey, "deployer", deployer);
        vm.serializeAddress(objectKey, "governance", config.governance);
        vm.serializeAddress(objectKey, "dependencyFilecoinPay", config.filecoinPay.target);
        vm.serializeBytes32(objectKey, "dependencyFilecoinPayCodeHash", config.filecoinPay.runtimeCodeHash);
        vm.serializeAddress(objectKey, "dependencyPdpVerifier", config.pdpVerifier.target);
        vm.serializeBytes32(objectKey, "dependencyPdpVerifierCodeHash", config.pdpVerifier.runtimeCodeHash);
        vm.serializeAddress(objectKey, "dependencyFwssService", config.fwssService.target);
        vm.serializeBytes32(objectKey, "dependencyFwssServiceCodeHash", config.fwssService.runtimeCodeHash);
        vm.serializeAddress(objectKey, "dependencyFwssStateView", config.fwssStateView.target);
        vm.serializeBytes32(objectKey, "dependencyFwssStateViewCodeHash", config.fwssStateView.runtimeCodeHash);
        vm.serializeAddress(objectKey, "dependencyToken", config.token.target);
        vm.serializeBytes32(objectKey, "dependencyTokenCodeHash", config.token.runtimeCodeHash);
        vm.serializeAddress(objectKey, "contractBossFactory", suite.factory);
        vm.serializeAddress(objectKey, "contractBossServiceRegistry", suite.serviceRegistry);
        vm.serializeAddress(objectKey, "contractBossAdapterRegistry", suite.adapterRegistry);
        vm.serializeAddress(objectKey, "contractBossBundles", suite.bundles);
        vm.serializeAddress(objectKey, "contractBossStateView", suite.stateView);
        vm.serializeAddress(objectKey, "contractFlatRateAdapter", suite.flatRateAdapter);
        vm.serializeAddress(objectKey, "contractPDPCapacityAdapter", suite.pdpCapacityAdapter);
        vm.serializeAddress(objectKey, "contractCappedMeteredAdapter", suite.cappedMeteredAdapter);
        vm.serializeAddress(objectKey, "contractFWSSPDPResourceAdapter", suite.fwssPdpResourceAdapter);
        vm.serializeAddress(objectKey, "smokeOwner", suite.smokeOwner);
        vm.serializeAddress(objectKey, "smokeAccount", suite.smokeAccount);
        string memory json = vm.serializeBytes32(objectKey, "accountCreationCodeHash", accountCreationCodeHash);
        vm.writeJson(json, output);
    }

    function _logDeployment(BossDeployment.Config memory config, address deployer, BossDeployment.Suite memory suite)
        internal
        view
    {
        console2.log("BOSS_DEPLOYER", deployer);
        console2.log("BOSS_GOVERNANCE", config.governance);
        console2.log("BossFactory", suite.factory);
        console2.log("BossServiceRegistry", suite.serviceRegistry);
        console2.log("BossAdapterRegistry", suite.adapterRegistry);
        console2.log("BossBundles", suite.bundles);
        console2.log("BossStateView", suite.stateView);
        console2.log("FlatRateAdapter", suite.flatRateAdapter);
        console2.log("PDPCapacityAdapter", suite.pdpCapacityAdapter);
        console2.log("CappedMeteredAdapter", suite.cappedMeteredAdapter);
        console2.log("FWSSPDPResourceAdapter", suite.fwssPdpResourceAdapter);
        console2.log("BOSS_SMOKE_OWNER", suite.smokeOwner);
        console2.log("BOSS_SMOKE_ACCOUNT", suite.smokeAccount);
    }
}

/// @notice Deploys Boss against an exact, caller-supplied dependency tuple.
/// @dev Every dependency address and runtime code hash is required through environment variables.
contract Deploy is DeployBase {
    function run() external returns (BossDeployment.Suite memory suite) {
        uint256 deployerPrivateKey = vm.envUint("BOSS_DEPLOYER_PRIVATE_KEY");
        address smokeOwner = vm.envOr("BOSS_SMOKE_OWNER", vm.addr(deployerPrivateKey));
        suite = _deploy(deployerPrivateKey, _configFromEnvironment(), smokeOwner);
    }
}
