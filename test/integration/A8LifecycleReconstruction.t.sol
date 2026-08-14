// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossStateView} from "../../src/BossStateView.sol";
import {IBossAccountEvents} from "../../src/interfaces/IBossAccountEvents.sol";
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
    function roll(uint256 newHeight) external;
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

contract A8LifecycleAccount is IBossAccountEvents {
    address public owner;
    address public payer;
    address public filecoinPay;
    address public serviceRegistry = address(0x5100);
    address public adapterRegistry = address(0xADA7);
    address public factory = address(0xFAC7);
    uint64 public accountVersion = 1;

    mapping(bytes32 subscriptionId => BossTypes.Subscription subscription) private _subscriptions;
    uint256 private _subscriptionCount;
    mapping(uint256 index => bytes32 subscriptionId) private _subscriptionIdAt;
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

    function setSubscription(bytes32 subscriptionId, BossTypes.Subscription memory subscription, bool acknowledged)
        external
    {
        if (_subscriptions[subscriptionId].state == BossTypes.SubscriptionState.NONE) {
            _subscriptionIdAt[_subscriptionCount++] = subscriptionId;
        }
        _subscriptions[subscriptionId] = subscription;
        _subscriptionsByRail[subscription.railId] = subscriptionId;
        _acknowledged[subscriptionId] = acknowledged;
    }

    function setUsageClaimState(
        bytes32 subscriptionId,
        bytes32 claimId,
        uint256 nonce,
        uint256 window,
        bool claimConsumed,
        bool nonceConsumed,
        uint256 gross
    ) external {
        _claimConsumed[subscriptionId][claimId] = claimConsumed;
        _nonceConsumed[subscriptionId][nonce] = nonceConsumed;
        _windowGross[subscriptionId][window] = gross;
    }

    function getSubscription(bytes32 subscriptionId)
        external
        view
        returns (BossTypes.Subscription memory subscription)
    {
        return _subscriptions[subscriptionId];
    }

    function subscriptionIndex(uint256 index) external view returns (bytes32 subscriptionId, uint256 count) {
        return (_subscriptionIdAt[index], _subscriptionCount);
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

    function emitFlatLifecycle(bytes32 subscriptionId) external {
        BossTypes.Subscription memory subscription = _subscriptions[subscriptionId];
        _emitAccepted(subscriptionId, subscription, 10, 0, 0);
        emit SubscriptionActivated(subscriptionId, 100);
        emit SubscriptionPaused(subscriptionId, 110);
        emit SubscriptionResumed(subscriptionId, 115);
        emit SubscriptionTerminationRequested(subscriptionId, 120);
        emit SubscriptionPayTerminationObserved(subscriptionId, subscription.railId, 130);
        emit SubscriptionEnded(subscriptionId, 130);
    }

    function emitCapacityLifecycle(bytes32 subscriptionId, bytes32 statusHash) external {
        BossTypes.Subscription memory subscription = _subscriptions[subscriptionId];
        _emitAccepted(subscriptionId, subscription, 10, 0, 130);
        emit SubscriptionActivated(subscriptionId, 100);
        emit RateSynchronized(subscriptionId, 10, 20, 120, 150, statusHash);
    }

    function emitMeteredLifecycle(bytes32 subscriptionId, BossTypes.UsageClaim memory usageClaim) external {
        BossTypes.Subscription memory subscription = _subscriptions[subscriptionId];
        _emitAccepted(subscriptionId, subscription, 0, 10 ether, 0);
        emit SubscriptionActivated(subscriptionId, 100);
        emit UsageClaimCharged(
            subscriptionId,
            usageClaim.claimId,
            BossHashes.hashUsageClaim(subscriptionId, usageClaim),
            usageClaim.units,
            7 ether,
            5 ether,
            usageClaim.evidenceHash
        );
    }

    function _emitAccepted(
        bytes32 subscriptionId,
        BossTypes.Subscription memory subscription,
        uint256 initialRate,
        uint256 initialFixedBudget,
        uint64 initialQuoteValidThrough
    ) private {
        bytes32 signature = IBossAccountEvents.SubscriptionAccepted.selector;
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            let caps := mload(add(subscription, 0x240))
            let policyWord :=
                or(
                    mload(add(subscription, 0x180)),
                    or(
                        shl(8, mload(add(subscription, 0x1a0))),
                        or(
                            shl(16, mload(add(subscription, 0x1c0))),
                            or(
                                shl(24, mload(add(subscription, 0x1e0))),
                                or(shl(32, mload(add(subscription, 0x200))), shl(40, mload(add(subscription, 0x220))))
                            )
                        )
                    )
                )
            let capEpochs :=
                or(mload(add(caps, 0xa0)), or(shl(64, mload(add(caps, 0xc0))), shl(128, mload(add(caps, 0xe0)))))
            let acceptanceEpochs :=
                or(
                    mload(add(subscription, 0x2e0)),
                    or(shl(64, initialQuoteValidThrough), shl(128, mload(add(subscription, 0x340))))
                )

            mstore(pointer, mload(add(subscription, 0x20)))
            mstore(add(pointer, 0x20), mload(add(subscription, 0x160)))
            mstore(add(pointer, 0x40), mload(add(subscription, 0xc0)))
            mstore(add(pointer, 0x60), mload(add(subscription, 0x100)))
            mstore(add(pointer, 0x80), initialFixedBudget)
            mstore(add(pointer, 0xa0), mload(add(subscription, 0xa0)))
            mstore(add(pointer, 0xc0), mload(add(subscription, 0xe0)))
            mstore(add(pointer, 0xe0), mload(add(subscription, 0x120)))
            mstore(add(pointer, 0x100), mload(add(subscription, 0x140)))
            mstore(add(pointer, 0x120), mload(add(subscription, 0x40)))
            mstore(add(pointer, 0x140), mload(add(subscription, 0x60)))
            mstore(add(pointer, 0x160), mload(add(subscription, 0x80)))
            mstore(add(pointer, 0x180), policyWord)
            mstore(add(pointer, 0x1a0), mload(caps))
            mstore(add(pointer, 0x1c0), mload(add(caps, 0x20)))
            mstore(add(pointer, 0x1e0), mload(add(caps, 0x40)))
            mstore(add(pointer, 0x200), mload(add(caps, 0x60)))
            mstore(add(pointer, 0x220), mload(add(caps, 0x80)))
            mstore(add(pointer, 0x240), capEpochs)
            mstore(add(pointer, 0x260), initialRate)
            mstore(add(pointer, 0x280), acceptanceEpochs)
            mstore(0x40, add(pointer, 0x2a0))
            log4(pointer, 0x2a0, signature, subscriptionId, address(), mload(subscription))
        }
    }

    function _policyWord(BossTypes.Subscription memory subscription) private pure returns (uint256) {
        return uint256(subscription.billingKind) | (uint256(subscription.assuranceKind) << 8)
            | (uint256(subscription.dependencyKind) << 16) | (uint256(subscription.activationKind) << 24)
            | (uint256(subscription.terminationBillingKind) << 32) | (uint256(subscription.pauseAllowed ? 1 : 0) << 40);
    }

    function _capEpochs(BossTypes.CapPolicy memory caps) private pure returns (uint256) {
        return uint256(caps.chargeWindowEpochs) | (uint256(caps.notAfterEpoch) << 64)
            | (uint256(caps.maxLockupPeriod) << 128);
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
        VM.roll(200);
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
        metered.state = BossTypes.SubscriptionState.ACTIVE;

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
        account.setUsageClaimState(METERED_ID, CLAIM_ID, usageClaim.nonce, 0, true, true, 5 ether);

        VM.recordLogs();
        account.emitFlatLifecycle(FLAT_ID);
        account.emitCapacityLifecycle(CAPACITY_ID, STATUS_HASH);
        account.emitMeteredLifecycle(METERED_ID, usageClaim);
        VmA8LifecycleLogs.Log[] memory logs = VM.getRecordedLogs();

        bytes32 acceptedSignature = IBossAccountEvents.SubscriptionAccepted.selector;
        bytes32 activatedSignature = keccak256("SubscriptionActivated(bytes32,uint64)");
        bytes32 rateSignature = keccak256("RateSynchronized(bytes32,uint256,uint256,uint64,uint64,bytes32)");
        bytes32 pausedSignature = keccak256("SubscriptionPaused(bytes32,uint64)");
        bytes32 resumedSignature = keccak256("SubscriptionResumed(bytes32,uint64)");
        bytes32 terminationSignature = keccak256("SubscriptionTerminationRequested(bytes32,uint64)");
        bytes32 payTerminationSignature = keccak256("SubscriptionPayTerminationObserved(bytes32,uint256,uint256)");
        bytes32 endedSignature = keccak256("SubscriptionEnded(bytes32,uint64)");
        bytes32 usageSignature = keccak256("UsageClaimCharged(bytes32,bytes32,bytes32,uint256,uint256,uint256,bytes32)");

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
                if (subscriptionId == FLAT_ID) {
                    require(logs[i].topics[3] == flat.offerHash, "flat accepted offer");
                    require(keccak256(logs[i].data) == keccak256(_acceptedData(flat, 10, 0, 0)), "flat accepted terms");
                } else if (subscriptionId == CAPACITY_ID) {
                    require(logs[i].topics[3] == capacity.offerHash, "capacity accepted offer");
                    require(
                        keccak256(logs[i].data) == keccak256(_acceptedData(capacity, 10, 0, 130)),
                        "capacity accepted terms"
                    );
                } else if (subscriptionId == METERED_ID) {
                    require(logs[i].topics[3] == metered.offerHash, "metered accepted offer");
                    require(
                        keccak256(logs[i].data) == keccak256(_acceptedData(metered, 0, 10 ether, 0)),
                        "metered accepted terms"
                    );
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
                (bytes32 claimHash, uint256 units, uint256 rawGross, uint256 chargedGross, bytes32 evidenceHash) =
                    abi.decode(logs[i].data, (bytes32, uint256, uint256, uint256, bytes32));
                require(claimHash == BossHashes.hashUsageClaim(METERED_ID, usageClaim), "usage claim hash");
                require(units == usageClaim.units, "usage units");
                require(rawGross == 7 ether && chargedGross == 5 ether, "usage gross");
                require(evidenceHash == usageClaim.evidenceHash, "usage evidence");
                meteredClaimObserved = true;
            }
        }

        require(acceptedSeen == 3, "accepted count");
        require(flatActivated && flatPaused && flatResumed, "flat lifecycle");
        require(flatTerminationRequested && flatPayTerminationObserved && flatEnded, "flat termination");
        require(capacityActivated && capacityRateObserved, "capacity lifecycle");
        require(meteredActivated && meteredClaimObserved, "metered lifecycle");

        BossStateView.SubscriptionSnapshot[] memory snapshots = stateView.subscriptionPage(address(account), 0, 3);

        require(snapshots.length == 3, "subscription page length");
        require(
            snapshots[0].exists && !snapshots[0].railRead && !snapshots[0].railAssociationValid, "flat finalized view"
        );
        require(snapshots[0].rail.from == address(0), "flat finalized rail fetched");
        require(snapshots[0].subscription.state == BossTypes.SubscriptionState.ENDED, "flat ended view");
        require(snapshots[0].subscription.payEndEpoch == 130, "flat termination view");
        require(snapshots[1].exists && snapshots[1].railRead && snapshots[1].railAssociationValid, "capacity view");
        require(snapshots[1].subscription.acceptedRatePerEpoch == 20, "capacity rate view");
        require(snapshots[1].subscription.quoteValidThroughEpoch == 150, "capacity quote view");
        require(snapshots[2].exists && snapshots[2].railRead && snapshots[2].railAssociationValid, "metered view");
        require(snapshots[2].grossSpent == 5 ether, "metered gross view");
        require(snapshots[2].remainingLifetimeGross == 5 ether, "metered lifetime view");

        BossStateView.ClaimSnapshot memory historical = stateView.claim(address(account), METERED_ID, usageClaim);
        require(historical.subscriptionExists && !historical.windowValid, "historical overlap accepted");
        require(historical.claimHash == BossHashes.hashUsageClaim(METERED_ID, usageClaim), "historical claim hash");
        (bool claimConsumed, bool nonceConsumed, uint256 windowGross) =
            account.usageClaimState(METERED_ID, usageClaim.claimId, usageClaim.nonce, 0);
        require(claimConsumed && nonceConsumed && windowGross == 5 ether, "historical replay state");

        BossTypes.UsageClaim memory candidate = BossTypes.UsageClaim({
            claimId: keccak256("a8-next-claim"),
            fromEpoch: 110,
            toEpoch: 120,
            units: 1 << 39,
            evidenceHash: keccak256("a8-next-evidence"),
            evidenceURI: "ipfs://a8-next-evidence",
            nonce: 10
        });
        BossStateView.ClaimSnapshot memory claimSnapshot = stateView.claim(address(account), METERED_ID, candidate);
        require(claimSnapshot.subscriptionExists && claimSnapshot.windowValid, "candidate claim view");
        require(claimSnapshot.claimHash == BossHashes.hashUsageClaim(METERED_ID, candidate), "claim hash");
        require(
            claimSnapshot.digest
                == BossHashes.hashTypedData(
                    BossHashes.domainSeparator(block.chainid, address(account)), claimSnapshot.claimHash
                ),
            "claim digest"
        );
        require(claimSnapshot.reporter == REPORTER, "claim reporter");
        require(!claimSnapshot.claimConsumed && !claimSnapshot.nonceConsumed, "fresh replay state");
        require(claimSnapshot.window == 0 && claimSnapshot.windowGross == 5 ether, "claim window");
        require(claimSnapshot.remainingWindowGross == 5 ether, "window remaining");
        require(claimSnapshot.remainingLifetimeGross == 5 ether, "lifetime remaining");
    }

    function _acceptedData(
        BossTypes.Subscription memory subscription,
        uint256 initialRate,
        uint256 initialFixedBudget,
        uint64 initialQuoteValidThrough
    ) private pure returns (bytes memory) {
        return abi.encode(
            subscription.resourceKey,
            subscription.railId,
            subscription.beneficiary,
            subscription.token,
            initialFixedBudget,
            subscription.provider,
            subscription.reporter,
            subscription.resourceAdapter,
            subscription.pricingAdapter,
            subscription.resourceDataHash,
            subscription.pricingDataHash,
            subscription.accessGrantHash,
            _policyWord(subscription),
            subscription.caps.maxRatePerEpoch,
            subscription.caps.maxFixedLockup,
            subscription.caps.maxSingleCharge,
            subscription.caps.maxChargePerWindow,
            subscription.caps.lifetimeCapGross,
            _capEpochs(subscription.caps),
            initialRate,
            uint256(subscription.acceptedEpoch) | (uint256(initialQuoteValidThrough) << 64)
                | (uint256(subscription.quoteTtlEpochs) << 128)
        );
    }

    function _policyWord(BossTypes.Subscription memory subscription) private pure returns (uint256) {
        return uint256(subscription.billingKind) | (uint256(subscription.assuranceKind) << 8)
            | (uint256(subscription.dependencyKind) << 16) | (uint256(subscription.activationKind) << 24)
            | (uint256(subscription.terminationBillingKind) << 32) | (uint256(subscription.pauseAllowed ? 1 : 0) << 40);
    }

    function _capEpochs(BossTypes.CapPolicy memory caps) private pure returns (uint256) {
        return uint256(caps.chargeWindowEpochs) | (uint256(caps.notAfterEpoch) << 64)
            | (uint256(caps.maxLockupPeriod) << 128);
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
