// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FilecoinPayV1} from "filecoin-pay/FilecoinPayV1.sol";

import {BossDeployment} from "../src/deployment/BossDeployment.sol";
import {DeployBase} from "./Deploy.s.sol";
import {
    LocalMockFWSSService,
    LocalMockFWSSStateView,
    LocalMockPDPVerifier,
    LocalMockToken
} from "./LocalDeploymentDependencies.sol";

/// @notice Deterministic local qualification deployment with the locked Filecoin Pay V1 contract.
/// @dev The PDP/FWSS/token dependencies are explicit test doubles and are never public-network evidence.
contract DeployLocal is DeployBase {
    function run() external returns (BossDeployment.Suite memory suite) {
        uint256 deployerPrivateKey = vm.envUint("BOSS_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address finalGovernance = vm.envOr("BOSS_GOVERNANCE", deployer);
        address smokeOwner = vm.envOr("BOSS_SMOKE_OWNER", deployer);

        vm.startBroadcast(deployerPrivateKey);
        address filecoinPay = address(new FilecoinPayV1());
        address pdpVerifier = address(new LocalMockPDPVerifier());
        address fwssService = address(new LocalMockFWSSService());
        address fwssStateView = address(new LocalMockFWSSStateView(fwssService));
        address token = address(new LocalMockToken());
        vm.stopBroadcast();

        BossDeployment.Config memory config = BossDeployment.Config({
            chainId: block.chainid,
            governance: finalGovernance,
            filecoinPay: BossDeployment.Dependency({target: filecoinPay, runtimeCodeHash: filecoinPay.codehash}),
            pdpVerifier: BossDeployment.Dependency({target: pdpVerifier, runtimeCodeHash: pdpVerifier.codehash}),
            fwssService: BossDeployment.Dependency({target: fwssService, runtimeCodeHash: fwssService.codehash}),
            fwssStateView: BossDeployment.Dependency({target: fwssStateView, runtimeCodeHash: fwssStateView.codehash}),
            token: BossDeployment.Dependency({target: token, runtimeCodeHash: token.codehash})
        });

        suite = _deploy(deployerPrivateKey, config, smokeOwner);
    }
}
