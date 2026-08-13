// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossAccount} from "../../src/BossAccount.sol";
import {BossAdapterRegistry} from "../../src/BossAdapterRegistry.sol";
import {BossServiceRegistry} from "../../src/BossServiceRegistry.sol";
import {FWSSPDPResourceAdapter} from "../../src/adapters/resources/FWSSPDPResourceAdapter.sol";
import {FlatRateAdapter} from "../../src/adapters/pricing/FlatRateAdapter.sol";
import {IFWSSStateView} from "../../src/interfaces/IFWSSStateView.sol";
import {BossHashes} from "../../src/libraries/BossHashes.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";
import {MockERC1271Signer, MockFilecoinPayV1} from "../unit/BossAccountFlatLifecycle.t.sol";
import {MockFWSSStateView, MockPDPVerifierView} from "../unit/FWSSPDPResourceAdapter.t.sol";

interface VmFWSSBinding {
    function prank(address sender) external;
    function roll(uint256 newHeight) external;
}

contract FWSSResourceBindingTest {
    VmFWSSBinding internal constant vm = VmFWSSBinding(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant DATA_SET_ID = 42;
    address internal constant FWSS_SERVICE = address(0xF55);
    address internal constant PROVIDER = address(0xB0B);
    address internal constant BENEFICIARY = address(0xBEEF);
    bytes32 internal constant SERVICE_ID = keccak256("fwss-flat-service");
    bytes32 internal constant SERVICE_TYPE = keccak256("managed-storage");

    MockPDPVerifierView internal pdp;
    MockFWSSStateView internal stateView;
    FWSSPDPResourceAdapter internal resourceAdapter;
    FlatRateAdapter internal pricingAdapter;
    MockFilecoinPayV1 internal pay;
    BossServiceRegistry internal serviceRegistry;
    BossAdapterRegistry internal adapterRegistry;
    MockERC1271Signer internal signer;
    BossAccount internal account;

    function setUp() public {
        vm.roll(100);
        pdp = new MockPDPVerifierView();
        stateView = new MockFWSSStateView(FWSS_SERVICE);
        resourceAdapter = new FWSSPDPResourceAdapter(address(pdp), FWSS_SERVICE, address(stateView));
        pricingAdapter = new FlatRateAdapter();
        pay = new MockFilecoinPayV1();
        serviceRegistry = new BossServiceRegistry();
        adapterRegistry = new BossAdapterRegistry(address(this));
        signer = new MockERC1271Signer();

        vm.prank(PROVIDER);
        serviceRegistry.registerProvider("ipfs://provider", address(signer));
        vm.prank(PROVIDER);
        serviceRegistry.publishService(SERVICE_ID, SERVICE_TYPE, "ipfs://service");

        adapterRegistry.registerAdapter(
            address(resourceAdapter), BossTypes.AdapterKind.RESOURCE, 1, "ipfs://fwss-resource"
        );
        adapterRegistry.registerAdapter(
            address(pricingAdapter), BossTypes.AdapterKind.PRICING, 1, "ipfs://flat-pricing"
        );

        account = new BossAccount(address(this), address(pay), address(serviceRegistry), address(adapterRegistry), 1);
        pay.setOperatorApproval(address(0), address(this), address(account), true);
        _setState(address(this));
    }

    function testBossAcceptsOnlyCanonicalFWSSResourceForRecordedPayer() public {
        BossTypes.AcceptanceInput memory input = _input();
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(input);
        BossTypes.Subscription memory subscription = account.getSubscription(subscriptionId);

        require(subscription.resourceKey == BossHashes.hashResource(input.resource), "resource key bound");
        require(subscription.resourceDataHash == keccak256(bytes("")), "resource data bound");
        require(subscription.state == BossTypes.SubscriptionState.ACTIVE, "subscription active");
        require(subscription.railId == railId, "rail bound");
        require(account.subscriptionForRail(railId) == subscriptionId, "reverse rail binding");
    }

    function testBossRejectsAnotherPayersNumericDataSetId() public {
        _setState(address(0xBAD));
        BossTypes.AcceptanceInput memory input = _input();

        (bool success,) = address(account).call(abi.encodeCall(BossAccount.acceptOffer, (input)));
        require(!success, "foreign payer resource accepted");
    }

    function testBossRejectsWrongDeploymentContext() public {
        BossTypes.AcceptanceInput memory input = _input();
        input.resource.context = bytes32(uint256(1));

        (bool success,) = address(account).call(abi.encodeCall(BossAccount.acceptOffer, (input)));
        require(!success, "wrong deployment context accepted");
    }

    function _input() private returns (BossTypes.AcceptanceInput memory input) {
        bytes memory pricingData =
            abi.encode(FlatRateAdapter.FlatRateTerms({grossPricePerPeriod: 1_000, periodEpochs: 1_000}));
        BossTypes.ServiceOffer memory offer = BossTypes.ServiceOffer({
            serviceId: SERVICE_ID,
            offerVersion: 1,
            provider: PROVIDER,
            signingKey: address(signer),
            beneficiary: BENEFICIARY,
            reporter: address(0),
            token: address(0),
            resourceAdapter: address(resourceAdapter),
            pricingAdapter: address(pricingAdapter),
            serviceType: SERVICE_TYPE,
            billingKind: BossTypes.BillingKind.STREAM_FLAT,
            assuranceKind: BossTypes.AssuranceKind.ONCHAIN_DETERMINISTIC,
            dependencyKind: BossTypes.DependencyKind.HARD,
            activationKind: BossTypes.ActivationKind.IMMEDIATE,
            terminationBillingKind: BossTypes.TerminationBillingKind.ZERO_AFTER_REQUEST,
            pricingDataHash: keccak256(pricingData),
            termsHash: keccak256("terms"),
            accessScopeHash: bytes32(0),
            validAfterEpoch: 0,
            validUntilEpoch: 0,
            requiredLockupPeriod: 0,
            quoteTtlEpochs: 0,
            commissionBps: 0,
            commissionRecipient: address(0),
            pauseAllowed: true,
            providerMaxRatePerEpoch: 1,
            providerMaxFixedLockup: 0,
            nonce: 1
        });
        bytes32 digest = BossHashes.hashTypedData(
            BossHashes.domainSeparator(block.chainid, address(account)), BossHashes.hashServiceOffer(offer)
        );
        signer.setValidDigest(digest);

        input = BossTypes.AcceptanceInput({
            offer: offer,
            providerSignature: hex"01",
            resource: BossTypes.ResourceRef({
                kind: BossTypes.ResourceKind.FWSS_PDP_DATASET,
                chainId: uint64(block.chainid),
                anchor: address(pdp),
                resourceId: DATA_SET_ID,
                context: bytes32(0)
            }),
            resourceData: bytes(""),
            pricingData: pricingData,
            caps: BossTypes.CapPolicy({
                maxRatePerEpoch: 1,
                maxFixedLockup: 0,
                maxSingleCharge: 0,
                maxChargePerWindow: 0,
                lifetimeCapGross: 1_000,
                chargeWindowEpochs: 0,
                notAfterEpoch: 1_000,
                maxLockupPeriod: 0
            }),
            initialFixedBudget: 0,
            accessGrantHash: bytes32(0)
        });
    }

    function _setState(address payer) private {
        pdp.setDataSet(
            DATA_SET_ID,
            MockPDPVerifierView.DataSet({
                live: true,
                leafCount: 4_096,
                listener: FWSS_SERVICE,
                storageProvider: PROVIDER,
                proposedProvider: address(0),
                lastProvenEpoch: block.number
            })
        );
        stateView.setDataSet(
            DATA_SET_ID,
            IFWSSStateView.DataSetInfoView({
                pdpRailId: 7,
                cacheMissRailId: 0,
                cdnRailId: 0,
                payer: payer,
                payee: BENEFICIARY,
                serviceProvider: PROVIDER,
                commissionBps: 0,
                clientDataSetId: 99,
                pdpEndEpoch: 0,
                providerId: 123,
                pendingOneTimePayments: 0,
                lifecycleReserveBalance: 0,
                dataSetId: DATA_SET_ID
            }),
            IFWSSStateView.DataSetStatus.Active
        );
    }
}
