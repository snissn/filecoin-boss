from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 anchor, found {count}")
    return text.replace(old, new)


# --- BossAccount: expose compact claim state and normalize claim event provenance. ---
account_path = Path("src/BossAccount.sol")
account = account_path.read_text()

account = replace_once(
    account,
    """    event UsageClaimCharged(
        bytes32 indexed subscriptionId,
        bytes32 indexed claimId,
        uint256 units,
        uint256 rawGross,
        uint256 chargedGross,
        bytes32 evidenceHash
    );
""",
    """    event UsageClaimCharged(
        bytes32 indexed subscriptionId,
        bytes32 indexed claimId,
        uint64 fromEpoch,
        uint64 toEpoch,
        uint256 units,
        uint256 rawGross,
        uint256 chargedGross,
        bytes32 evidenceHash,
        uint256 nonce
    );
""",
    "usage event",
)

account = replace_once(
    account,
    """    address public immutable owner;
    address public immutable payer;
    address public immutable filecoinPay;
    address public immutable serviceRegistry;
    address public immutable adapterRegistry;
    address public immutable factory;
    uint64 public immutable accountVersion;
""",
    """    address public immutable owner;
    address public immutable filecoinPay;
    address public immutable serviceRegistry;
    address public immutable adapterRegistry;
    address public immutable factory;
""",
    "immutable declarations",
)

account = replace_once(account, "        payer = owner_;\n", "", "payer assignment")
account = replace_once(account, "        accountVersion = accountVersion_;\n", "", "version assignment")
account = replace_once(
    account,
    """        factory = msg.sender;
    }

    function acceptOffer(BossTypes.AcceptanceInput calldata input)
""",
    """        factory = msg.sender;
    }

    function payer() external view returns (address) {
        return owner;
    }

    function accountVersion() external pure returns (uint64) {
        return 1;
    }

    function acceptOffer(BossTypes.AcceptanceInput calldata input)
""",
    "derived account getters",
)

account = replace_once(
    account,
    ".inspect(input.resource, payer, input.resourceData)",
    ".inspect(input.resource, owner, input.resourceData)",
    "accept inspect payer",
)
count = account.count("resource.payer != payer")
if count != 2:
    raise SystemExit(f"resource payer checks: expected 2 anchors, found {count}")
account = account.replace("resource.payer != payer", "resource.payer != owner")
account = replace_once(
    account,
    "offer.token, payer, offer.beneficiary",
    "offer.token, owner, offer.beneficiary",
    "rail payer",
)
account = replace_once(
    account,
    ".inspect(resourceRef, payer, bytes(\"\"))",
    ".inspect(resourceRef, owner, bytes(\"\"))",
    "sync inspect payer",
)

account = replace_once(
    account,
    """        emit UsageClaimCharged(subscriptionId, claim.claimId, claim.units, rawGross, chargedGross, claim.evidenceHash);
""",
    """        emit UsageClaimCharged(
            subscriptionId,
            claim.claimId,
            claim.fromEpoch,
            claim.toEpoch,
            claim.units,
            rawGross,
            chargedGross,
            claim.evidenceHash,
            claim.nonce
        );
""",
    "usage event emission",
)

account = replace_once(
    account,
    """    function activationAcknowledged(bytes32 subscriptionId) external view returns (bool) {
        return _activationAcknowledged[subscriptionId];
    }

    function validatePayment(uint256 railId, uint256 proposedAmount, uint256 fromEpoch, uint256 toEpoch, uint256 rate)
""",
    """    function activationAcknowledged(bytes32 subscriptionId) external view returns (bool) {
        return _activationAcknowledged[subscriptionId];
    }

    function usageClaimState(bytes32 subscriptionId, bytes32 claimId, uint256 nonce, uint256 window)
        external
        view
        returns (bool claimConsumed, bool nonceConsumed, uint256 windowGross)
    {
        return (
            _consumedClaims[subscriptionId][claimId],
            _consumedUsageNonces[subscriptionId][nonce],
            _usageGrossByWindow[subscriptionId][window]
        );
    }

    function validatePayment(uint256 railId, uint256 proposedAmount, uint256 fromEpoch, uint256 toEpoch, uint256 rate)
""",
    "claim state getter",
)

account_path.write_text(account)


# --- BossStateView: canonical claim hash/consumption/cap read without a second ledger. ---
view_path = Path("src/BossStateView.sol")
view = view_path.read_text()

view = replace_once(
    view,
    """    function subscriptionForRail(uint256 railId) external view returns (bytes32);
    function activationAcknowledged(bytes32 subscriptionId) external view returns (bool);
}
""",
    """    function subscriptionForRail(uint256 railId) external view returns (bytes32);
    function activationAcknowledged(bytes32 subscriptionId) external view returns (bool);

    function usageClaimState(bytes32 subscriptionId, bytes32 claimId, uint256 nonce, uint256 window)
        external
        view
        returns (bool claimConsumed, bool nonceConsumed, uint256 windowGross);
}
""",
    "read interface claim state",
)

