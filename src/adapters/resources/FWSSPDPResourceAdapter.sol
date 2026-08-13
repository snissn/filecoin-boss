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

        uint256 dataSetId = resource.resourceId;
        IPDPVerifierView pdp = IPDPVerifierView(pdpVerifier);
        if (!pdp.dataSetLive(dataSetId)) revert DataSetNotLive(dataSetId);

        address listener = pdp.getDataSetListener(dataSetId);
        if (listener != fwssService) revert ListenerMismatch(fwssService, listener);

        IFWSSStateView stateView = IFWSSStateView(fwssStateView);
        if (stateView.getDataSetStatus(dataSetId) != IFWSSStateView.DataSetStatus.Active) {
            revert DataSetNotActive(dataSetId);
        }

        IFWSSStateView.DataSetInfoView memory info = stateView.getDataSet(dataSetId);
        if (info.dataSetId != dataSetId || info.pdpRailId == 0 || info.pdpEndEpoch != 0) {
            revert InvalidDataSetRecord(dataSetId);
        }
        if (info.payer != expectedPayer) revert PayerMismatch(expectedPayer, info.payer);

        (address storageProvider, address proposedProvider) = pdp.getDataSetStorageProvider(dataSetId);
        if (storageProvider == address(0) || storageProvider != info.serviceProvider) {
            revert StorageProviderMismatch(storageProvider, info.serviceProvider);
        }

        uint256 leafCount = pdp.getDataSetLeafCount(dataSetId);
        uint256 sizeInBytes = stateView.getDataSetSizeInBytes(leafCount);
        bytes32 resourceKey = BossHashes.hashResource(resource);
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
}
