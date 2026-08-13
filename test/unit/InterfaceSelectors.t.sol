// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IFilecoinPayV1, IFilecoinPayValidator} from "../../src/interfaces/IFilecoinPayV1.sol";
import {IPDPVerifierView} from "../../src/interfaces/IPDPVerifierView.sol";
import {IFWSSStateView} from "../../src/interfaces/IFWSSStateView.sol";
import {IBossResourceAdapter} from "../../src/interfaces/IBossResourceAdapter.sol";
import {IBossPricingAdapter} from "../../src/interfaces/IBossPricingAdapter.sol";

contract InterfaceSelectorsTest {
    function testFilecoinPaySelectors() public pure {
        require(IFilecoinPayV1.createRail.selector == 0xf9f78de8, "createRail");
        require(IFilecoinPayV1.modifyRailLockup.selector == 0xde07b8bb, "modifyRailLockup");
        require(IFilecoinPayV1.modifyRailPayment.selector == 0x97d3ea34, "modifyRailPayment");
        require(IFilecoinPayV1.settleRail.selector == 0xbcd40bf8, "settleRail");
        require(IFilecoinPayV1.terminateRail.selector == 0xcbb0bf18, "terminateRail");
        require(IFilecoinPayV1.getRail.selector == 0x22e440b3, "getRail");
        require(IFilecoinPayV1.getAccountInfoIfSettled.selector == 0x05f4c536, "getAccountInfoIfSettled");
        require(IFilecoinPayV1.operatorApprovals.selector == 0xe3d4c69e, "operatorApprovals");
        require(IFilecoinPayValidator.validatePayment.selector == 0x1a7bf46f, "validatePayment");
        require(IFilecoinPayValidator.railTerminated.selector == 0xc5153f70, "railTerminated");
    }

    function testPdpSelectors() public pure {
        require(IPDPVerifierView.dataSetLive.selector == 0xca759f27, "dataSetLive");
        require(IPDPVerifierView.getDataSetLeafCount.selector == 0xa531998c, "getDataSetLeafCount");
        require(IPDPVerifierView.getDataSetListener.selector == 0x2b3129bb, "getDataSetListener");
        require(IPDPVerifierView.getDataSetStorageProvider.selector == 0x21b7cd1c, "getDataSetStorageProvider");
        require(IPDPVerifierView.getDataSetLastProvenEpoch.selector == 0x04595c1a, "getDataSetLastProvenEpoch");
    }

    function testFwssSelectors() public pure {
        require(IFWSSStateView.service.selector == 0xd598d4c9, "service");
        require(IFWSSStateView.getDataSet.selector == 0xbdaac056, "getDataSet");
        require(IFWSSStateView.getDataSetSizeInBytes.selector == 0xfe295953, "getDataSetSizeInBytes");
        require(IFWSSStateView.getDataSetStatus.selector == 0x617285ad, "getDataSetStatus");
    }

    function testBossAdapterSelectors() public pure {
        require(IBossResourceAdapter.interfaceVersion.selector == 0x1d8ffa4d, "resource version");
        require(IBossResourceAdapter.inspect.selector == 0x50b9714c, "inspect");
        require(IBossPricingAdapter.interfaceVersion.selector == 0x1d8ffa4d, "pricing version");
        require(IBossPricingAdapter.quoteRate.selector == 0xdeba2139, "quoteRate");
        require(IBossPricingAdapter.quoteUsage.selector == 0x1e3bfb9e, "quoteUsage");
    }
}