view = replace_once(
    view,
    """    struct QuoteSnapshot {
        BossTypes.ResourceStatus resource;
        BossTypes.RateQuote quote;
    }

    function account(address accountAddress) external view returns (AccountSnapshot memory snapshot) {
""",
    """    struct QuoteSnapshot {
        BossTypes.ResourceStatus resource;
        BossTypes.RateQuote quote;
    }

    struct ClaimSnapshot {
        bool subscriptionExists;
        bool windowValid;
        bytes32 subscriptionId;
        bytes32 claimHash;
        bytes32 digest;
        address reporter;
        bool claimConsumed;
        bool nonceConsumed;
        uint256 window;
        uint256 windowGross;
        uint256 remainingWindowGross;
        uint256 remainingLifetimeGross;
    }

    function account(address accountAddress) external view returns (AccountSnapshot memory snapshot) {
""",
    "claim snapshot struct",
)

view = replace_once(
    view,
    """        snapshot.quote = IBossPricingAdapter(subscription_.pricingAdapter).quoteRate(snapshot.resource, pricingData);
    }

    function _subscription(IBossAccountRead account_, address accountAddress, bytes32 subscriptionId)
""",
    """        snapshot.quote = IBossPricingAdapter(subscription_.pricingAdapter).quoteRate(snapshot.resource, pricingData);
    }

    function claim(address accountAddress, bytes32 subscriptionId, BossTypes.UsageClaim calldata usageClaim)
        external
        view
        returns (ClaimSnapshot memory snapshot)
    {
        IBossAccountRead account_ = _account(accountAddress);
        BossTypes.Subscription memory subscription_ = account_.getSubscription(subscriptionId);
        snapshot.subscriptionId = subscriptionId;
        if (subscription_.state == BossTypes.SubscriptionState.NONE) return snapshot;

        snapshot.subscriptionExists = true;
        snapshot.claimHash = BossHashes.hashUsageClaim(subscriptionId, usageClaim);
        snapshot.digest = BossHashes.hashTypedData(
            BossHashes.domainSeparator(block.chainid, accountAddress), snapshot.claimHash
        );
        snapshot.reporter = subscription_.reporter;
        uint256 grossSpent = subscription_.settledGross + subscription_.oneTimeChargedGross;
        snapshot.remainingLifetimeGross =
            BossTypes.remainingCap(subscription_.caps.lifetimeCapGross, grossSpent);

        uint256 windowSize = subscription_.caps.chargeWindowEpochs;
        if (
            windowSize == 0 || usageClaim.toEpoch <= usageClaim.fromEpoch
                || usageClaim.fromEpoch < subscription_.acceptedEpoch
        ) return snapshot;

        uint256 startWindow = (uint256(usageClaim.fromEpoch) - subscription_.acceptedEpoch) / windowSize;
        uint256 endWindow = (uint256(usageClaim.toEpoch) - 1 - subscription_.acceptedEpoch) / windowSize;
        if (startWindow != endWindow) return snapshot;

        snapshot.windowValid = true;
        snapshot.window = startWindow;
        (snapshot.claimConsumed, snapshot.nonceConsumed, snapshot.windowGross) =
            account_.usageClaimState(subscriptionId, usageClaim.claimId, usageClaim.nonce, startWindow);
        snapshot.remainingWindowGross =
            BossTypes.remainingCap(subscription_.caps.maxChargePerWindow, snapshot.windowGross);
    }

    function _subscription(IBossAccountRead account_, address accountAddress, bytes32 subscriptionId)
""",
    "claim view",
)

view_path.write_text(view)


# --- Production claim-state test. ---
usage_test_path = Path("test/unit/BossUsageClaims.t.sol")
usage_test = usage_test_path.read_text()
usage_test = replace_once(
    usage_test,
    """        require(account.submitUsageClaim(subscriptionId, claim, _signClaim(subscriptionId, claim)) == 0, "zero charge");
        require(pay.oneTimeGross(railId) == 0, "no Pay payment");
        _mustFailClaim(subscriptionId, claim, _signClaim(subscriptionId, claim));
""",
    """        require(account.submitUsageClaim(subscriptionId, claim, _signClaim(subscriptionId, claim)) == 0, "zero charge");
        require(pay.oneTimeGross(railId) == 0, "no Pay payment");
        (bool claimConsumed, bool nonceConsumed, uint256 windowGross) =
            account.usageClaimState(subscriptionId, claim.claimId, claim.nonce, 0);
        require(claimConsumed, "claim consumption not readable");
        require(nonceConsumed, "nonce consumption not readable");
        require(windowGross == 0, "zero claim changed window gross");
        _mustFailClaim(subscriptionId, claim, _signClaim(subscriptionId, claim));
""",
    "claim state production test",
)
usage_test_path.write_text(usage_test)


