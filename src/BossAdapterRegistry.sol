// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {BossTypes} from "./libraries/BossTypes.sol";

/// @notice Governance-controlled allowlist of exact resource and pricing adapter bytecode.
contract BossAdapterRegistry {
    error Unauthorized(address caller);
    error InvalidGovernance();
    error GovernanceUnchanged();
    error InvalidAdapter();
    error AdapterHasNoCode(address adapter);
    error InvalidInterfaceVersion();
    error AdapterAlreadyRegistered(address adapter);
    error AdapterNotRegistered(address adapter);
    error AdapterStateUnchanged(address adapter, bool active);
    error AdapterCodeHashMismatch(address adapter, bytes32 expected, bytes32 observed);

    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);
    event AdapterRegistered(
        address indexed adapter,
        BossTypes.AdapterKind kind,
        uint64 interfaceVersion,
        bytes32 codeHash,
        string metadataURI
    );
    event AdapterActivationChanged(address indexed adapter, bool activeForNewSubscriptions, bytes32 observedCodeHash);

    address public governance;

    mapping(address adapter => bool registered) private _registered;
    mapping(address adapter => BossTypes.AdapterRecord record) private _adapters;

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized(msg.sender);
        _;
    }

    constructor(address governance_) {
        if (governance_ == address(0)) revert InvalidGovernance();
        governance = governance_;
        emit GovernanceTransferred(address(0), governance_);
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidGovernance();
        if (newGovernance == governance) revert GovernanceUnchanged();

        address previous = governance;
        governance = newGovernance;
        emit GovernanceTransferred(previous, newGovernance);
    }

    function registerAdapter(
        address adapter,
        BossTypes.AdapterKind kind,
        uint64 interfaceVersion,
        string calldata metadataURI
    ) external onlyGovernance {
        if (adapter == address(0)) revert InvalidAdapter();
        if (adapter.code.length == 0) revert AdapterHasNoCode(adapter);
        if (interfaceVersion == 0) revert InvalidInterfaceVersion();
        if (_registered[adapter]) revert AdapterAlreadyRegistered(adapter);

        bytes32 codeHash = adapter.codehash;
        _registered[adapter] = true;
        _adapters[adapter] = BossTypes.AdapterRecord({
            kind: kind,
            interfaceVersion: interfaceVersion,
            codeHash: codeHash,
            activeForNewSubscriptions: true,
            metadataURI: metadataURI
        });

        emit AdapterRegistered(adapter, kind, interfaceVersion, codeHash, metadataURI);
    }

    function setAdapterActive(address adapter, bool active) external onlyGovernance {
        if (!_registered[adapter]) revert AdapterNotRegistered(adapter);

        BossTypes.AdapterRecord storage record = _adapters[adapter];
        if (record.activeForNewSubscriptions == active) {
            revert AdapterStateUnchanged(adapter, active);
        }

        bytes32 observedCodeHash = adapter.codehash;
        if (active) {
            if (adapter.code.length == 0) revert AdapterHasNoCode(adapter);
            if (observedCodeHash != record.codeHash) {
                revert AdapterCodeHashMismatch(adapter, record.codeHash, observedCodeHash);
            }
        }

        record.activeForNewSubscriptions = active;
        emit AdapterActivationChanged(adapter, active, observedCodeHash);
    }

    function getAdapter(address adapter) external view returns (BossTypes.AdapterRecord memory record) {
        return _adapters[adapter];
    }

    function isRegistered(address adapter) external view returns (bool) {
        return _registered[adapter];
    }

    function isActive(address adapter, BossTypes.AdapterKind expectedKind, uint64 expectedInterfaceVersion)
        external
        view
        returns (bool)
    {
        if (!_registered[adapter]) return false;

        BossTypes.AdapterRecord storage record = _adapters[adapter];
        return record.activeForNewSubscriptions && record.kind == expectedKind
            && record.interfaceVersion == expectedInterfaceVersion && adapter.code.length != 0
            && adapter.codehash == record.codeHash;
    }
}
