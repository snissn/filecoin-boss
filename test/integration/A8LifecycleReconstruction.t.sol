// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossStateView} from "../../src/BossStateView.sol";
import {IFilecoinPayV1} from "../../src/interfaces/IFilecoinPayV1.sol";
import {BossHashes} from "../../src/libraries/BossHashes.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";

interface VmA8LifecycleLogs {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}

contract A8LifecyclePay {
    mapping(uint256 railId => IFilecoinPayV1.RailView rail) private _rails;

    function setRail(uint256 railId, IFilecoinPayV1.RailView memory rail) external {
        _rails[railId] = rail;
    }

    function getRail(uint256 railId) external view returns (IFilecoinPayV1.RailView memory rail) {
        return _rails[railId];
    }
}

contract A8LifecycleAccount {
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
    mapping(bytes32 subscriptionId => mapping(uint256 window => uint256 gross)) private _windowGross;

    event SubscriptionAccepted(
        bytes32 indexed subscriptionId,
        address indexed account,
        bytes32 indexed offerHash,
        bytes32 resourceKey,
        uint256 railId,
        address beneficiary,
        address token,
        uint256 initialRate,
        uint256 initialFixedBudget
    );
    event SubscriptionActivated(bytes32 indexed subscriptionId, uint64 activatedEpoch);
    event RateSynchronized(
        bytes32 indexed subscriptionId,
        uint256 oldRate,
        uint256 newRate,
        uint64 quoteEpoch,
        uint64 validThroughEpoch,
        bytes32 resourceStatusHash
    );
    event SubscriptionPaused(bytes32 indexed subscriptionId, uint64 pausedEpoch);
    event SubscriptionResumed(bytes32 indexed subscriptionId, uint64 resumedEpoch);
    event SubscriptionTerminationRequested(bytes32 indexed subscriptionId, uint64 requestEpoch);
    event SubscriptionPayTerminationObserved(bytes32 indexed subscriptionId, uint256 indexed railId, uint256 endEpoch);
    event SubscriptionEnded(bytes32 indexed subscriptionId, uint64 endedEpoch);
    event UsageClaimCharged(
        bytes32 indexed subscriptionId,
        bytes32 indexed claimId,
        bytes32 claimHash,
        uint256 rawGross,
        uint256 chargedGross
    );

    constructor(address owner_, address pay_) {
        owner = owner_;
        payer = owner_;
        filecoinPay = pay_;
    }

    function setSubscription(bytes32 subscriptionId, BossTypes.Subscription memory subscription, bool acknowledged)
        external
    {
        _subscriptions[subscriptionId] = subscription;
        _subscriptionsByRail[subscription.railId] = subscriptionId;
        _acknowledged[subscriptionId] = acknowledged;
    }

    function setUsageClaimState(bytes32 subscriptionId, bytes32 claimId, uint256 window, uint256 gross) external {
        _claimConsumed[subscriptionId][claimId] = true;
        _windowGross[subscriptionId][window] = gross;
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

    function usageClaimState(bytes32 subscriptionId, bytes32 claimId, uint256 window)
        external
        view
        returns (bool claimConsumed, uint256 windowGross)
    {
        return (_claimConsumed[subscriptionId][claimId], _windowGross[subscriptionId][window]);
    }

    function emitFlatLifecycle(bytes32 subscriptionId) external {
        BossTypes.Subscription memory subscription = _subscriptions[subscriptionId];
        emit SubscriptionAccepted(
            subscriptionId,
            address(this),
            subscription.offerHash,
            subscription.resourceKey,
            subscription.railId,
            subscription.beneficiary,
            subscription.token,
            10,
            0
        );
        emit SubscriptionActivated(subscriptionId, 100);
        emit SubscriptionPaused(subscriptionId, 110);
        emit SubscriptionResumed(subscriptionId, 115);
        emit SubscriptionTerminationRequested(subscriptionId, 120);
        emit SubscriptionPayTerminationObserved(subscriptionId, subscription.railId, 130);
        emit SubscriptionEnded(subscriptionId, 130);
    }

    function emitCapacityLifecycle(bytes32 subscriptionId, bytes32 statusHash) external {
        BossTypes.Subscription memory subscription = _subscriptions[subscriptionId];
        emit SubscriptionAccepted(
            subscriptionId,
            address(this),
            subscription.offerHash,
            subscription.resourceKey,
            subscription.railId,
            subscription.beneficiary,
            subscription.token,
            10,
            0
        );
        emit SubscriptionActivated(subscriptionId, 100);
        emit RateSynchronized(subscriptionId, 10, 20, 120, 150, statusHash);
    }

    function emitMeteredLifecycle(bytes32 subscriptionId, BossTypes.UsageClaim memory usageClaim) external {
        BossTypes.Subscription memory subscription = _subscriptions[subscriptionId];
        emit SubscriptionAccepted(
            subscriptionId,
            address(this),
            subscription.offerHash,
            subscription.resourceKey,
            subscription.railId,
            subscription.beneficiary,
            subscription.token,
            0,
            10 ether
        );
        emit SubscriptionActivated(subscriptionId, 100);
        emit UsageClaimCharged(
            subscriptionId, usageClaim.claimId, BossHashes.hashUsageClaim(subscriptionId, usageClaim), 7 ether, 5 ether
        );
    }
}

contract A8LifecycleReconstructionTest {
    VmA8LifecycleLogs private constant VM = VmA8LifecycleLogs(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant FLAT_ID = keccak256("a8-flat");
    bytes32 private constant CAPACITY_ID = keccak256("a8-capacity");
    bytes32 private constant METERED_ID = keccak256("a8-metered");
    bytes32 private constant CLAIM_ID = keccak256("a8-claim");
    bytes32 private constant EVIDENCE_HASH = keccak256("a8-evidence");
    bytes32 private constant STATUS_HASH = keccak256("a8-capacity-status");
    address private constant BENEFICIARY = address(0xBEEF);
    address private constant TOKEN = address(0x1003);
    address private constant REPORTER = address(0xCAFE);

    function testReconstructsFlatCapacityAndMeteredLifecycleFromEventsAndViews() public {
        A8LifecyclePay pay = new A8LifecyclePay();
        A8LifecycleAccount account = new A8LifecycleAccount(address(this), address(pay));
        BossStateView stateView = new BossStateView();

        BossTypes.Subscription memory flat;
        flat.offerHash = keccak256("flat-offer");
        flat.resourceKey = keccak256("flat-resource");
        flat.beneficiary = BENEFICIARY;
        flat.token = TOKEN;
        flat.railId = 1;
        flat.billingKind = BossTypes.BillingKind.STREAM_FLAT;
        flat.caps.lifetimeCapGross = 1_000;
        flat.acceptedRatePerEpoch = 10;
        flat.settledGross = 200;
        flat.acceptedEpoch = 100;
        flat.activatedEpoch = 100;
        flat.pausedEpoch = 110;
        flat.terminationRequestedEpoch = 120;
        flat.payEndEpoch = 130;
        flat.state = BossTypes.SubscriptionState.ENDED;

        BossTypes.Subscription memory capacity;
        capacity.offerHash = keccak256("capacity-offer");
        capacity.resourceKey = keccak256("capacity-resource");
        capacity.beneficiary = BENEFICIARY;
        capacity.token = TOKEN;
        capacity.railId = 2;
        capacity.billingKind = BossTypes.BillingKind.STREAM_CAPACITY;
        capacity.caps.lifetimeCapGross = type(uint256).max;
        capacity.acceptedRatePerEpoch = 20;
        capacity.settledGross = 100;
        capacity.acceptedEpoch = 100;
        capacity.activatedEpoch = 100;
        capacity.quoteValidThroughEpoch = 150;
        capacity.quoteTtlEpochs = 30;
        capacity.state = BossTypes.SubscriptionState.ACTIVE;

        BossTypes.Subscription memory metered;
        metered.offerHash = keccak256("metered-offer");
        metered.resourceKey = keccak256("metered-resource");
        metered.beneficiary = BENEFICIARY;
        metered.reporter = REPORTER;
        metered.token = TOKEN;
        metered.railId = 3;
        metered.billingKind = BossTypes.BillingKind.METERED_FIXED_LOCKUP;
        metered.caps.maxFixedLockup = 10 ether;
        metered.caps.maxSingleCharge = 5 ether;
        metered.caps.maxChargePerWindow = 10 ether;
        metered.caps.lifetimeCapGross = 10 ether;
        metered.caps.chargeWindowEpochs = 100;
        metered.oneTimeChargedGross = 5 ether;
        metered.currentFixedBudget = 5 ether;
        metered.acceptedEpoch = 100;
        metered.activatedEpoch = 100;
        metered.lastUsageToEpoch = 110;
        metered.state = BossTypes.SubscriptionState.EXHAUSTED;

        account.setSubscription(FLAT_ID, flat, true);
        account.setSubscription(CAPACITY_ID, capacity, true);
        account.setSubscription(METERED_ID, metered, true);

        pay.setRail(flat.railId, _rail(address(account), flat, 0, 130));
        pay.setRail(capacity.railId, _rail(address(account), capacity, 20, 0));
        pay.setRail(metered.railId, _rail(address(account), metered, 0, 0));

        BossTypes.UsageClaim memory usageClaim = BossTypes.UsageClaim({
            claimId: CLAIM_ID,
            fromEpoch: 100,
            toEpoch: 110,
            units: 1 << 40,
            evidenceHash: EVIDENCE_HASH,
            evidenceURI: "ipfs://a8-evidence",
            nonce: 9
        });
        account.setUsageClaimState(METERED_ID, CLAIM_ID, 0, 5 ether);

        VM.recordLogs();
        account.emitFlatLifecycle(FLAT_ID);
        account.emitCapacityLifecycle(CAPACITY_ID, STATUS_HASH);
        account.emitMeteredLifecycle(METERED_ID, usageClaim);
        VmA8LifecycleLogs.Log[] memory logs = VM.getRecordedLogs();

        bytes32 acceptedSignature =
            keccak256("SubscriptionAccepted(bytes32,address,bytes32,bytes32,uint256,address,address,uint256,uint256)");
        bytes32 activatedSignature = keccak256("SubscriptionActivated(bytes32,uint64)");
        bytes32 rateSignature = keccak256("RateSynchronized(bytes32,uint256,uint256,uint64,uint64,bytes32)");
        bytes32 pausedSignature = keccak256("SubscriptionPaused(bytes32,uint64)");
        bytes32 resumedSignature = keccak256("SubscriptionResumed(bytes32,uint64)");
        bytes32 terminationSignature = keccak256("SubscriptionTerminationRequested(bytes32,uint64)");
        bytes32 payTerminationSignature = keccak256("SubscriptionPayTerminationObserved(bytes32,uint256,uint256)");
        bytes32 endedSignature = keccak256("SubscriptionEnded(bytes32,uint64)");
        bytes32 usageSignature = keccak256("UsageClaimCharged(bytes32,bytes32,bytes32,uint256,uint256)");

        uint256 acceptedSeen;
        bool flatActivated;
        bool flatPaused;
        bool flatResumed;
        bool flatTerminationRequested;
        bool flatPayTerminationObserved;
        bool flatEnded;
        bool capacityActivated;
        bool capacityRateObserved;
        bool meteredActivated;
        bool meteredClaimObserved;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(account) || logs[i].topics.length == 0) continue;
            bytes32 signature = logs[i].topics[0];
            bytes32 subscriptionId = logs[i].topics.length > 1 ? logs[i].topics[1] : bytes32(0);

            if (signature == acceptedSignature) {
                require(logs[i].topics.length == 4, "accepted topics");
                require(address(uint160(uint256(logs[i].topics[2]))) == address(account), "accepted account");
                BossTypes.Subscription memory recorded = account.getSubscription(subscriptionId);
                require(logs[i].topics[3] == recorded.offerHash, "accepted offer");
                (
                    bytes32 resourceKey,
                    uint256 railId,
                    address beneficiary,
                    address token,
                    uint256 initialRate,
                    uint256 initialFixedBudget
                ) = abi.decode(logs[i].data, (bytes32, uint256, address, address, uint256, uint256));
                require(resourceKey == recorded.resourceKey, "accepted resource");
                require(railId == recorded.railId, "accepted rail");
                require(beneficiary == recorded.beneficiary && token == recorded.token, "accepted recipients");
                if (subscriptionId == FLAT_ID) {
                    require(initialRate == 10 && initialFixedBudget == 0, "flat accepted terms");
                } else if (subscriptionId == CAPACITY_ID) {
                    require(initialRate == 10 && initialFixedBudget == 0, "capacity accepted terms");
                } else if (subscriptionId == METERED_ID) {
                    require(initialRate == 0 && initialFixedBudget == 10 ether, "metered accepted terms");
                } else {
                    revert("unknown accepted subscription");
                }
                ++acceptedSeen;
            } else if (signature == activatedSignature) {
                if (subscriptionId == FLAT_ID) flatActivated = true;
                else if (subscriptionId == CAPACITY_ID) capacityActivated = true;
                else if (subscriptionId == METERED_ID) meteredActivated = true;
            } else if (signature == rateSignature) {
                require(subscriptionId == CAPACITY_ID, "rate subscription");
                (uint256 oldRate, uint256 newRate, uint64 quoteEpoch, uint64 validThrough, bytes32 statusHash) =
                    abi.decode(logs[i].data, (uint256, uint256, uint64, uint64, bytes32));
                require(oldRate == 10 && newRate == 20, "rate values");
                require(quoteEpoch == 120 && validThrough == 150, "rate epochs");
                require(statusHash == STATUS_HASH, "rate status");
                capacityRateObserved = true;
            } else if (signature == pausedSignature) {
                require(subscriptionId == FLAT_ID, "pause subscription");
                flatPaused = true;
            } else if (signature == resumedSignature) {
                require(subscriptionId == FLAT_ID, "resume subscription");
                flatResumed = true;
            } else if (signature == terminationSignature) {
                require(subscriptionId == FLAT_ID, "termination subscription");
                flatTerminationRequested = true;
            } else if (signature == payTerminationSignature) {
                require(subscriptionId == FLAT_ID, "pay termination subscription");
                require(uint256(logs[i].topics[2]) == flat.railId, "pay termination rail");
                require(abi.decode(logs[i].data, (uint256)) == 130, "pay termination epoch");
                flatPayTerminationObserved = true;
            } else if (signature == endedSignature) {
                require(subscriptionId == FLAT_ID, "ended subscription");
                require(abi.decode(logs[i].data, (uint64)) == 130, "ended epoch");
                flatEnded = true;
            } else if (signature == usageSignature) {
                require(subscriptionId == METERED_ID, "usage subscription");
                require(logs[i].topics[2] == CLAIM_ID, "usage claim id");
                (bytes32 claimHash, uint256 rawGross, uint256 chargedGross) =
                    abi.decode(logs[i].data, (bytes32, uint256, uint256));
                require(claimHash == BossHashes.hashUsageClaim(METERED_ID, usageClaim), "usage claim hash");
                require(rawGross == 7 ether && chargedGross == 5 ether, "usage gross");
                meteredClaimObserved = true;
            }
        }

        require(acceptedSeen == 3, "accepted count");
        require(flatActivated && flatPaused && flatResumed, "flat lifecycle");
        require(flatTerminationRequested && flatPayTerminationObserved && flatEnded, "flat termination");
        require(capacityActivated && capacityRateObserved, "capacity lifecycle");
        require(meteredActivated && meteredClaimObserved, "metered lifecycle");

        bytes32[] memory subscriptionIds = new bytes32[](3);
        subscriptionIds[0] = FLAT_ID;
        subscriptionIds[1] = CAPACITY_ID;
        subscriptionIds[2] = METERED_ID;
        BossStateView.SubscriptionSnapshot[] memory snapshots =
            stateView.subscriptions(address(account), subscriptionIds);

        require(snapshots[0].exists && snapshots[0].railAssociationValid, "flat view");
        require(snapshots[0].subscription.state == BossTypes.SubscriptionState.ENDED, "flat ended view");
        require(snapshots[0].subscription.payEndEpoch == 130, "flat termination view");
        require(snapshots[1].exists && snapshots[1].railAssociationValid, "capacity view");
        require(snapshots[1].subscription.acceptedRatePerEpoch == 20, "capacity rate view");
        require(snapshots[1].subscription.quoteValidThroughEpoch == 150, "capacity quote view");
        require(snapshots[2].exists && snapshots[2].railAssociationValid, "metered view");
        require(snapshots[2].grossSpent == 5 ether, "metered gross view");
        require(snapshots[2].remainingLifetimeGross == 5 ether, "metered lifetime view");

        BossStateView.ClaimSnapshot memory claimSnapshot = stateView.claim(address(account), METERED_ID, usageClaim);
        require(claimSnapshot.subscriptionExists && claimSnapshot.windowValid, "claim view existence");
        require(claimSnapshot.claimHash == BossHashes.hashUsageClaim(METERED_ID, usageClaim), "claim hash");
        require(
            claimSnapshot.digest
                == BossHashes.hashTypedData(
                    BossHashes.domainSeparator(block.chainid, address(account)), claimSnapshot.claimHash
                ),
            "claim digest"
        );
        require(claimSnapshot.reporter == REPORTER, "claim reporter");
        require(claimSnapshot.claimConsumed, "claim consumption");
        require(claimSnapshot.window == 0 && claimSnapshot.windowGross == 5 ether, "claim window");
        require(claimSnapshot.remainingWindowGross == 5 ether, "window remaining");
        require(claimSnapshot.remainingLifetimeGross == 5 ether, "lifetime remaining");
    }

    function _rail(address account, BossTypes.Subscription memory subscription, uint256 rate, uint256 endEpoch)
        private
        view
        returns (IFilecoinPayV1.RailView memory rail)
    {
        rail = IFilecoinPayV1.RailView({
            token: subscription.token,
            from: address(this),
            to: subscription.beneficiary,
            operator: account,
            validator: account,
            paymentRate: rate,
            lockupPeriod: 0,
            lockupFixed: subscription.currentFixedBudget,
            settledUpTo: subscription.acceptedEpoch,
            endEpoch: endEpoch,
            commissionRateBps: 0,
            serviceFeeRecipient: address(0)
        });
    }
}