# --- Bundle authority and pagination-gas guardrails. ---
bundle_test_path = Path("test/unit/BossBundles.t.sol")
bundle_test = bundle_test_path.read_text()
bundle_test = replace_once(
    bundle_test,
    """        bytes32[] memory first = bundles.components(bundleId, 0, 1);
        bytes32[] memory second = bundles.components(bundleId, 1, 10);
        bytes32[] memory pastEnd = bundles.components(bundleId, 2, 1);
""",
    """        uint256 gasBefore = gasleft();
        bytes32[] memory first = bundles.components(bundleId, 0, 1);
        uint256 pageGas = gasBefore - gasleft();
        bytes32[] memory second = bundles.components(bundleId, 1, 10);
        bytes32[] memory pastEnd = bundles.components(bundleId, 2, 1);
""",
    "bundle page gas measurement",
)
bundle_test = replace_once(
    bundle_test,
    """        require(first.length == 1 && first[0] == SUBSCRIPTION_A, "first page");
        require(second.length == 1 && second[0] == SUBSCRIPTION_B, "second page");
        require(pastEnd.length == 0, "past-end page");
""",
    """        require(first.length == 1 && first[0] == SUBSCRIPTION_A, "first page");
        require(second.length == 1 && second[0] == SUBSCRIPTION_B, "second page");
        require(pastEnd.length == 0, "past-end page");
        require(pageGas < 150_000, "bundle page gas");
""",
    "bundle page gas assertion",
)
bundle_test = replace_once(
    bundle_test,
    """    function testRejectsUnknownSubscriptionAndInvalidManifestOrVersion() public {
""",
    """    function testBundleCannotMutateMembershipSubscriptionOrRailAuthority() public {
        BossBundles bundles = new BossBundles();
        MockBundleAccount account = new MockBundleAccount(address(this));
        account.setSubscription(SUBSCRIPTION_A, RESOURCE, 77);
        bytes32[] memory one = new bytes32[](1);
        one[0] = SUBSCRIPTION_A;
        bytes32 bundleId = bundles.createBundle(address(account), MANIFEST, 1, one);

        (bool removeSuccess,) =
            address(bundles).call(abi.encodeWithSignature("removeComponent(bytes32,uint256)", bundleId, 0));
        (bool executeSuccess,) =
            address(bundles).call(abi.encodeWithSignature("execute(bytes32,bytes)", bundleId, bytes("")));
        (bool terminateSuccess,) =
            address(bundles).call(abi.encodeWithSignature("terminate(bytes32)", SUBSCRIPTION_A));
        require(!removeSuccess && !executeSuccess && !terminateSuccess, "bundle gained authority");

        BossTypes.Subscription memory subscription = account.getSubscription(SUBSCRIPTION_A);
        require(subscription.resourceKey == RESOURCE, "bundle changed resource");
        require(subscription.railId == 77, "bundle changed rail");
        require(subscription.state == BossTypes.SubscriptionState.ACTIVE, "bundle changed lifecycle");
        require(bundles.componentAt(bundleId, 0) == SUBSCRIPTION_A, "bundle membership mutated");
    }

    function testRejectsUnknownSubscriptionAndInvalidManifestOrVersion() public {
""",
    "bundle authority test",
)
bundle_test_path.write_text(bundle_test)


# --- State-view batch-gas guardrail. ---
state_test_path = Path("test/unit/BossStateView.t.sol")
state_test = state_test_path.read_text()
state_test = replace_once(
    state_test,
    """        BossStateView.SubscriptionSnapshot[] memory snapshots = stateView.subscriptions(address(account), ids);
        require(snapshots.length == 2, "batch length");
""",
    """        uint256 gasBefore = gasleft();
        BossStateView.SubscriptionSnapshot[] memory snapshots = stateView.subscriptions(address(account), ids);
        uint256 batchGas = gasBefore - gasleft();
        require(snapshots.length == 2, "batch length");
""",
    "state batch gas measurement",
)
state_test = replace_once(
    state_test,
    """        require(!snapshots[1].exists, "missing existing");
        require(snapshots[0].remainingLifetimeGross == type(uint256).max, "unlimited cap");
""",
    """        require(!snapshots[1].exists, "missing existing");
        require(snapshots[0].remainingLifetimeGross == type(uint256).max, "unlimited cap");
        require(batchGas < 750_000, "state batch gas");
""",
    "state batch gas assertion",
)
state_test_path.write_text(state_test)


