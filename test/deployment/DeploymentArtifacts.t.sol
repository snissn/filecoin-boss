// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {BossAccount} from "../../src/BossAccount.sol";
import {BossAdapterRegistry} from "../../src/BossAdapterRegistry.sol";
import {BossFactory} from "../../src/BossFactory.sol";
import {BossServiceRegistry} from "../../src/BossServiceRegistry.sol";
import {BossStateView} from "../../src/BossStateView.sol";
import {CappedMeteredAdapter} from "../../src/adapters/pricing/CappedMeteredAdapter.sol";
import {FlatRateAdapter} from "../../src/adapters/pricing/FlatRateAdapter.sol";
import {PDPCapacityAdapter} from "../../src/adapters/pricing/PDPCapacityAdapter.sol";
import {FWSSPDPResourceAdapter} from "../../src/adapters/resources/FWSSPDPResourceAdapter.sol";
import {BossDeployment} from "../../src/deployment/BossDeployment.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";

contract ArtifactDependency {}

contract ArtifactStateView {
    address public immutable service;

    constructor(address service_) {
        service = service_;
    }
}

contract DeploymentArtifactsHarness {
    function verify(
        BossDeployment.Config memory config,
        BossDeployment.Suite memory suite,
        bytes32 accountCreationCodeHash
    ) external view {
        BossDeployment.verify(config, suite, accountCreationCodeHash);
    }
}

contract DeploymentArtifactsTest is Test {
    DeploymentArtifactsHarness private harness;
    BossDeployment.Config private config;
    BossDeployment.Suite private suite;
    bytes32 private accountCreationCodeHash;

    function setUp() public {
        harness = new DeploymentArtifactsHarness();

        ArtifactDependency filecoinPay = new ArtifactDependency();
        ArtifactDependency pdpVerifier = new ArtifactDependency();
        ArtifactDependency fwssService = new ArtifactDependency();
        ArtifactStateView fwssStateView = new ArtifactStateView(address(fwssService));
        ArtifactDependency token = new ArtifactDependency();

        BossServiceRegistry serviceRegistry = new BossServiceRegistry();
        BossAdapterRegistry adapterRegistry = new BossAdapterRegistry(address(this));
        BossFactory factory = new BossFactory();
        BossStateView stateView = new BossStateView();
        FlatRateAdapter flatRateAdapter = new FlatRateAdapter();
        PDPCapacityAdapter pdpCapacityAdapter = new PDPCapacityAdapter();
        CappedMeteredAdapter cappedMeteredAdapter = new CappedMeteredAdapter();
        FWSSPDPResourceAdapter resourceAdapter =
            new FWSSPDPResourceAdapter(address(pdpVerifier), address(fwssService), address(fwssStateView));

        adapterRegistry.registerAdapter(
            address(flatRateAdapter), BossTypes.AdapterKind.PRICING, 1, "filecoin-boss://pricing/flat/v1"
        );
        adapterRegistry.registerAdapter(
            address(pdpCapacityAdapter), BossTypes.AdapterKind.PRICING, 1, "filecoin-boss://pricing/pdp-capacity/v1"
        );
        adapterRegistry.registerAdapter(
            address(cappedMeteredAdapter), BossTypes.AdapterKind.PRICING, 1, "filecoin-boss://pricing/capped-metered/v1"
        );
        adapterRegistry.registerAdapter(
            address(resourceAdapter), BossTypes.AdapterKind.RESOURCE, 1, "filecoin-boss://resource/fwss-pdp/v1"
        );

        address smokeOwner = makeAddr("smokeOwner");
        bytes memory creationCode = type(BossAccount).creationCode;
        accountCreationCodeHash = keccak256(creationCode);
        address smokeAccount = factory.createAccount(
            smokeOwner, address(filecoinPay), address(serviceRegistry), address(adapterRegistry), 1, creationCode
        );

        config = BossDeployment.Config({
            chainId: block.chainid,
            governance: address(this),
            filecoinPay: _dependency(address(filecoinPay)),
            pdpVerifier: _dependency(address(pdpVerifier)),
            fwssService: _dependency(address(fwssService)),
            fwssStateView: _dependency(address(fwssStateView)),
            token: _dependency(address(token))
        });
        suite = BossDeployment.Suite({
            factory: address(factory),
            serviceRegistry: address(serviceRegistry),
            adapterRegistry: address(adapterRegistry),
            bundles: factory.bundles(),
            stateView: address(stateView),
            flatRateAdapter: address(flatRateAdapter),
            pdpCapacityAdapter: address(pdpCapacityAdapter),
            cappedMeteredAdapter: address(cappedMeteredAdapter),
            fwssPdpResourceAdapter: address(resourceAdapter),
            smokeAccount: smokeAccount,
            smokeOwner: smokeOwner
        });
    }

    function testVerifyAcceptsCompleteExactDeploymentTopology() public view {
        harness.verify(config, suite, accountCreationCodeHash);
    }

    function testVerifyRejectsMissingContractRuntime() public {
        BossDeployment.Suite memory invalid = suite;
        invalid.stateView = address(0);

        vm.expectRevert(abi.encodeWithSelector(BossDeployment.MissingDeployment.selector, bytes32("BossStateView")));
        harness.verify(config, invalid, accountCreationCodeHash);
    }

    function testVerifyRejectsWrongAccountCreationCodeHash() public {
        bytes32 wrong = bytes32(uint256(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                BossDeployment.HashMismatch.selector, bytes32("accountCreationCodeHash"), wrong, accountCreationCodeHash
            )
        );
        harness.verify(config, suite, wrong);
    }

    function testVerifyRejectsGovernanceDrift() public {
        BossDeployment.Config memory invalid = config;
        invalid.governance = makeAddr("otherGovernance");

        vm.expectRevert(
            abi.encodeWithSelector(
                BossDeployment.TopologyMismatch.selector,
                bytes32("adapterRegistry.governance"),
                invalid.governance,
                config.governance
            )
        );
        harness.verify(invalid, suite, accountCreationCodeHash);
    }

    function testVerifyRejectsSmokeOwnerDrift() public {
        BossDeployment.Suite memory invalid = suite;
        invalid.smokeOwner = makeAddr("otherOwner");

        vm.expectRevert(
            abi.encodeWithSelector(
                BossDeployment.SmokeAccountMismatch.selector, bytes32("owner"), invalid.smokeOwner, suite.smokeOwner
            )
        );
        harness.verify(config, invalid, accountCreationCodeHash);
    }

    function _dependency(address target) private view returns (BossDeployment.Dependency memory dependency) {
        dependency = BossDeployment.Dependency({target: target, runtimeCodeHash: target.codehash});
    }
}
