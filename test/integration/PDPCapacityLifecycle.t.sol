// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossAccount} from "../../src/BossAccount.sol";
import {BossAdapterRegistry} from "../../src/BossAdapterRegistry.sol";
import {BossServiceRegistry} from "../../src/BossServiceRegistry.sol";
import {PDPCapacityAdapter} from "../../src/adapters/pricing/PDPCapacityAdapter.sol";
import {IBossResourceAdapter} from "../../src/interfaces/IBossResourceAdapter.sol";
import {BossHashes} from "../../src/libraries/BossHashes.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";
import {MockERC1271Signer, MockFilecoinPayV1} from "../unit/BossAccountFlatLifecycle.t.sol";

interface VmCapacityLifecycle {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address sender) external;
    function roll(uint256 newHeight) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}

contract MutableCapacityResourceAdapter is IBossResourceAdapter {
    uint256 public sizeInBytes = 1 << 40;
    uint256 public stateNonce = 1;
    bool public available = true;

    function setSize(uint256 sizeInBytes_) external {
        sizeInBytes = sizeInBytes_;
        ++stateNonce;
    }

    function setAvailable(bool available_) external {
        available = available_;
        ++stateNonce;
    }

    function touchState() external {
        ++stateNonce;
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function inspect(BossTypes.ResourceRef calldata resource, address expectedPayer, bytes calldata)
        external
        view
        returns (BossTypes.ResourceStatus memory status)
    {
        bytes32 resourceKey = BossHashes.hashResource(resource);
        status = BossTypes.ResourceStatus({
            resourceKey: resourceKey,
            exists: available,
            attachable: available,
            billable: available,
            payer: available ? expectedPayer : address(0),
            storageProvider: available ? address(0xB0B) : address(0),
            sizeInBytes: available ? sizeInBytes : 0,
            statusHash: available ? keccak256(abi.encode(resourceKey, sizeInBytes, stateNonce)) : bytes32(0)
        });
    }
}

contract PDPCapacityLifecycleTest {
    VmCapacityLifecycle private constant vm =
        VmCapacityLifecycle(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant TIB = 1 << 40;
    uint256 private constant PRICE_PER_TIB = 1 ether;
    uint64 private constant PERIOD_EPOCHS = 86_400;
    uint64 private constant QUOTE_TTL = 10;
    uint256 private constant ONE_TIB_RATE = 11_574_074_074_074;

    address private constant PROVIDER = address(0xB0B);
    address private constant BENEFICIARY = address(0xBEEF);
    bytes32 private constant SERVICE_ID = keccak256("capacity-storage");
    bytes32 private constant SERVICE_TYPE = keccak256("managed-storage-capacity");

    MockFilecoinPayV1 private pay;
    BossServiceRegistry private serviceRegistry;
    BossAdapterRegistry private adapterRegistry;
    MockERC1271Signer private signer;
    MutableCapacityResourceAdapter private resourceAdapter;
    PDPCapacityAdapter private pricingAdapter;
    BossAccount private account;

    function setUp() public {
        vm.roll(100);
        pay = new MockFilecoinPayV1();
        serviceRegistry = new BossServiceRegistry();
        adapterRegistry = new BossAdapterRegistry(address(this));
        signer = new MockERC1271Signer();
        resourceAdapter = new MutableCapacityResourceAdapter();
        pricingAdapter = new PDPCapacityAdapter();

        vm.prank(PROVIDER);
        serviceRegistry.registerProvider("ipfs://capacity-provider", address(signer));
        vm.prank(PROVIDER);
        serviceRegistry.publishService(SERVICE_ID, SERVICE_TYPE, "ipfs://capacity-service");

        adapterRegistry.registerAdapter(
            address(resourceAdapter), BossTypes.AdapterKind.RESOURCE, 1, "ipfs://capacity-resource"
        );
        adapterRegistry.registerAdapter(
            address(pricingAdapter), BossTypes.AdapterKind.PRICING, 1, "ipfs://capacity-pricing"
        );

        account = new BossAccount(
            address(this), address(pay), address(serviceRegistry), address(adapterRegistry), 1, address(this)
        );
        pay.setOperatorApproval(address(0), address(this), address(account), true);
    }

    function testPermissionlessSyncSettlesOldRateBeforeProspectiveIncrease() public {
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(_input(1, type(uint256).max));
        require(pay.getRail(railId).paymentRate == ONE_TIB_RATE, "initial rate");

        resourceAdapter.setSize(TIB * 2);
        vm.roll(105);
        vm.prank(address(0xCAFE));
        account.syncRate(subscriptionId);

        require(pay.settledGross(railId) == ONE_TIB_RATE * 5, "old interval not settled at old rate");
        require(pay.getRail(railId).settledUpTo == 105, "settlement cursor");
        require(pay.getRail(railId).paymentRate == ONE_TIB_RATE * 2, "new rate");

        BossTypes.Subscription memory subscription = account.getSubscription(subscriptionId);
        require(subscription.acceptedRatePerEpoch == ONE_TIB_RATE * 2, "accepted rate");
        require(subscription.quoteValidThroughEpoch == 115, "refreshed ttl");

        vm.prank(address(0xD00D));
        account.syncRate(subscriptionId);
        require(pay.getRail(railId).paymentRate == ONE_TIB_RATE * 2, "same-state sync changed rate");
        require(pay.settledGross(railId) == ONE_TIB_RATE * 5, "same-state sync charged again");
    }

    function testRateSyncEventCarriesRequiredProvenance() public {
        (bytes32 subscriptionId,) = account.acceptOffer(_input(10, type(uint256).max));
        resourceAdapter.setSize(TIB * 2);
        BossTypes.ResourceStatus memory expected = resourceAdapter.inspect(
            BossTypes.ResourceRef({
                kind: BossTypes.ResourceKind.FWSS_PDP_DATASET,
                chainId: uint64(block.chainid),
                anchor: address(0xF00D),
                resourceId: 42,
                context: bytes32(0)
            }),
            address(this),
            bytes("")
        );

        vm.roll(105);
        vm.recordLogs();
        account.syncRate(subscriptionId);
        VmCapacityLifecycle.Log[] memory logs = vm.getRecordedLogs();
        bytes32 signature = keccak256("RateSynchronized(bytes32,uint256,uint256,uint64,uint64,bytes32)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(account) || logs[i].topics.length != 2 || logs[i].topics[0] != signature) {
                continue;
            }
            require(logs[i].topics[1] == subscriptionId, "event subscription");
            (uint256 oldRate, uint256 newRate, uint64 quoteEpoch, uint64 validThrough, bytes32 statusHash) =
                abi.decode(logs[i].data, (uint256, uint256, uint64, uint64, bytes32));
            require(oldRate == ONE_TIB_RATE, "event old rate");
            require(newRate == ONE_TIB_RATE * 2, "event new rate");
            require(quoteEpoch == 105, "event quote epoch");
            require(validThrough == 115, "event validity");
            require(statusHash == expected.statusHash, "event resource state");
            found = true;
        }
        require(found, "rate sync event missing");
    }

    function testExpiredQuoteAdvancesSettlementWithZeroUntilRefresh() public {
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(_input(2, type(uint256).max));

        vm.roll(125);
        account.settle(subscriptionId, 125);
        require(pay.settledGross(railId) == ONE_TIB_RATE * QUOTE_TTL, "expired interval paid");
        require(pay.getRail(railId).settledUpTo == 125, "expired cursor not advanced");

        resourceAdapter.setSize(TIB * 3);
        vm.prank(address(0xCAFE));
        account.syncRate(subscriptionId);
        require(pay.settledGross(railId) == ONE_TIB_RATE * QUOTE_TTL, "refresh revived expired gap");
        require(pay.getRail(railId).paymentRate == ONE_TIB_RATE * 3, "refreshed rate");
        require(account.getSubscription(subscriptionId).quoteValidThroughEpoch == 135, "refreshed expiry");
    }

    function testUnavailableResourceStopsRateAndLaterRecoveryIsProspective() public {
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(_input(3, type(uint256).max));

        resourceAdapter.setAvailable(false);
        vm.roll(105);
        account.syncRate(subscriptionId);
        require(pay.settledGross(railId) == ONE_TIB_RATE * 5, "available interval settlement");
        require(pay.getRail(railId).paymentRate == 0, "unavailable resource still rated");
        require(account.getSubscription(subscriptionId).quoteValidThroughEpoch == 105, "unavailable boundary");

        resourceAdapter.setAvailable(true);
        resourceAdapter.setSize(TIB * 2);
        vm.roll(110);
        account.syncRate(subscriptionId);
        require(pay.settledGross(railId) == ONE_TIB_RATE * 5, "unavailable gap charged");
        require(pay.getRail(railId).paymentRate == ONE_TIB_RATE * 2, "recovery rate");
    }

    function testCapBreachRevertsSettlementAndRateChangeAtomically() public {
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(_input(4, ONE_TIB_RATE));

        resourceAdapter.setSize(TIB * 2);
        vm.roll(105);
        (bool success,) = address(account).call(abi.encodeCall(BossAccount.syncRate, (subscriptionId)));
        require(!success, "above-cap quote accepted");
        require(pay.settledGross(railId) == 0, "failed sync retained settlement");
        require(pay.getRail(railId).settledUpTo == 100, "failed sync advanced cursor");
        require(pay.getRail(railId).paymentRate == ONE_TIB_RATE, "failed sync changed rate");
    }

    function testPendingActivationAndResumeRequireCurrentCapacityQuote() public {
        BossTypes.AcceptanceInput memory pending = _input(5, type(uint256).max);
        pending.offer.activationKind = BossTypes.ActivationKind.PROVIDER_ACK;
        pending.providerSignature = _signOffer(pending.offer);
        (bytes32 pendingId,) = account.acceptOffer(pending);

        vm.roll(111);
        bytes32 provisioningHash = keccak256("capacity-ready");
        account.acknowledgeActivation(pendingId, provisioningHash, _activationSignature(pendingId, provisioningHash));
        _mustFail(abi.encodeCall(BossAccount.activate, (pendingId)));

        vm.prank(address(0xCAFE));
        account.syncRate(pendingId);
        account.activate(pendingId);
        require(account.getSubscription(pendingId).state == BossTypes.SubscriptionState.ACTIVE, "activation failed");

        BossTypes.AcceptanceInput memory immediate = _input(6, type(uint256).max);
        (bytes32 activeId,) = account.acceptOffer(immediate);
        account.pause(activeId);
        vm.roll(122);
        _mustFail(abi.encodeCall(BossAccount.resume, (activeId)));

        vm.prank(address(0xD00D));
        account.syncRate(activeId);
        account.resume(activeId);
        require(account.getSubscription(activeId).state == BossTypes.SubscriptionState.ACTIVE, "resume failed");
    }

    function testCapacityRejectsNonEmptyResourceData() public {
        BossTypes.AcceptanceInput memory input = _input(9, type(uint256).max);
        input.resourceData = hex"01";
        _mustFail(abi.encodeCall(BossAccount.acceptOffer, (input)));
    }

    function testSignedOfferTtlOwnsExpiryWhileAdapterQuoteIsStable() public {
        BossTypes.AcceptanceInput memory shortTtl = _input(7, type(uint256).max);
        (bytes32 shortId,) = account.acceptOffer(shortTtl);

        BossTypes.AcceptanceInput memory longTtl = _input(8, type(uint256).max);
        longTtl.offer.quoteTtlEpochs = QUOTE_TTL * 2;
        longTtl.providerSignature = _signOffer(longTtl.offer);
        (bytes32 longId,) = account.acceptOffer(longTtl);

        require(account.getSubscription(shortId).quoteValidThroughEpoch == 110, "short signed ttl");
        require(account.getSubscription(longId).quoteValidThroughEpoch == 120, "long signed ttl");
        require(account.getSubscription(shortId).quoteTtlEpochs == QUOTE_TTL, "short ttl not discoverable");
        require(account.getSubscription(longId).quoteTtlEpochs == QUOTE_TTL * 2, "long ttl not discoverable");
        require(shortTtl.offer.pricingDataHash == longTtl.offer.pricingDataHash, "pricing bytes changed");

        BossTypes.ResourceStatus memory resource =
            resourceAdapter.inspect(shortTtl.resource, address(this), shortTtl.resourceData);
        BossTypes.RateQuote memory shortQuote = pricingAdapter.quoteRate(resource, shortTtl.pricingData);
        BossTypes.RateQuote memory longQuote = pricingAdapter.quoteRate(resource, longTtl.pricingData);
        require(shortQuote.quoteHash == longQuote.quoteHash, "adapter quote depends on ttl");
        require(shortQuote.validThroughEpoch == 0, "adapter selected ttl");
    }

    function testBossAccountKeepsFixedFiveHundredTwelveByteRuntimeMargin() public view {
        require(address(account).code.length <= 24_064, "BossAccount has less than 512-byte EIP-170 margin");
    }

    function _input(uint256 nonce, uint256 maxRate) private returns (BossTypes.AcceptanceInput memory input) {
        bytes memory pricingData = abi.encode(
            PDPCapacityAdapter.CapacityTerms({grossPricePerTiBPerPeriod: PRICE_PER_TIB, periodEpochs: PERIOD_EPOCHS})
        );
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
            billingKind: BossTypes.BillingKind.STREAM_CAPACITY,
            assuranceKind: BossTypes.AssuranceKind.ONCHAIN_DETERMINISTIC,
            dependencyKind: BossTypes.DependencyKind.HARD,
            activationKind: BossTypes.ActivationKind.IMMEDIATE,
            terminationBillingKind: BossTypes.TerminationBillingKind.ZERO_AFTER_REQUEST,
            pricingDataHash: keccak256(pricingData),
            termsHash: keccak256("capacity terms"),
            accessScopeHash: bytes32(0),
            validAfterEpoch: 0,
            validUntilEpoch: 0,
            requiredLockupPeriod: 0,
            quoteTtlEpochs: QUOTE_TTL,
            commissionBps: 0,
            commissionRecipient: address(0),
            pauseAllowed: true,
            providerMaxRatePerEpoch: maxRate,
            providerMaxFixedLockup: 0,
            nonce: nonce
        });
        input = BossTypes.AcceptanceInput({
            offer: offer,
            providerSignature: _signOffer(offer),
            resource: BossTypes.ResourceRef({
                kind: BossTypes.ResourceKind.FWSS_PDP_DATASET,
                chainId: uint64(block.chainid),
                anchor: address(0xF00D),
                resourceId: 42,
                context: bytes32(0)
            }),
            resourceData: bytes(""),
            pricingData: pricingData,
            caps: BossTypes.CapPolicy({
                maxRatePerEpoch: maxRate,
                maxFixedLockup: 0,
                maxSingleCharge: 0,
                maxChargePerWindow: 0,
                lifetimeCapGross: type(uint256).max,
                chargeWindowEpochs: 0,
                notAfterEpoch: 0,
                maxLockupPeriod: 0
            }),
            initialFixedBudget: 0,
            accessGrantHash: bytes32(0)
        });
    }

    function _signOffer(BossTypes.ServiceOffer memory offer) private returns (bytes memory signature) {
        bytes32 digest = BossHashes.hashTypedData(
            BossHashes.domainSeparator(block.chainid, address(account)), BossHashes.hashServiceOffer(offer)
        );
        signer.setValidDigest(digest);
        signature = hex"01";
    }

    function _activationSignature(bytes32 subscriptionId, bytes32 provisioningHash)
        private
        returns (bytes memory signature)
    {
        signer.setValidDigest(account.activationAckDigest(subscriptionId, provisioningHash));
        signature = hex"02";
    }

    function _mustFail(bytes memory callData) private {
        (bool success,) = address(account).call(callData);
        require(!success, "stale quote operation succeeded");
    }
}
