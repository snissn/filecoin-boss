// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FWSSPDPResourceAdapter} from "../../src/adapters/resources/FWSSPDPResourceAdapter.sol";
import {IFWSSStateView} from "../../src/interfaces/IFWSSStateView.sol";
import {IPDPVerifierView} from "../../src/interfaces/IPDPVerifierView.sol";
import {BossHashes} from "../../src/libraries/BossHashes.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";

contract MockPDPVerifierView is IPDPVerifierView {
    struct DataSet {
        bool live;
        uint256 leafCount;
        address listener;
        address storageProvider;
        address proposedProvider;
        uint256 lastProvenEpoch;
    }

    mapping(uint256 setId => DataSet dataSet) private _dataSets;

    function setDataSet(uint256 setId, DataSet calldata dataSet) external {
        _dataSets[setId] = dataSet;
    }

    function getDataSetRecord(uint256 setId) external view returns (DataSet memory) {
        return _dataSets[setId];
    }

    function dataSetLive(uint256 setId) external view returns (bool) {
        return _dataSets[setId].live;
    }

    function getDataSetLeafCount(uint256 setId) external view returns (uint256) {
        return _dataSets[setId].leafCount;
    }

    function getDataSetListener(uint256 setId) external view returns (address) {
        return _dataSets[setId].listener;
    }

    function getDataSetStorageProvider(uint256 setId)
        external
        view
        returns (address serviceProvider, address proposedProvider)
    {
        DataSet storage dataSet = _dataSets[setId];
        return (dataSet.storageProvider, dataSet.proposedProvider);
    }

    function getDataSetLastProvenEpoch(uint256 setId) external view returns (uint256) {
        return _dataSets[setId].lastProvenEpoch;
    }
}

contract MockFWSSStateView is IFWSSStateView {
    address public immutable service;
    mapping(uint256 dataSetId => DataSetInfoView info) private _dataSets;
    mapping(uint256 dataSetId => DataSetStatus status) private _status;

    constructor(address service_) {
        service = service_;
    }

    function setDataSet(uint256 dataSetId, DataSetInfoView calldata info, DataSetStatus status_) external {
        _dataSets[dataSetId] = info;
        _status[dataSetId] = status_;
    }

    function getDataSet(uint256 dataSetId) external view returns (DataSetInfoView memory info) {
        return _dataSets[dataSetId];
    }

    function getDataSetSizeInBytes(uint256 leafCount) external pure returns (uint256) {
        return leafCount * 32 * 127 / 128;
    }

    function getDataSetStatus(uint256 dataSetId) external view returns (DataSetStatus status) {
        return _status[dataSetId];
    }
}

