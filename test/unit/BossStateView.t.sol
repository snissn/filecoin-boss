// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossAdapterRegistry} from "../../src/BossAdapterRegistry.sol";
import {BossStateView} from "../../src/BossStateView.sol";
import {IBossPricingAdapter} from "../../src/interfaces/IBossPricingAdapter.sol";
import {IBossResourceAdapter} from "../../src/interfaces/IBossResourceAdapter.sol";
import {IFilecoinPayV1} from "../../src/interfaces/IFilecoinPayV1.sol";
import {BossHashes} from "../../src/libraries/BossHashes.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";
import {RevertAssertions} from "../utils/RevertAssertions.sol";

interface VmStateView {
    function roll(uint256 newHeight) external;
}

contract MockStatePay {
    mapping(uint256 railId => IFilecoinPayV1.RailView rail) private _rails;
    mapping(uint256 railId => bool exists) private _exists;

    function setRail(uint256 railId, IFilecoinPayV1.RailView memory rail) external {
        _rails[railId] = rail;
        _exists[railId] = true;
    }

    function deleteRail(uint256 railId) external {
        delete _rails[railId];
        delete _exists[railId];
    }

    function getRail(uint256 railId) external view returns (IFilecoinPayV1.RailView memory rail) {
        require(_exists[railId], "rail finalized");
        return _rails[railId];
    }
}

contract MockStateAccount {
    address public owner;
    address public payer;
    address public filecoinPay;
    address public serviceRegistry = address(0x5100);
    address public adapterRegistry = address(0xADA7);
    address public factory = address(0xFAC7);
    uint64 public accountVersion = 1;

    mapping(bytes32 subscriptionId => BossTypes.Subscription subscription) private _subscriptions;
    mapping(uint256 railId => bytes32 subscriptionId) private _subscriptionsByRail;
    mapping(bytes32 subscriptionId => bool acknowledged) private _acknowledged;
    mapping(bytes32 subscriptionId => mapping(bytes32 claimId => bool consumed)) private _claimConsumed;
    mapping(bytes32 subscriptionId => mapping(uint256 nonce => bool consumed)) private _nonceConsumed;
    mapping(bytes32 subscriptionId => mapping(uint256 window => uint256 gross)) private _windowGross;

    constructor(address owner_, address pay_) {
        owner = owner_;
        payer = owner_;
        filecoinPay = pay_;
    }

    function setAdapterRegistry(address adapterRegistry_) external {
        adapterRegistry = adapterRegistry_;
    }

    function setSubscription(bytes32 subscriptionId, BossTypes.Subscription memory subscription, bool acknowledged)
        external
    {
        _subscriptions[subscriptionId] = subscription;
        _subscriptionsByRail[subscription.railId] = subscriptionId;
        _acknowledged[subscriptionId] = acknowledged;
    }

    function setSubscriptionForRail(uint256 railId, bytes32 subscriptionId) external {
        _subscriptionsByRail[railId] = subscriptionId;
    }

    function setUsageClaimState(
        bytes32 subscriptionId,
        bytes32 claimId,
        uint256 nonce,
        uint256 window,
        bool claimConsumed,
        bool nonceConsumed,
        uint256 windowGross
    ) external {
        _claimConsumed[subscriptionId][claimId] = claimConsumed;
        _nonceConsumed[subscriptionId][nonce] = nonceConsumed;
        _windowGross[subscriptionId][window] = windowGross;
    }

    function getSubscription(bytes32 subscriptionId)
        external
        view
        returns (BossTypes.Subscription memory subscription)
    {
        return _subscriptions[subscriptionId];
    }

    function subscriptionForRail(uint256 railId) external view returns (bytes32) {
        return _subscriptionsByRail[railId];
    }

    function activationAcknowledged(bytes32 subscriptionId) external view returns (bool) {
        return _acknowledged[subscriptionId];
    }

    function usageClaimState(bytes32 subscriptionId, bytes32 claimId, uint256 nonce, uint256 window)
        external
        view
        returns (bool claimConsumed, bool nonceConsumed, uint256 windowGross)
    {
        return (
            _claimConsumed[subscriptionId][claimId],
            _nonceConsumed[subscriptionId][nonce],
            _windowGross[subscriptionId][window]
        );
    }
}