# --- Deterministic generation must replace, not merely overwrite, generated outputs. ---
generator_path = Path("scripts/generate-contract-artifacts.sh")
generator = generator_path.read_text()
generator = replace_once(
    generator,
    """ABI_DIR=packages/contracts/abi
BYTECODE_DIR=packages/contracts/bytecode
mkdir -p "$ABI_DIR" "$BYTECODE_DIR"
""",
    """ABI_DIR=packages/contracts/abi
BYTECODE_DIR=packages/contracts/bytecode
rm -rf "$ABI_DIR" "$BYTECODE_DIR"
mkdir -p "$ABI_DIR" "$BYTECODE_DIR"
""",
    "artifact directory replacement",
)
generator_path.write_text(generator)

workflow_path = Path(".github/workflows/contract-artifacts.yml")
workflow = workflow_path.read_text()
workflow = replace_once(
    workflow,
    """      - name: Regenerate contract artifacts
        run: scripts/generate-contract-artifacts.sh

      - name: Reject artifact drift
""",
    """      - name: Regenerate contract artifacts
        shell: bash
        run: |
          set -euo pipefail
          mkdir -p packages/contracts/abi packages/contracts/bytecode
          printf 'stale\\n' > packages/contracts/abi/Stale.json
          printf 'stale\\n' > packages/contracts/bytecode/Stale.hex
          scripts/generate-contract-artifacts.sh
          test ! -e packages/contracts/abi/Stale.json
          test ! -e packages/contracts/bytecode/Stale.hex
          test "$(find packages/contracts/abi -maxdepth 1 -type f -name '*.json' | wc -l)" -eq 10
          test "$(find packages/contracts/bytecode -maxdepth 1 -type f -name '*.hex' | wc -l)" -eq 1

      - name: Reject artifact drift
""",
    "artifact stale-file test",
)
workflow_path.write_text(workflow)


