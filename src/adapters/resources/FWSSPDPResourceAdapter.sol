// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {IBossResourceAdapter} from "../../interfaces/IBossResourceAdapter.sol";
import {IFWSSStateView} from "../../interfaces/IFWSSStateView.sol";
import {IPDPVerifierView} from "../../interfaces/IPDPVerifierView.sol";
import {BossHashes} from "../../libraries/BossHashes.sol";
import {BossTypes} from "../../libraries/BossTypes.sol";

/// @notice Authorizes one exact FWSS/PDP deployment tuple for Boss resource attachment.
contract FWSSPDPResourceAdapter is IBossResourceAdapter {
    error InvalidDeployment();
    error StateViewServiceMismatch(address expected, address observed);
    error InvalidResource();
    error UnexpectedResourceData();
    error InvalidExpectedPayer();
    error DataSetNotLive(uint256 dataSetId);
    error ListenerMismatch(address expected, address observed);
    error DataSetNotActive(uint256 dataSetId);
    error InvalidDataSetRecord(uint256 dataSetId);
    error PayerMismatch(address expected, address observed);
    error StorageProviderMismatch(address pdpProvider, address fwssProvider);

    address public immutable pdpVerifier;
    address public immutable fwssService;
    address public immutable fwssStateView;
    bytes32 public constant resourceContext = bytes32(0);

    constructor(address pdpVerifier_, address fwssService_, address fwssStateView_) {
        if (pdpVerifier_ == address(0) || fwssService_ == address(0) || fwssStateView_ == address(0)) {
            revert InvalidDeployment();
        }
        if (pdpVerifier_.code.length == 0 || fwssStateView_.code.length == 0) revert InvalidDeployment();

        address observedService = IFWSSStateView(fwssStateView_).service();
        if (observedService != fwssService_) {
            revert StateViewServiceMismatch(fwssService_, observedService);
        }

        pdpVerifier = pdpVerifier_;
        fwssService = fwssService_;
        fwssStateView = fwssStateView_;
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function inspect(BossTypes.ResourceRef calldata resource, address expectedPayer, bytes calldata resourceData)
        external
        view
        returns (BossTypes.ResourceStatus memory status)
    {
        if (resourceData.length != 0) revert UnexpectedResourceData();
        if (expectedPayer == address(0)) revert InvalidExpectedPayer();
        if (
            resource.kind != BossTypes.ResourceKind.FWSS_PDP_DATASET || resource.chainId != block.chainid
                || resource.anchor != pdpVerifier || resource.context != bytes32(0)
        ) revert InvalidResource();

        bytes32 resourceKey = BossHashes.hashResource(resource);
        uint256 dataSetId = resource.resourceId;
        IPDPVerifierView pdp = IPDPVerifierView(pdpVerifier);
        IFWSSStateView stateView = IFWSSStateView(fwssStateView);

        bool live;
        try pdp.dataSetLive(dataSetId) returns (bool observedLive) {
            live = observedLive;
        } catch {
            return _unavailable(resourceKey);
        }
        if (!live) revert DataSetNotLive(dataSetId);

        address listener;
        try pdp.getDataSetListener(dataSetId) returns (address observedListener) {
            listener = observedListener;
        } catch {
            return _unavailable(resourceKey);
        }
        if (listener != fwssService) revert ListenerMismatch(fwssService, listener);

        IFWSSStateView.DataSetStatus dataSetStatus;
        try stateView.getDataSetStatus(dataSetId) returns (IFWSSStateView.DataSetStatus observedStatus) {
            dataSetStatus = observedStatus;
        } catch {
            return _unavailable(resourceKey);
        }
        if (dataSetStatus != IFWSSStateView.DataSetStatus.Active) revert DataSetNotActive(dataSetId);

        IFWSSStateView.DataSetInfoView memory info;
        try stateView.getDataSet(dataSetId) returns (IFWSSStateView.DataSetInfoView memory observedInfo) {
            info = observedInfo;
        } catch {
            return _unavailable(resourceKey);
        }
        if (info.dataSetId != dataSetId || info.pdpRailId == 0 || info.pdpEndEpoch != 0) {
            revert InvalidDataSetRecord(dataSetId);
        }
        if (info.payer != expectedPayer) revert PayerMismatch(expectedPayer, info.payer);

        address storageProvider;
        address proposedProvider;
        try pdp.getDataSetStorageProvider(dataSetId) returns (
            address observedStorageProvider, address observedProposedProvider
        ) {
            storageProvider = observedStorageProvider;
            proposedProvider = observedProposedProvider;
        } catch {
            return _unavailable(resourceKey);
        }
        if (storageProvider == address(0) || storageProvider != info.serviceProvider) {
            revert StorageProviderMismatch(storageProvider, info.serviceProvider);
        }

        uint256 leafCount;
        try pdp.getDataSetLeafCount(dataSetId) returns (uint256 observedLeafCount) {
            leafCount = observedLeafCount;
        } catch {
            return _unavailable(resourceKey);
        }

        uint256 sizeInBytes;
        try stateView.getDataSetSizeInBytes(leafCount) returns (uint256 observedSizeInBytes) {
            sizeInBytes = observedSizeInBytes;
        } catch {
            return _unavailable(resourceKey);
        }

        bytes32 statusHash = keccak256(
            abi.encode(
                "FILECOIN_BOSS_FWSS_PDP_STATUS_V1",
                resourceKey,
                pdpVerifier,
                fwssService,
                fwssStateView,
                info.payer,
                storageProvider,
                proposedProvider,
                info.pdpRailId,
                info.providerId,
                leafCount,
                sizeInBytes
            )
        );

        status = BossTypes.ResourceStatus({
            resourceKey: resourceKey,
            exists: true,
            attachable: true,
            billable: true,
            payer: info.payer,
            storageProvider: storageProvider,
            sizeInBytes: sizeInBytes,
            statusHash: statusHash
        });
    }

    function _unavailable(bytes32 resourceKey) private pure returns (BossTypes.ResourceStatus memory status) {
        status = BossTypes.ResourceStatus({
            resourceKey: resourceKey,
            exists: false,
            attachable: false,
            billable: false,
            payer: address(0),
            storageProvider: address(0),
            sizeInBytes: 0,
            statusHash: bytes32(0)
        });
    }
}