contract MockStateResourceAdapter is IBossResourceAdapter {
    BossTypes.ResourceStatus private _status;

    function setStatus(BossTypes.ResourceStatus memory status) external {
        _status = status;
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function inspect(BossTypes.ResourceRef calldata, address expectedPayer, bytes calldata)
        external
        view
        returns (BossTypes.ResourceStatus memory status)
    {
        status = _status;
        require(status.payer == expectedPayer, "unexpected payer");
    }
}

contract MockStatePricingAdapter is IBossPricingAdapter {
    BossTypes.RateQuote private _quote;

    function setQuote(BossTypes.RateQuote memory quote) external {
        _quote = quote;
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function quoteRate(BossTypes.ResourceStatus calldata, bytes calldata)
        external
        view
        returns (BossTypes.RateQuote memory quote)
    {
        return _quote;
    }

    function quoteUsage(uint256, bytes calldata) external pure returns (uint256) {
        return 0;
    }
}

contract BossStateViewTest is RevertAssertions {
    VmStateView private constant VM = VmStateView(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant SUBSCRIPTION = keccak256("subscription");
    bytes32 private constant MISSING = keccak256("missing");

    function testReturnsAccountSubscriptionRailAndCapSnapshot() public {
        (MockStatePay pay, MockStateAccount account, BossStateView stateView) = _fixture();
        BossTypes.Subscription memory subscription = _activeSubscription(9);
        subscription.offerHash = keccak256("offer");
        subscription.resourceKey = keccak256("resource");
        subscription.billingKind = BossTypes.BillingKind.STREAM_CAPACITY;
        subscription.caps.lifetimeCapGross = 100;
        subscription.acceptedRatePerEpoch = 7;
        subscription.settledGross = 20;
        subscription.oneTimeChargedGross = 10;
        subscription.currentFixedBudget = 30;
        account.setSubscription(SUBSCRIPTION, subscription, true);
        pay.setRail(subscription.railId, _validRail(address(account), address(this), subscription));

        BossStateView.AccountSnapshot memory accountSnapshot = stateView.account(address(account));
        require(accountSnapshot.owner == address(this), "owner");
        require(accountSnapshot.payer == address(this), "payer");
        require(accountSnapshot.filecoinPay == address(pay), "pay");
        require(accountSnapshot.serviceRegistry == address(0x5100), "service registry");
        require(accountSnapshot.adapterRegistry == address(0xADA7), "adapter registry");
        require(accountSnapshot.factory == address(0xFAC7), "factory");
        require(accountSnapshot.accountVersion == 1, "version");

        BossStateView.SubscriptionSnapshot memory snapshot = stateView.subscription(address(account), SUBSCRIPTION);
        require(snapshot.exists, "subscription exists");
        require(snapshot.subscriptionId == SUBSCRIPTION, "subscription id");
        require(snapshot.subscription.offerHash == subscription.offerHash, "offer hash");
        require(snapshot.activationAcknowledged, "acknowledged");
        require(snapshot.grossSpent == 30, "gross spent");
        require(snapshot.remainingLifetimeGross == 70, "lifetime remaining");
        require(snapshot.railAssociationValid, "rail association");
        require(snapshot.rail.paymentRate == 7, "rail rate");

        require(!stateView.subscription(address(account), MISSING).exists, "missing exists");
    }

    function testRailAssociationRejectsEveryMismatchedJoinField() public {
        (MockStatePay pay, MockStateAccount account, BossStateView stateView) = _fixture();
        BossTypes.Subscription memory subscription = _activeSubscription(9);
        account.setSubscription(SUBSCRIPTION, subscription, false);
        IFilecoinPayV1.RailView memory rail = _validRail(address(account), address(this), subscription);
        pay.setRail(subscription.railId, rail);
        require(stateView.subscription(address(account), SUBSCRIPTION).railAssociationValid, "valid association");

        rail.from = address(0xDEAD);
        pay.setRail(subscription.railId, rail);
        require(!stateView.subscription(address(account), SUBSCRIPTION).railAssociationValid, "wrong payer");
        rail = _validRail(address(account), address(this), subscription);

        rail.to = address(0xDEAD);
        pay.setRail(subscription.railId, rail);
        require(!stateView.subscription(address(account), SUBSCRIPTION).railAssociationValid, "wrong beneficiary");
        rail = _validRail(address(account), address(this), subscription);

        rail.token = address(0xDEAD);
        pay.setRail(subscription.railId, rail);
        require(!stateView.subscription(address(account), SUBSCRIPTION).railAssociationValid, "wrong token");
        rail = _validRail(address(account), address(this), subscription);

        rail.operator = address(0xDEAD);
        pay.setRail(subscription.railId, rail);
        require(!stateView.subscription(address(account), SUBSCRIPTION).railAssociationValid, "wrong operator");
        rail = _validRail(address(account), address(this), subscription);

        rail.validator = address(0xDEAD);
        pay.setRail(subscription.railId, rail);
        require(!stateView.subscription(address(account), SUBSCRIPTION).railAssociationValid, "wrong validator");
        rail = _validRail(address(account), address(this), subscription);
        pay.setRail(subscription.railId, rail);

        account.setSubscriptionForRail(subscription.railId, MISSING);
        require(!stateView.subscription(address(account), SUBSCRIPTION).railAssociationValid, "wrong rail mapping");
    }

    function testFinalizedEndedRailDoesNotBreakSingleOrBatchSnapshots() public {
        (MockStatePay pay, MockStateAccount account, BossStateView stateView) = _fixture();
        BossTypes.Subscription memory ended = _activeSubscription(13);
        ended.state = BossTypes.SubscriptionState.ENDED;
        account.setSubscription(SUBSCRIPTION, ended, true);
        pay.deleteRail(ended.railId);

        BossStateView.SubscriptionSnapshot memory snapshot = stateView.subscription(address(account), SUBSCRIPTION);
        require(snapshot.exists, "ended missing");
        require(snapshot.subscription.state == BossTypes.SubscriptionState.ENDED, "ended state");
        require(!snapshot.railAssociationValid, "finalized rail associated");
        require(snapshot.rail.from == address(0), "finalized rail fetched");

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = SUBSCRIPTION;
        ids[1] = MISSING;
        BossStateView.SubscriptionSnapshot[] memory snapshots = stateView.subscriptions(address(account), ids);
        require(snapshots[0].exists && !snapshots[0].railAssociationValid, "ended batch");
        require(!snapshots[1].exists, "missing batch");
    }

    function testBatchIsBoundedAndPreservesMissingEntries() public {
        (MockStatePay pay, MockStateAccount account, BossStateView stateView) = _fixture();
        BossTypes.Subscription memory subscription = _activeSubscription(1);
        subscription.caps.lifetimeCapGross = type(uint256).max;
        account.setSubscription(SUBSCRIPTION, subscription, false);
        pay.setRail(subscription.railId, _validRail(address(account), address(this), subscription));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = SUBSCRIPTION;
        ids[1] = MISSING;
        uint256 gasBefore = gasleft();
        BossStateView.SubscriptionSnapshot[] memory snapshots = stateView.subscriptions(address(account), ids);
        uint256 batchGas = gasBefore - gasleft();
        require(snapshots.length == 2, "batch length");
        require(snapshots[0].exists, "existing missing");
        require(!snapshots[1].exists, "missing existing");
        require(snapshots[0].remainingLifetimeGross == type(uint256).max, "unlimited cap");
        require(batchGas < 750_000, "state batch gas");

        bytes32[] memory oversized = new bytes32[](stateView.MAX_BATCH() + 1);
        _mustRevertWith(
            address(stateView),
            abi.encodeCall(BossStateView.subscriptions, (address(account), oversized)),
            BossStateView.InvalidBatch.selector
        );
        _mustRevertWith(
            address(stateView),
            abi.encodeCall(BossStateView.subscriptions, (address(account), new bytes32[](0))),
            BossStateView.InvalidBatch.selector
        );
    }

    function testClaimSnapshotMatchesAccountPreflightAndReportsBothReplayGuards() public {
        VM.roll(500);
        (, MockStateAccount account, BossStateView stateView) = _fixture();
        BossTypes.Subscription memory subscription = _activeSubscription(3);
        subscription.billingKind = BossTypes.BillingKind.METERED_FIXED_LOCKUP;
        subscription.reporter = address(0xCAFE);
        subscription.acceptedEpoch = 100;
        subscription.activatedEpoch = 110;
        subscription.lastUsageToEpoch = 120;
        subscription.caps.chargeWindowEpochs = 100;
        subscription.caps.maxChargePerWindow = 10 ether;
        subscription.caps.lifetimeCapGross = 20 ether;
        subscription.oneTimeChargedGross = 5 ether;
        account.setSubscription(SUBSCRIPTION, subscription, false);

        BossTypes.UsageClaim memory candidate = _claim(keccak256("candidate"), 120, 130, 9);
        account.setUsageClaimState(SUBSCRIPTION, candidate.claimId, candidate.nonce, 0, false, true, 5 ether);
        BossStateView.ClaimSnapshot memory snapshot = stateView.claim(address(account), SUBSCRIPTION, candidate);
        require(snapshot.subscriptionExists && snapshot.windowValid, "candidate invalid");
        require(!snapshot.claimConsumed && snapshot.nonceConsumed, "replay guards");
        require(snapshot.window == 0 && snapshot.windowGross == 5 ether, "window state");
        require(snapshot.remainingWindowGross == 5 ether, "window remaining");
        require(snapshot.remainingLifetimeGross == 15 ether, "lifetime remaining");

        BossTypes.UsageClaim memory invalid = candidate;
        invalid.claimId = bytes32(0);
        require(!stateView.claim(address(account), SUBSCRIPTION, invalid).windowValid, "zero claim id");
        invalid = candidate;
        invalid.toEpoch = 501;
        require(!stateView.claim(address(account), SUBSCRIPTION, invalid).windowValid, "future claim");
        invalid = candidate;
        invalid.fromEpoch = 105;
        invalid.toEpoch = 115;
        require(!stateView.claim(address(account), SUBSCRIPTION, invalid).windowValid, "pre-activation claim");
        invalid = candidate;
        invalid.fromEpoch = 119;
        invalid.toEpoch = 120;
        require(!stateView.claim(address(account), SUBSCRIPTION, invalid).windowValid, "overlap claim");
    }

    function testRequotesPinnedResourceAndPricingPayloadWithoutSigner() public {
        (MockStatePay pay, MockStateAccount account, BossStateView stateView) = _fixture();
        MockStateResourceAdapter resourceAdapter = new MockStateResourceAdapter();
        MockStatePricingAdapter pricingAdapter = new MockStatePricingAdapter();
        BossAdapterRegistry registry = new BossAdapterRegistry(address(this));
        registry.registerAdapter(address(resourceAdapter), BossTypes.AdapterKind.RESOURCE, 1, "ipfs://mock-resource");
        registry.registerAdapter(address(pricingAdapter), BossTypes.AdapterKind.PRICING, 1, "ipfs://mock-pricing");
        account.setAdapterRegistry(address(registry));

        BossTypes.ResourceRef memory resource = BossTypes.ResourceRef({
            kind: BossTypes.ResourceKind.FWSS_PDP_DATASET,
            chainId: uint64(block.chainid),
            anchor: address(0x1111),
            resourceId: 42,
            context: bytes32(0)
        });
        bytes memory resourceData = bytes("");
        bytes memory pricingData = abi.encode(uint256(1 ether), uint256(86_400));
        bytes32 resourceKey = BossHashes.hashResource(resource);
        resourceAdapter.setStatus(
            BossTypes.ResourceStatus({
                resourceKey: resourceKey,
                exists: true,
                attachable: true,
                billable: true,
                payer: address(this),
                storageProvider: address(0x2222),
                sizeInBytes: 1 << 40,
                statusHash: keccak256("status")
            })
        );
        pricingAdapter.setQuote(
            BossTypes.RateQuote({
                ratePerEpoch: 11_574_074_074_074,
                validThroughEpoch: 0,
                billable: true,
                quoteHash: keccak256("quote"),
                note: "capacity"
            })
        );

        BossTypes.Subscription memory subscription = _activeSubscription(3);
        subscription.resourceKey = resourceKey;
        subscription.resourceDataHash = keccak256(resourceData);
        subscription.pricingDataHash = keccak256(pricingData);
        subscription.resourceAdapter = address(resourceAdapter);
        subscription.pricingAdapter = address(pricingAdapter);
        account.setSubscription(SUBSCRIPTION, subscription, false);
        pay.setRail(subscription.railId, _validRail(address(account), address(this), subscription));

        BossStateView.QuoteSnapshot memory snapshot =
            stateView.quote(address(account), SUBSCRIPTION, resource, resourceData, pricingData);
        require(snapshot.resource.resourceKey == resourceKey, "resource key");
        require(snapshot.quote.ratePerEpoch == 11_574_074_074_074, "rate");
        require(snapshot.quote.quoteHash == keccak256("quote"), "quote hash");

        _mustRevertWith(
            address(stateView),
            abi.encodeCall(
                BossStateView.quote,
                (address(account), SUBSCRIPTION, resource, resourceData, abi.encode(uint256(2 ether)))
            ),
            BossStateView.PricingDataMismatch.selector
        );
    }

    function _fixture() private returns (MockStatePay pay, MockStateAccount account, BossStateView stateView) {
        pay = new MockStatePay();
        account = new MockStateAccount(address(this), address(pay));
        stateView = new BossStateView();
    }

    function _activeSubscription(uint256 railId) private pure returns (BossTypes.Subscription memory subscription) {
        subscription.beneficiary = address(0x1002);
        subscription.token = address(0x1003);
        subscription.railId = railId;
        subscription.state = BossTypes.SubscriptionState.ACTIVE;
    }

    function _validRail(address account, address payer_, BossTypes.Subscription memory subscription)
        private
        pure
        returns (IFilecoinPayV1.RailView memory rail)
    {
        rail.token = subscription.token;
        rail.from = payer_;
        rail.to = subscription.beneficiary;
        rail.operator = account;
        rail.validator = account;
        rail.paymentRate = subscription.acceptedRatePerEpoch;
        rail.lockupFixed = subscription.currentFixedBudget;
    }

    function _claim(bytes32 claimId, uint64 fromEpoch, uint64 toEpoch, uint256 nonce)
        private
        pure
        returns (BossTypes.UsageClaim memory claim)
    {
        claim = BossTypes.UsageClaim({
            claimId: claimId,
            fromEpoch: fromEpoch,
            toEpoch: toEpoch,
            units: 1,
            evidenceHash: keccak256("evidence"),
            evidenceURI: "ipfs://evidence",
            nonce: nonce
        });
    }
}
