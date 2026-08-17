// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {BossAdapterRegistry} from "../BossAdapterRegistry.sol";
import {BossBundles} from "../BossBundles.sol";
import {BossFactory} from "../BossFactory.sol";
import {IFWSSStateView} from "../interfaces/IFWSSStateView.sol";
import {BossTypes} from "../libraries/BossTypes.sol";

interface IBossDeploymentResourceAdapter {
    function pdpVerifier() external view returns (address);
    function fwssService() external view returns (address);
    function fwssStateView() external view returns (address);
}

interface IBossDeploymentAccount {
    function owner() external view returns (address);
    function payer() external view returns (address);
    function filecoinPay() external view returns (address);
    function serviceRegistry() external view returns (address);
    function adapterRegistry() external view returns (address);
    function factory() external view returns (address);
    function accountVersion() external view returns (uint64);
}

/// @notice Shared deployment configuration and exact post-deployment verification.
/// @dev This library is consumed by Foundry scripts and deployment tests; it is not a protocol authority.
library BossDeployment {
    bytes32 internal constant FILECOIN_PAY = "filecoinPay";
    bytes32 internal constant PDP_VERIFIER = "pdpVerifier";
    bytes32 internal constant FWSS_SERVICE = "fwssService";
    bytes32 internal constant FWSS_STATE_VIEW = "fwssStateView";
    bytes32 internal constant TOKEN = "token";

    struct Dependency {
        address target;
        bytes32 runtimeCodeHash;
    }

    struct Config {
        uint256 chainId;
        address governance;
        Dependency filecoinPay;
        Dependency pdpVerifier;
        Dependency fwssService;
        Dependency fwssStateView;
        Dependency token;
    }

    struct Suite {
        address factory;
        address serviceRegistry;
        address adapterRegistry;
        address bundles;
        address stateView;
        address flatRateAdapter;
        address pdpCapacityAdapter;
        address cappedMeteredAdapter;
        address fwssPdpResourceAdapter;
        address smokeAccount;
        address smokeOwner;
    }

    error WrongChain(uint256 expected, uint256 observed);
    error InvalidGovernance();
    error InvalidDependency(bytes32 dependency);
    error DependencyHasNoCode(bytes32 dependency, address target);
    error DependencyCodeHashMismatch(bytes32 dependency, address target, bytes32 expected, bytes32 observed);
    error DependencyInterfaceMismatch(bytes32 dependency, address target);
    error StateViewServiceMismatch(address expected, address observed);
    error MissingDeployment(bytes32 contractName);
    error TopologyMismatch(bytes32 field, address expected, address observed);
    error HashMismatch(bytes32 field, bytes32 expected, bytes32 observed);
    error AdapterRecordMismatch(address adapter, BossTypes.AdapterKind expectedKind);
    error SmokeAccountMismatch(bytes32 field, address expected, address observed);
    error SmokeAccountVersionMismatch(uint64 expected, uint64 observed);

    function validate(Config memory config) internal view {
        if (config.chainId != block.chainid) revert WrongChain(config.chainId, block.chainid);
        if (config.governance == address(0)) revert InvalidGovernance();

        _validateDependency(FILECOIN_PAY, config.filecoinPay);
        _validateDependency(PDP_VERIFIER, config.pdpVerifier);
        _validateDependency(FWSS_SERVICE, config.fwssService);
        _validateDependency(FWSS_STATE_VIEW, config.fwssStateView);
        _validateDependency(TOKEN, config.token);

        (bool success, bytes memory output) =
            config.fwssStateView.target.staticcall(abi.encodeCall(IFWSSStateView.service, ()));
        if (!success || output.length < 32) {
            revert DependencyInterfaceMismatch(FWSS_STATE_VIEW, config.fwssStateView.target);
        }
        address observedService = abi.decode(output, (address));
        if (observedService != config.fwssService.target) {
            revert StateViewServiceMismatch(config.fwssService.target, observedService);
        }
    }

    function verify(Config memory config, Suite memory suite, bytes32 expectedCreationHash) internal view {
        validate(config);

        _requireCode("BossFactory", suite.factory);
        _requireCode("BossServiceRegistry", suite.serviceRegistry);
        _requireCode("BossAdapterRegistry", suite.adapterRegistry);
        _requireCode("BossBundles", suite.bundles);
        _requireCode("BossStateView", suite.stateView);
        _requireCode("FlatRateAdapter", suite.flatRateAdapter);
        _requireCode("PDPCapacityAdapter", suite.pdpCapacityAdapter);
        _requireCode("CappedMeteredAdapter", suite.cappedMeteredAdapter);
        _requireCode("FWSSPDPResourceAdapter", suite.fwssPdpResourceAdapter);
        _requireCode("BossAccount", suite.smokeAccount);

        BossFactory factory = BossFactory(suite.factory);
        bytes32 observedCreationHash = factory.accountCreationCodeHash();
        if (observedCreationHash != expectedCreationHash) {
            revert HashMismatch("accountCreationCodeHash", expectedCreationHash, observedCreationHash);
        }

        address observedBundles = factory.bundles();
        if (observedBundles != suite.bundles) {
            revert TopologyMismatch("factory.bundles", suite.bundles, observedBundles);
        }
        address observedFactory = BossBundles(suite.bundles).factory();
        if (observedFactory != suite.factory) {
            revert TopologyMismatch("bundles.factory", suite.factory, observedFactory);
        }

        address observedGovernance = BossAdapterRegistry(suite.adapterRegistry).governance();
        if (observedGovernance != config.governance) {
            revert TopologyMismatch("adapterRegistry.governance", config.governance, observedGovernance);
        }

        _verifyAdapter(suite.adapterRegistry, suite.flatRateAdapter, BossTypes.AdapterKind.PRICING);
        _verifyAdapter(suite.adapterRegistry, suite.pdpCapacityAdapter, BossTypes.AdapterKind.PRICING);
        _verifyAdapter(suite.adapterRegistry, suite.cappedMeteredAdapter, BossTypes.AdapterKind.PRICING);
        _verifyAdapter(suite.adapterRegistry, suite.fwssPdpResourceAdapter, BossTypes.AdapterKind.RESOURCE);

        IBossDeploymentResourceAdapter resourceAdapter = IBossDeploymentResourceAdapter(suite.fwssPdpResourceAdapter);
        if (resourceAdapter.pdpVerifier() != config.pdpVerifier.target) {
            revert TopologyMismatch(
                "resourceAdapter.pdpVerifier", config.pdpVerifier.target, resourceAdapter.pdpVerifier()
            );
        }
        if (resourceAdapter.fwssService() != config.fwssService.target) {
            revert TopologyMismatch(
                "resourceAdapter.fwssService", config.fwssService.target, resourceAdapter.fwssService()
            );
        }
        if (resourceAdapter.fwssStateView() != config.fwssStateView.target) {
            revert TopologyMismatch(
                "resourceAdapter.fwssStateView", config.fwssStateView.target, resourceAdapter.fwssStateView()
            );
        }

        IBossDeploymentAccount smokeAccount = IBossDeploymentAccount(suite.smokeAccount);
        _smokeAddress("owner", suite.smokeOwner, smokeAccount.owner());
        _smokeAddress("payer", suite.smokeOwner, smokeAccount.payer());
        _smokeAddress("filecoinPay", config.filecoinPay.target, smokeAccount.filecoinPay());
        _smokeAddress("serviceRegistry", suite.serviceRegistry, smokeAccount.serviceRegistry());
        _smokeAddress("adapterRegistry", suite.adapterRegistry, smokeAccount.adapterRegistry());
        _smokeAddress("factory", suite.factory, smokeAccount.factory());
        uint64 observedVersion = smokeAccount.accountVersion();
        if (observedVersion != 1) revert SmokeAccountVersionMismatch(1, observedVersion);

        bytes32 key = factory.accountKey(
            suite.smokeOwner, config.filecoinPay.target, suite.serviceRegistry, suite.adapterRegistry, 1
        );
        address indexedAccount = factory.accountFor(key);
        if (indexedAccount != suite.smokeAccount) {
            revert SmokeAccountMismatch("factory.accountFor", suite.smokeAccount, indexedAccount);
        }
    }

    function _validateDependency(bytes32 name, Dependency memory dependency) private view {
        if (dependency.target == address(0) || dependency.runtimeCodeHash == bytes32(0)) {
            revert InvalidDependency(name);
        }
        if (dependency.target.code.length == 0) revert DependencyHasNoCode(name, dependency.target);
        bytes32 observed = dependency.target.codehash;
        if (observed != dependency.runtimeCodeHash) {
            revert DependencyCodeHashMismatch(name, dependency.target, dependency.runtimeCodeHash, observed);
        }
    }

    function _requireCode(bytes32 name, address target) private view {
        if (target == address(0) || target.code.length == 0) revert MissingDeployment(name);
    }

    function _verifyAdapter(address registryAddress, address adapter, BossTypes.AdapterKind kind) private view {
        BossTypes.AdapterRecord memory record = BossAdapterRegistry(registryAddress).getAdapter(adapter);
        if (
            record.kind != kind || record.interfaceVersion != 1 || record.codeHash != adapter.codehash
                || !record.activeForNewSubscriptions
        ) revert AdapterRecordMismatch(adapter, kind);
    }

    function _smokeAddress(bytes32 field, address expected, address observed) private pure {
        if (observed != expected) revert SmokeAccountMismatch(field, expected, observed);
    }
}
