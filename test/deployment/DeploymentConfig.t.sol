// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {BossDeployment} from "../../src/deployment/BossDeployment.sol";

contract DeploymentDependency {}

contract DeploymentStateView {
    address public immutable service;

    constructor(address service_) {
        service = service_;
    }
}

contract DeploymentConfigHarness {
    function validate(BossDeployment.Config memory config) external view {
        BossDeployment.validate(config);
    }
}

contract DeploymentConfigTest is Test {
    DeploymentConfigHarness private harness;
    DeploymentDependency private filecoinPay;
    DeploymentDependency private pdpVerifier;
    DeploymentDependency private fwssService;
    DeploymentStateView private fwssStateView;
    DeploymentDependency private token;

    function setUp() public {
        harness = new DeploymentConfigHarness();
        filecoinPay = new DeploymentDependency();
        pdpVerifier = new DeploymentDependency();
        fwssService = new DeploymentDependency();
        fwssStateView = new DeploymentStateView(address(fwssService));
        token = new DeploymentDependency();
    }

    function testValidateAcceptsExactChainCodeAndStateViewTuple() public view {
        harness.validate(_config());
    }

    function testValidateRejectsWrongChainBeforeAnyDeployment() public {
        BossDeployment.Config memory config = _config();
        config.chainId = block.chainid + 1;

        vm.expectRevert(abi.encodeWithSelector(BossDeployment.WrongChain.selector, block.chainid + 1, block.chainid));
        harness.validate(config);
    }

    function testValidateRejectsZeroDependencyAddress() public {
        BossDeployment.Config memory config = _config();
        config.filecoinPay.target = address(0);

        vm.expectRevert(abi.encodeWithSelector(BossDeployment.InvalidDependency.selector, bytes32("filecoinPay")));
        harness.validate(config);
    }

    function testValidateRejectsZeroExpectedCodeHash() public {
        BossDeployment.Config memory config = _config();
        config.token.runtimeCodeHash = bytes32(0);

        vm.expectRevert(abi.encodeWithSelector(BossDeployment.InvalidDependency.selector, bytes32("token")));
        harness.validate(config);
    }

    function testValidateRejectsAddressWithoutCode() public {
        BossDeployment.Config memory config = _config();
        config.pdpVerifier = BossDeployment.Dependency({target: address(0xBEEF), runtimeCodeHash: bytes32(uint256(1))});

        vm.expectRevert(
            abi.encodeWithSelector(BossDeployment.DependencyHasNoCode.selector, bytes32("pdpVerifier"), address(0xBEEF))
        );
        harness.validate(config);
    }

    function testValidateRejectsWrongRuntimeCodeHash() public {
        BossDeployment.Config memory config = _config();
        bytes32 expected = bytes32(uint256(1));
        config.filecoinPay.runtimeCodeHash = expected;

        vm.expectRevert(
            abi.encodeWithSelector(
                BossDeployment.DependencyCodeHashMismatch.selector,
                bytes32("filecoinPay"),
                address(filecoinPay),
                expected,
                address(filecoinPay).codehash
            )
        );
        harness.validate(config);
    }

    function testValidateRejectsStateViewBoundToDifferentService() public {
        DeploymentDependency otherService = new DeploymentDependency();
        BossDeployment.Config memory config = _config();
        config.fwssStateView = _dependency(address(new DeploymentStateView(address(otherService))));

        vm.expectRevert(
            abi.encodeWithSelector(
                BossDeployment.StateViewServiceMismatch.selector, address(fwssService), address(otherService)
            )
        );
        harness.validate(config);
    }

    function testValidateRejectsStateViewWithoutRequiredInterface() public {
        DeploymentDependency invalidStateView = new DeploymentDependency();
        BossDeployment.Config memory config = _config();
        config.fwssStateView = _dependency(address(invalidStateView));

        vm.expectRevert(
            abi.encodeWithSelector(
                BossDeployment.DependencyInterfaceMismatch.selector, bytes32("fwssStateView"), address(invalidStateView)
            )
        );
        harness.validate(config);
    }

    function _config() private view returns (BossDeployment.Config memory config) {
        config = BossDeployment.Config({
            chainId: block.chainid,
            governance: address(this),
            filecoinPay: _dependency(address(filecoinPay)),
            pdpVerifier: _dependency(address(pdpVerifier)),
            fwssService: _dependency(address(fwssService)),
            fwssStateView: _dependency(address(fwssStateView)),
            token: _dependency(address(token))
        });
    }

    function _dependency(address target) private view returns (BossDeployment.Dependency memory dependency) {
        dependency = BossDeployment.Dependency({target: target, runtimeCodeHash: target.codehash});
    }
}