# --- Canonical flat/capacity/metered event + bounded-view compatibility fixture. ---
Path("test/integration/A8LifecycleReconstruction.t.sol").write_text('// SPDX-License-Identifier: MIT\npragma solidity ^0.8.30;\n\nimport {BossStateView} from "../../src/BossStateView.sol";\nimport {IFilecoinPayV1} from "../../src/interfaces/IFilecoinPayV1.sol";\nimport {BossHashes} from "../../src/libraries/BossHashes.sol";\nimport {BossTypes} from "../../src/libraries/BossTypes.sol";\n\ninterface VmA8LifecycleLogs {\n    struct Log {\n        bytes32[] topics;\n        bytes data;\n        address emitter;\n    }\n\n    function recordLogs() external;\n    function getRecordedLogs() external returns (Log[] memory logs);\n}\n\ncontract A8LifecyclePay {\n    mapping(uint256 railId => IFilecoinPayV1.RailView rail) private _rails;\n\n    function setRail(uint256 railId, IFilecoinPayV1.RailView memory rail) external {\n        _rails[railId] = rail;\n    }\n\n    function getRail(uint256 railId) external view returns (IFilecoinPayV1.RailView memory rail) {\n        return _rails[railId];\n    }\n}\n\ncontract A8LifecycleAccount {\n    address public owner;\n    address public payer;\n    address public filecoinPay;\n    address public serviceRegistry = address(0x5100);\n    address public adapterRegistry = address(0xADA7);\n    address public factory = address(0xFAC7);\n    uint64 public accountVersion = 1;\n\n    mapping(bytes32 subscriptionId => BossTypes.Subscription subscription) private _subscriptions;\n    mapping(uint256 railId => bytes32 subscriptionId) private _subscriptionsByRail;\n    mapping(bytes32 subscriptionId => bool acknowledged) private _acknowledged;\n    mapping(bytes32 subscriptionId => mapping(bytes32 claimId => bool consumed)) private _claimConsumed;\n    mapping(bytes32 subscriptionId => mapping(uint256 nonce => bool consumed)) private _nonceConsumed;\n    mapping(bytes32 subscriptionId => mapping(uint256 window => uint256 gross)) private _windowGross;\n\n    event SubscriptionAccepted(\n        bytes32 indexed subscriptionId,\n        address indexed account,\n        bytes32 indexed offerHash,\n        bytes32 resourceKey,\n        uint256 railId,\n        address beneficiary,\n        address token,\n        uint256 initialRate,\n        uint256 initialFixedBudget\n    );\n    event SubscriptionActivated(bytes32 indexed subscriptionId, uint64 activatedEpoch);\n    event RateSynchronized(\n        bytes32 indexed subscriptionId,\n        uint256 oldRate,\n        uint256 newRate,\n        uint64 quoteEpoch,\n        uint64 validThroughEpoch,\n        bytes32 resourceStatusHash\n    );\n    event SubscriptionPaused(bytes32 indexed subscriptionId, uint64 pausedEpoch);\n    event SubscriptionResumed(bytes32 indexed subscriptionId, uint64 resumedEpoch);\n    event SubscriptionTerminationRequested(bytes32 indexed subscriptionId, uint64 requestEpoch);\n    event SubscriptionPayTerminationObserved(bytes32 indexed subscriptionId, uint256 indexed railId, uint256 endEpoch);\n    event SubscriptionEnded(bytes32 indexed subscriptionId, uint64 endedEpoch);\n    event UsageClaimCharged(\n        bytes32 indexed subscriptionId,\n        bytes32 indexed claimId,\n        uint64 fromEpoch,\n        uint64 toEpoch,\n        uint256 units,\n        uint256 rawGross,\n        uint256 chargedGross,\n        bytes32 evidenceHash,\n        uint256 nonce\n    );\n\n    constructor(address owner_, address pay_) {\n        owner = owner_;\n        payer = owner_;\n        filecoinPay = pay_;\n    }\n\n    function setSubscription(bytes32 subscriptionId, BossTypes.Subscription memory subscription, bool acknowledged)\n        external\n    {\n        _subscriptions[subscriptionId] = subscription;\n        _subscriptionsByRail[subscription.railId] = subscriptionId;\n        _acknowledged[subscriptionId] = acknowledged;\n    }\n\n    function setUsageClaimState(\n        bytes32 subscriptionId,\n        bytes32 claimId,\n        uint256 nonce,\n        uint256 window,\n        uint256 gross\n    ) external {\n        _claimConsumed[subscriptionId][claimId] = true;\n        _nonceConsumed[subscriptionId][nonce] = true;\n        _windowGross[subscriptionId][window] = gross;\n    }\n\n    function getSubscription(bytes32 subscriptionId)\n        external\n        view\n        returns (BossTypes.Subscription memory subscription)\n    {\n        return _subscriptions[subscriptionId];\n    }\n\n    function subscriptionForRail(uint256 railId) external view returns (bytes32) {\n        return _subscriptionsByRail[railId];\n    }\n\n    function activationAcknowledged(bytes32 subscriptionId) external view returns (bool) {\n        return _acknowledged[subscriptionId];\n    }\n\n    function usageClaimState(bytes32 subscriptionId, bytes32 claimId, uint256 nonce, uint256 window)\n        external\n        view\n        returns (bool claimConsumed, bool nonceConsumed, uint256 windowGross)\n    {\n        return (\n            _claimConsumed[subscriptionId][claimId],\n            _nonceConsumed[subscriptionId][nonce],\n            _windowGross[subscriptionId][window]\n        );\n    }\n\n    function emitFlatLifecycle(bytes32 subscriptionId) external {\n        BossTypes.Subscription memory subscription = _subscriptions[subscriptionId];\n        emit SubscriptionAccepted(\n            subscriptionId,\n            address(this),\n            subscription.offerHash,\n            subscription.resourceKey,\n            subscription.railId,\n            subscription.beneficiary,\n            subscription.token,\n            10,\n            0\n        );\n        emit SubscriptionActivated(subscriptionId, 100);\n        emit SubscriptionPaused(subscriptionId, 110);\n        emit SubscriptionResumed(subscriptionId, 115);\n        emit SubscriptionTerminationRequested(subscriptionId, 120);\n        emit SubscriptionPayTerminationObserved(subscriptionId, subscription.railId, 130);\n        emit SubscriptionEnded(subscriptionId, 130);\n    }\n\n    function emitCapacityLifecycle(bytes32 subscriptionId, bytes32 statusHash) external {\n        BossTypes.Subscription memory subscription = _subscriptions[subscriptionId];\n        emit SubscriptionAccepted(\n            subscriptionId,\n            address(this),\n            subscription.offerHash,\n            subscription.resourceKey,\n            subscription.railId,\n            subscription.beneficiary,\n            subscription.token,\n            10,\n            0\n        );\n        emit SubscriptionActivated(subscriptionId, 100);\n        emit RateSynchronized(subscriptionId, 10, 20, 120, 150, statusHash);\n    }\n\n    function emitMeteredLifecycle(bytes32 subscriptionId, BossTypes.UsageClaim memory usageClaim) external {\n        BossTypes.Subscription memory subscription = _subscriptions[subscriptionId];\n        emit SubscriptionAccepted(\n            subscriptionId,\n            address(this),\n            subscription.offerHash,\n            subscription.resourceKey,\n            subscription.railId,\n            subscription.beneficiary,\n            subscription.token,\n            0,\n            10 ether\n        );\n        emit SubscriptionActivated(subscriptionId, 100);\n        emit UsageClaimCharged(\n            subscriptionId,\n            usageClaim.claimId,\n            usageClaim.fromEpoch,\n            usageClaim.toEpoch,\n            usageClaim.units,\n            7 ether,\n            5 ether,\n            usageClaim.evidenceHash,\n            usageClaim.nonce\n        );\n    }\n}\n\ncontract A8LifecycleReconstructionTest {\n    VmA8LifecycleLogs private constant VM =\n        VmA8LifecycleLogs(address(uint160(uint256(keccak256("hevm cheat code")))));\n\n    bytes32 private constant FLAT_ID = keccak256("a8-flat");\n    bytes32 private constant CAPACITY_ID = keccak256("a8-capacity");\n    bytes32 private constant METERED_ID = keccak256("a8-metered");\n    bytes32 private constant CLAIM_ID = keccak256("a8-claim");\n    bytes32 private constant EVIDENCE_HASH = keccak256("a8-evidence");\n    bytes32 private constant STATUS_HASH = keccak256("a8-capacity-status");\n    address private constant BENEFICIARY = address(0xBEEF);\n    address private constant TOKEN = address(0x1003);\n    address private constant REPORTER = address(0xCAFE);\n\n    function testReconstructsFlatCapacityAndMeteredLifecycleFromEventsAndViews() public {\n        A8LifecyclePay pay = new A8LifecyclePay();\n        A8LifecycleAccount account = new A8LifecycleAccount(address(this), address(pay));\n        BossStateView stateView = new BossStateView();\n\n        BossTypes.Subscription memory flat;\n        flat.offerHash = keccak256("flat-offer");\n        flat.resourceKey = keccak256("flat-resource");\n        flat.beneficiary = BENEFICIARY;\n        flat.token = TOKEN;\n        flat.railId = 1;\n        flat.billingKind = BossTypes.BillingKind.STREAM_FLAT;\n        flat.caps.lifetimeCapGross = 1_000;\n        flat.acceptedRatePerEpoch = 10;\n        flat.settledGross = 200;\n        flat.acceptedEpoch = 100;\n        flat.activatedEpoch = 100;\n        flat.pausedEpoch = 110;\n        flat.terminationRequestedEpoch = 120;\n        flat.payEndEpoch = 130;\n        flat.state = BossTypes.SubscriptionState.ENDED;\n\n        BossTypes.Subscription memory capacity;\n        capacity.offerHash = keccak256("capacity-offer");\n        capacity.resourceKey = keccak256("capacity-resource");\n        capacity.beneficiary = BENEFICIARY;\n        capacity.token = TOKEN;\n        capacity.railId = 2;\n        capacity.billingKind = BossTypes.BillingKind.STREAM_CAPACITY;\n        capacity.caps.lifetimeCapGross = type(uint256).max;\n        capacity.acceptedRatePerEpoch = 20;\n        capacity.settledGross = 100;\n        capacity.acceptedEpoch = 100;\n        capacity.activatedEpoch = 100;\n        capacity.quoteValidThroughEpoch = 150;\n        capacity.quoteTtlEpochs = 30;\n        capacity.state = BossTypes.SubscriptionState.ACTIVE;\n\n        BossTypes.Subscription memory metered;\n        metered.offerHash = keccak256("metered-offer");\n        metered.resourceKey = keccak256("metered-resource");\n        metered.beneficiary = BENEFICIARY;\n        metered.reporter = REPORTER;\n        metered.token = TOKEN;\n        metered.railId = 3;\n        metered.billingKind = BossTypes.BillingKind.METERED_FIXED_LOCKUP;\n        metered.caps.maxFixedLockup = 10 ether;\n        metered.caps.maxSingleCharge = 5 ether;\n        metered.caps.maxChargePerWindow = 10 ether;\n        metered.caps.lifetimeCapGross = 10 ether;\n        metered.caps.chargeWindowEpochs = 100;\n        metered.oneTimeChargedGross = 5 ether;\n        metered.currentFixedBudget = 5 ether;\n        metered.acceptedEpoch = 100;\n        metered.activatedEpoch = 100;\n        metered.lastUsageToEpoch = 110;\n        metered.state = BossTypes.SubscriptionState.EXHAUSTED;\n\n        account.setSubscription(FLAT_ID, flat, true);\n        account.setSubscription(CAPACITY_ID, capacity, true);\n        account.setSubscription(METERED_ID, metered, true);\n\n        pay.setRail(flat.railId, _rail(address(account), flat, 0, 130));\n        pay.setRail(capacity.railId, _rail(address(account), capacity, 20, 0));\n        pay.setRail(metered.railId, _rail(address(account), metered, 0, 0));\n\n        BossTypes.UsageClaim memory usageClaim = BossTypes.UsageClaim({\n            claimId: CLAIM_ID,\n            fromEpoch: 100,\n            toEpoch: 110,\n            units: 1 << 40,\n            evidenceHash: EVIDENCE_HASH,\n            evidenceURI: "ipfs://a8-evidence",\n            nonce: 9\n        });\n        account.setUsageClaimState(METERED_ID, CLAIM_ID, usageClaim.nonce, 0, 5 ether);\n\n        VM.recordLogs();\n        account.emitFlatLifecycle(FLAT_ID);\n        account.emitCapacityLifecycle(CAPACITY_ID, STATUS_HASH);\n        account.emitMeteredLifecycle(METERED_ID, usageClaim);\n        VmA8LifecycleLogs.Log[] memory logs = VM.getRecordedLogs();\n\n        bytes32 acceptedSignature =\n            keccak256("SubscriptionAccepted(bytes32,address,bytes32,bytes32,uint256,address,address,uint256,uint256)");\n        bytes32 activatedSignature = keccak256("SubscriptionActivated(bytes32,uint64)");\n        bytes32 rateSignature =\n            keccak256("RateSynchronized(bytes32,uint256,uint256,uint64,uint64,bytes32)");\n        bytes32 pausedSignature = keccak256("SubscriptionPaused(bytes32,uint64)");\n        bytes32 resumedSignature = keccak256("SubscriptionResumed(bytes32,uint64)");\n        bytes32 terminationSignature = keccak256("SubscriptionTerminationRequested(bytes32,uint64)");\n        bytes32 payTerminationSignature =\n            keccak256("SubscriptionPayTerminationObserved(bytes32,uint256,uint256)");\n        bytes32 endedSignature = keccak256("SubscriptionEnded(bytes32,uint64)");\n        bytes32 usageSignature =\n            keccak256("UsageClaimCharged(bytes32,bytes32,uint64,uint64,uint256,uint256,uint256,bytes32,uint256)");\n\n        uint256 acceptedSeen;\n        bool flatActivated;\n        bool flatPaused;\n        bool flatResumed;\n        bool flatTerminationRequested;\n        bool flatPayTerminationObserved;\n        bool flatEnded;\n        bool capacityActivated;\n        bool capacityRateObserved;\n        bool meteredActivated;\n        bool meteredClaimObserved;\n\n        for (uint256 i; i < logs.length; ++i) {\n            if (logs[i].emitter != address(account) || logs[i].topics.length == 0) continue;\n            bytes32 signature = logs[i].topics[0];\n            bytes32 subscriptionId = logs[i].topics.length > 1 ? logs[i].topics[1] : bytes32(0);\n\n            if (signature == acceptedSignature) {\n                require(logs[i].topics.length == 4, "accepted topics");\n                require(\n                    address(uint160(uint256(logs[i].topics[2]))) == address(account), "accepted account"\n                );\n                BossTypes.Subscription memory recorded = account.getSubscription(subscriptionId);\n                require(logs[i].topics[3] == recorded.offerHash, "accepted offer");\n                (\n                    bytes32 resourceKey,\n                    uint256 railId,\n                    address beneficiary,\n                    address token,\n                    uint256 initialRate,\n                    uint256 initialFixedBudget\n                ) = abi.decode(logs[i].data, (bytes32, uint256, address, address, uint256, uint256));\n                require(resourceKey == recorded.resourceKey, "accepted resource");\n                require(railId == recorded.railId, "accepted rail");\n                require(beneficiary == recorded.beneficiary && token == recorded.token, "accepted recipients");\n                if (subscriptionId == FLAT_ID) {\n                    require(initialRate == 10 && initialFixedBudget == 0, "flat accepted terms");\n                } else if (subscriptionId == CAPACITY_ID) {\n                    require(initialRate == 10 && initialFixedBudget == 0, "capacity accepted terms");\n                } else if (subscriptionId == METERED_ID) {\n                    require(initialRate == 0 && initialFixedBudget == 10 ether, "metered accepted terms");\n                } else {\n                    revert("unknown accepted subscription");\n                }\n                ++acceptedSeen;\n            } else if (signature == activatedSignature) {\n                if (subscriptionId == FLAT_ID) flatActivated = true;\n                else if (subscriptionId == CAPACITY_ID) capacityActivated = true;\n                else if (subscriptionId == METERED_ID) meteredActivated = true;\n            } else if (signature == rateSignature) {\n                require(subscriptionId == CAPACITY_ID, "rate subscription");\n                (uint256 oldRate, uint256 newRate, uint64 quoteEpoch, uint64 validThrough, bytes32 statusHash) =\n                    abi.decode(logs[i].data, (uint256, uint256, uint64, uint64, bytes32));\n                require(oldRate == 10 && newRate == 20, "rate values");\n                require(quoteEpoch == 120 && validThrough == 150, "rate epochs");\n                require(statusHash == STATUS_HASH, "rate status");\n                capacityRateObserved = true;\n            } else if (signature == pausedSignature) {\n                require(subscriptionId == FLAT_ID, "pause subscription");\n                flatPaused = true;\n            } else if (signature == resumedSignature) {\n                require(subscriptionId == FLAT_ID, "resume subscription");\n                flatResumed = true;\n            } else if (signature == terminationSignature) {\n                require(subscriptionId == FLAT_ID, "termination subscription");\n                flatTerminationRequested = true;\n            } else if (signature == payTerminationSignature) {\n                require(subscriptionId == FLAT_ID, "pay termination subscription");\n                require(uint256(logs[i].topics[2]) == flat.railId, "pay termination rail");\n                require(abi.decode(logs[i].data, (uint256)) == 130, "pay termination epoch");\n                flatPayTerminationObserved = true;\n            } else if (signature == endedSignature) {\n                require(subscriptionId == FLAT_ID, "ended subscription");\n                require(abi.decode(logs[i].data, (uint64)) == 130, "ended epoch");\n                flatEnded = true;\n            } else if (signature == usageSignature) {\n                require(subscriptionId == METERED_ID, "usage subscription");\n                require(logs[i].topics[2] == CLAIM_ID, "usage claim id");\n                (\n                    uint64 fromEpoch,\n                    uint64 toEpoch,\n                    uint256 units,\n                    uint256 rawGross,\n                    uint256 chargedGross,\n                    bytes32 evidenceHash,\n                    uint256 nonce\n                ) = abi.decode(logs[i].data, (uint64, uint64, uint256, uint256, uint256, bytes32, uint256));\n                require(fromEpoch == usageClaim.fromEpoch && toEpoch == usageClaim.toEpoch, "usage epochs");\n                require(units == usageClaim.units, "usage units");\n                require(rawGross == 7 ether && chargedGross == 5 ether, "usage gross");\n                require(evidenceHash == usageClaim.evidenceHash && nonce == usageClaim.nonce, "usage provenance");\n                meteredClaimObserved = true;\n            }\n        }\n\n        require(acceptedSeen == 3, "accepted count");\n        require(flatActivated && flatPaused && flatResumed, "flat lifecycle");\n        require(flatTerminationRequested && flatPayTerminationObserved && flatEnded, "flat termination");\n        require(capacityActivated && capacityRateObserved, "capacity lifecycle");\n        require(meteredActivated && meteredClaimObserved, "metered lifecycle");\n\n        bytes32[] memory subscriptionIds = new bytes32[](3);\n        subscriptionIds[0] = FLAT_ID;\n        subscriptionIds[1] = CAPACITY_ID;\n        subscriptionIds[2] = METERED_ID;\n        BossStateView.SubscriptionSnapshot[] memory snapshots =\n            stateView.subscriptions(address(account), subscriptionIds);\n\n        require(snapshots[0].exists && snapshots[0].railAssociationValid, "flat view");\n        require(snapshots[0].subscription.state == BossTypes.SubscriptionState.ENDED, "flat ended view");\n        require(snapshots[0].subscription.payEndEpoch == 130, "flat termination view");\n        require(snapshots[1].exists && snapshots[1].railAssociationValid, "capacity view");\n        require(snapshots[1].subscription.acceptedRatePerEpoch == 20, "capacity rate view");\n        require(snapshots[1].subscription.quoteValidThroughEpoch == 150, "capacity quote view");\n        require(snapshots[2].exists && snapshots[2].railAssociationValid, "metered view");\n        require(snapshots[2].grossSpent == 5 ether, "metered gross view");\n        require(snapshots[2].remainingLifetimeGross == 5 ether, "metered lifetime view");\n\n        BossStateView.ClaimSnapshot memory claimSnapshot =\n            stateView.claim(address(account), METERED_ID, usageClaim);\n        require(claimSnapshot.subscriptionExists && claimSnapshot.windowValid, "claim view existence");\n        require(claimSnapshot.claimHash == BossHashes.hashUsageClaim(METERED_ID, usageClaim), "claim hash");\n        require(\n            claimSnapshot.digest\n                == BossHashes.hashTypedData(\n                    BossHashes.domainSeparator(block.chainid, address(account)), claimSnapshot.claimHash\n                ),\n            "claim digest"\n        );\n        require(claimSnapshot.reporter == REPORTER, "claim reporter");\n        require(claimSnapshot.claimConsumed && claimSnapshot.nonceConsumed, "claim consumption");\n        require(claimSnapshot.window == 0 && claimSnapshot.windowGross == 5 ether, "claim window");\n        require(claimSnapshot.remainingWindowGross == 5 ether, "window remaining");\n        require(claimSnapshot.remainingLifetimeGross == 5 ether, "lifetime remaining");\n    }\n\n    function _rail(\n        address account,\n        BossTypes.Subscription memory subscription,\n        uint256 rate,\n        uint256 endEpoch\n    ) private view returns (IFilecoinPayV1.RailView memory rail) {\n        rail = IFilecoinPayV1.RailView({\n            token: subscription.token,\n            from: address(this),\n            to: subscription.beneficiary,\n            operator: account,\n            validator: account,\n            paymentRate: rate,\n            lockupPeriod: 0,\n            lockupFixed: subscription.currentFixedBudget,\n            settledUpTo: subscription.acceptedEpoch,\n            endEpoch: endEpoch,\n            commissionRateBps: 0,\n            serviceFeeRecipient: address(0)\n        });\n    }\n}\n')