contract FWSSPDPResourceAdapterTest {
    uint256 internal constant DATA_SET_ID = 42;
    address internal constant FWSS_SERVICE = address(0xF55);
    address internal constant PAYER = address(0xA11CE);
    address internal constant STORAGE_PROVIDER = address(0xB0B);

    MockPDPVerifierView internal pdp;
    MockFWSSStateView internal stateView;
    FWSSPDPResourceAdapter internal adapter;

    function setUp() public {
        pdp = new MockPDPVerifierView();
        stateView = new MockFWSSStateView(FWSS_SERVICE);
        adapter = new FWSSPDPResourceAdapter(address(pdp), FWSS_SERVICE, address(stateView));
        _setValidState(4_096, STORAGE_PROVIDER);
    }

    function testValidPayerProducesCanonicalStatus() public view {
        BossTypes.ResourceRef memory resource = _resource();
        BossTypes.ResourceStatus memory status = adapter.inspect(resource, PAYER, bytes(""));

        require(adapter.interfaceVersion() == 1, "interface version");
        require(status.resourceKey == BossHashes.hashResource(resource), "resource key");
        require(status.exists, "exists");
        require(status.attachable, "attachable");
        require(status.billable, "billable");
        require(status.payer == PAYER, "payer");
        require(status.storageProvider == STORAGE_PROVIDER, "storage provider");
        require(status.sizeInBytes == 4_096 * 32 * 127 / 128, "size");
        require(status.statusHash != bytes32(0), "status hash");
    }

    function testContextCommitsExactDeploymentTuple() public view {
        bytes32 expected = keccak256(
            abi.encode("FILECOIN_BOSS_FWSS_PDP_CONTEXT_V1", FWSS_SERVICE, address(stateView))
        );
        require(adapter.resourceContext() == expected, "deployment context");
        require(_resource().context == expected, "resource context");
    }

    function testWrongStructuralIdentityFailsClosed() public {
        BossTypes.ResourceRef memory resource = _resource();

        resource.chainId += 1;
        _mustFail(resource, PAYER, bytes(""));

        resource = _resource();
        resource.anchor = address(0xDEAD);
        _mustFail(resource, PAYER, bytes(""));

        resource = _resource();
        resource.context = bytes32(uint256(1));
        _mustFail(resource, PAYER, bytes(""));

        resource = _resource();
        resource.kind = BossTypes.ResourceKind.BARE_PDP_DATASET;
        _mustFail(resource, PAYER, bytes(""));

        resource = _resource();
        _mustFail(resource, PAYER, abi.encode(uint256(1)));
    }

    function testWrongPayerListenerAndLifecycleFailClosed() public {
        BossTypes.ResourceRef memory resource = _resource();
        _mustFail(resource, address(0xBAD), bytes(""));

        MockPDPVerifierView.DataSet memory pdpData = pdp.getDataSetRecord(DATA_SET_ID);
        pdpData.listener = address(0xBAD);
        pdp.setDataSet(DATA_SET_ID, pdpData);
        _mustFail(resource, PAYER, bytes(""));

        _setValidState(4_096, STORAGE_PROVIDER);
        pdpData = pdp.getDataSetRecord(DATA_SET_ID);
        pdpData.live = false;
        pdp.setDataSet(DATA_SET_ID, pdpData);
        _mustFail(resource, PAYER, bytes(""));

        _setValidState(4_096, STORAGE_PROVIDER);
        IFWSSStateView.DataSetInfoView memory info = _info(PAYER, STORAGE_PROVIDER);
        stateView.setDataSet(DATA_SET_ID, info, IFWSSStateView.DataSetStatus.Inactive);
        _mustFail(resource, PAYER, bytes(""));

        _setValidState(4_096, STORAGE_PROVIDER);
        info = _info(PAYER, STORAGE_PROVIDER);
        info.pdpEndEpoch = block.number + 1;
        stateView.setDataSet(DATA_SET_ID, info, IFWSSStateView.DataSetStatus.Active);
        _mustFail(resource, PAYER, bytes(""));
    }

    function testStateViewRecordAndCurrentProviderMustMatch() public {
        BossTypes.ResourceRef memory resource = _resource();
        IFWSSStateView.DataSetInfoView memory info = _info(PAYER, STORAGE_PROVIDER);

        info.dataSetId = DATA_SET_ID + 1;
        stateView.setDataSet(DATA_SET_ID, info, IFWSSStateView.DataSetStatus.Active);
        _mustFail(resource, PAYER, bytes(""));

        _setValidState(4_096, STORAGE_PROVIDER);
        info = _info(PAYER, STORAGE_PROVIDER);
        info.pdpRailId = 0;
        stateView.setDataSet(DATA_SET_ID, info, IFWSSStateView.DataSetStatus.Active);
        _mustFail(resource, PAYER, bytes(""));

        _setValidState(4_096, STORAGE_PROVIDER);
        info = _info(PAYER, address(0xBAD));
        stateView.setDataSet(DATA_SET_ID, info, IFWSSStateView.DataSetStatus.Active);
        _mustFail(resource, PAYER, bytes(""));
    }

    function testStatusHashChangesWithCapacityAndProviderState() public {
        bytes32 first = adapter.inspect(_resource(), PAYER, bytes("")).statusHash;

        _setValidState(8_192, STORAGE_PROVIDER);
        bytes32 resized = adapter.inspect(_resource(), PAYER, bytes("")).statusHash;
        require(resized != first, "capacity changes state hash");

        _setValidState(8_192, address(0xCAFE));
        bytes32 migrated = adapter.inspect(_resource(), PAYER, bytes("")).statusHash;
        require(migrated != resized, "provider changes state hash");
    }

    function testInspectHasBoundedGasAndDoesNotMutateSources() public {
        MockPDPVerifierView.DataSet memory beforePdp = pdp.getDataSetRecord(DATA_SET_ID);
        IFWSSStateView.DataSetInfoView memory beforeInfo = stateView.getDataSet(DATA_SET_ID);

        uint256 gasBefore = gasleft();
        adapter.inspect(_resource(), PAYER, bytes(""));
        uint256 gasUsed = gasBefore - gasleft();
        require(gasUsed < 300_000, "inspect gas ceiling");

        MockPDPVerifierView.DataSet memory afterPdp = pdp.getDataSetRecord(DATA_SET_ID);
        IFWSSStateView.DataSetInfoView memory afterInfo = stateView.getDataSet(DATA_SET_ID);
        require(keccak256(abi.encode(beforePdp)) == keccak256(abi.encode(afterPdp)), "PDP unchanged");
        require(keccak256(abi.encode(beforeInfo)) == keccak256(abi.encode(afterInfo)), "FWSS unchanged");
    }

    function testConstructorRejectsMismatchedStateViewService() public {
        MockFWSSStateView wrong = new MockFWSSStateView(address(0xBAD));
        try new FWSSPDPResourceAdapter(address(pdp), FWSS_SERVICE, address(wrong)) {
            revert("mismatched state view accepted");
        } catch {}
    }

    function _setValidState(uint256 leafCount, address storageProvider) private {
        pdp.setDataSet(
            DATA_SET_ID,
            MockPDPVerifierView.DataSet({
                live: true,
                leafCount: leafCount,
                listener: FWSS_SERVICE,
                storageProvider: storageProvider,
                proposedProvider: address(0),
                lastProvenEpoch: block.number
            })
        );
        stateView.setDataSet(
            DATA_SET_ID,
            _info(PAYER, storageProvider),
            IFWSSStateView.DataSetStatus.Active
        );
    }

    function _info(address payer, address storageProvider)
        private
        pure
        returns (IFWSSStateView.DataSetInfoView memory info)
    {
        info = IFWSSStateView.DataSetInfoView({
            pdpRailId: 7,
            cacheMissRailId: 0,
            cdnRailId: 0,
            payer: payer,
            payee: address(0xBEEF),
            serviceProvider: storageProvider,
            commissionBps: 0,
            clientDataSetId: 99,
            pdpEndEpoch: 0,
            providerId: 123,
            pendingOneTimePayments: 0,
            lifecycleReserveBalance: 0,
            dataSetId: DATA_SET_ID
        });
    }

    function _resource() private view returns (BossTypes.ResourceRef memory resource) {
        resource = BossTypes.ResourceRef({
            kind: BossTypes.ResourceKind.FWSS_PDP_DATASET,
            chainId: uint64(block.chainid),
            anchor: address(pdp),
            resourceId: DATA_SET_ID,
            context: adapter.resourceContext()
        });
    }

    function _mustFail(BossTypes.ResourceRef memory resource, address expectedPayer, bytes memory resourceData)
        private
    {
        try adapter.inspect(resource, expectedPayer, resourceData) returns (BossTypes.ResourceStatus memory) {
            revert("invalid resource accepted");
        } catch {}
    }
}
