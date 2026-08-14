// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossAdapterRegistry} from "../../src/BossAdapterRegistry.sol";
import {BossStateView} from "../../src/BossStateView.sol";
import {IBossPricingAdapter} from "../../src/interfaces/IBossPricingAdapter.sol";
import {IBossResourceAdapter} from "../../src/interfaces/IBossResourceAdapter.sol";
import {IFilecoinPayV1} from "../../src/interfaces/IFilecoinPayV1.sol";
import {BossHashes} from "../../src/libraries/BossHashes.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";

contract MockStatePay {
    mapping(uint256 => IFilecoinPayV1.RailView) private _rails;

    function setRail(uint256 railId, IFilecoinPayV1.RailView memory rail) external {
        _rails[railId] = rail;
    }

    function getRail(uint256 railId) external view returns (IFilecoinPayV1.RailView memory rail) {
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

    mapping(bytes32 => BossTypes.Subscription) private _subscriptions;
    mapping(uint256 => bytes32) private _subscriptionsByRail;
    mapping(bytes32 => bool) private _acknowledged;

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

contract BossStateViewTest {
    bytes32 private constant SUBSCRIPTION = keccak256("subscription");
    bytes32 private constant MISSING = keccak256("missing");

    function testReturnsAccountSubscriptionRailAndCapSnapshot() public {
        MockStatePay pay = new MockStatePay();
        MockStateAccount account = new MockStateAccount(address(this), address(pay));
        BossStateView stateView = new BossStateView();

        BossTypes.Subscription memory subscription;
        subscription.offerHash = keccak256("offer");
        subscription.resourceKey = keccak256("resource");
        subscription.provider = address(0x1001);
        subscription.beneficiary = address(0x1002);
        subscription.token = address(0x1003);
        subscription.railId = 9;
        subscription.billingKind = BossTypes.BillingKind.STREAM_CAPACITY;
        subscription.caps.lifetimeCapGross = 100;
        subscription.acceptedRatePerEpoch = 7;
        subscription.settledGross = 20;
        subscription.oneTimeChargedGross = 10;
        subscription.currentFixedBudget = 30;
        subscription.state = BossTypes.SubscriptionState.ACTIVE;
        account.setSubscription(SUBSCRIPTION, subscription, true);

        IFilecoinPayV1.RailView memory rail;
        rail.token = subscription.token;
        rail.from = address(this);
        rail.to = subscription.beneficiary;
        rail.operator = address(account);
        rail.validator = address(account);
        rail.paymentRate = subscription.acceptedRatePerEpoch;
        rail.lockupFixed = subscription.currentFixedBudget;
        pay.setRail(subscription.railId, rail);

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

        BossStateView.SubscriptionSnapshot memory missing = stateView.subscription(address(account), MISSING);
        require(!missing.exists, "missing exists");
    }

    function testBatchIsBoundedAndPreservesMissingEntries() public {
        MockStatePay pay = new MockStatePay();
        MockStateAccount account = new MockStateAccount(address(this), address(pay));
        BossStateView stateView = new BossStateView();

        BossTypes.Subscription memory subscription;
        subscription.railId = 1;
        subscription.state = BossTypes.SubscriptionState.ACTIVE;
        subscription.caps.lifetimeCapGross = type(uint256).max;
        account.setSubscription(SUBSCRIPTION, subscription, false);

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
        _mustFail(address(stateView), abi.encodeCall(BossStateView.subscriptions, (address(account), oversized)));
    }

    function testRequotesPinnedResourceAndPricingPayloadWithoutSigner() public {
        MockStatePay pay = new MockStatePay();
        MockStateAccount account = new MockStateAccount(address(this), address(pay));
        MockStateResourceAdapter resourceAdapter = new MockStateResourceAdapter();
        MockStatePricingAdapter pricingAdapter = new MockStatePricingAdapter();
        BossAdapterRegistry registry = new BossAdapterRegistry(address(this));
        registry.registerAdapter(address(resourceAdapter), BossTypes.AdapterKind.RESOURCE, 1, "ipfs://mock-resource");
        registry.registerAdapter(address(pricingAdapter), BossTypes.AdapterKind.PRICING, 1, "ipfs://mock-pricing");
        account.setAdapterRegistry(address(registry));
        BossStateView stateView = new BossStateView();

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

        BossTypes.ResourceStatus memory status = BossTypes.ResourceStatus({
            resourceKey: resourceKey,
            exists: true,
            attachable: true,
            billable: true,
            payer: address(this),
            storageProvider: address(0x2222),
            sizeInBytes: 1 << 40,
            statusHash: keccak256("status")
        });
        resourceAdapter.setStatus(status);
        pricingAdapter.setQuote(
            BossTypes.RateQuote({
                ratePerEpoch: 11_574_074_074_074,
                validThroughEpoch: 0,
                billable: true,
                quoteHash: keccak256("quote"),
                note: "capacity"
            })
        );

        BossTypes.Subscription memory subscription;
        subscription.resourceKey = resourceKey;
        subscription.resourceDataHash = keccak256(resourceData);
        subscription.pricingDataHash = keccak256(pricingData);
        subscription.resourceAdapter = address(resourceAdapter);
        subscription.pricingAdapter = address(pricingAdapter);
        subscription.railId = 3;
        subscription.state = BossTypes.SubscriptionState.ACTIVE;
        account.setSubscription(SUBSCRIPTION, subscription, false);

        BossStateView.QuoteSnapshot memory snapshot =
            stateView.quote(address(account), SUBSCRIPTION, resource, resourceData, pricingData);
        require(snapshot.resource.resourceKey == resourceKey, "resource key");
        require(snapshot.resource.statusHash == status.statusHash, "status hash");
        require(snapshot.quote.ratePerEpoch == 11_574_074_074_074, "rate");
        require(snapshot.quote.quoteHash == keccak256("quote"), "quote hash");

        _mustFail(
            address(stateView),
            abi.encodeCall(
                BossStateView.quote,
                (address(account), SUBSCRIPTION, resource, resourceData, abi.encode(uint256(2 ether)))
            )
        );
    }

    function _mustFail(address target, bytes memory callData) private {
        (bool success,) = target.call(callData);
        require(!success, "expected failure");
    }
}
