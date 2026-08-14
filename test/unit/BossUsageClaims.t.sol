// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossAccount} from "../../src/BossAccount.sol";
import {BossBundles} from "../../src/BossBundles.sol";
import {BossAdapterRegistry} from "../../src/BossAdapterRegistry.sol";
import {BossServiceRegistry} from "../../src/BossServiceRegistry.sol";
import {CappedMeteredAdapter} from "../../src/adapters/pricing/CappedMeteredAdapter.sol";
import {IBossResourceAdapter} from "../../src/interfaces/IBossResourceAdapter.sol";
import {IFilecoinPayV1, IFilecoinPayValidator} from "../../src/interfaces/IFilecoinPayV1.sol";
import {BossHashes} from "../../src/libraries/BossHashes.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";

interface VmUsageClaims {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function addr(uint256 privateKey) external returns (address keyAddr);
    function prank(address sender) external;
    function roll(uint256 newHeight) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function etch(address target, bytes calldata newRuntimeBytecode) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}

contract MeteredResourceAdapter is IBossResourceAdapter {
    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function inspect(BossTypes.ResourceRef calldata resource, address expectedPayer, bytes calldata resourceData)
        external
        pure
        returns (BossTypes.ResourceStatus memory status)
    {
        return BossTypes.ResourceStatus({
            resourceKey: BossHashes.hashResource(resource),
            exists: true,
            attachable: true,
            billable: true,
            payer: expectedPayer,
            storageProvider: address(0xB0B),
            sizeInBytes: 1,
            statusHash: keccak256(resourceData)
        });
    }
}

contract MockMeteredFilecoinPayV1 is IFilecoinPayV1 {
    mapping(uint256 railId => RailView rail) private _rails;
    mapping(address token => mapping(address client => mapping(address operator => bool approved))) private _approved;
    mapping(uint256 railId => uint256 gross) public oneTimeGross;

    uint256 private _nextRailId = 1;

    function nextRailId() external view returns (uint256) {
        return _nextRailId;
    }

    function setOperatorApproval(address token, address client, address operator, bool approved) external {
        require(msg.sender == client, "only client");
        _approved[token][client][operator] = approved;
    }

    function createRail(
        address token,
        address from,
        address to,
        address validator,
        uint256 commissionRateBps,
        address serviceFeeRecipient
    ) external returns (uint256 railId) {
        require(_approved[token][from][msg.sender], "operator not approved");
        railId = _nextRailId++;
        _rails[railId] = RailView({
            token: token,
            from: from,
            to: to,
            operator: msg.sender,
            validator: validator,
            paymentRate: 0,
            lockupPeriod: 0,
            lockupFixed: 0,
            settledUpTo: block.number,
            endEpoch: 0,
            commissionRateBps: commissionRateBps,
            serviceFeeRecipient: serviceFeeRecipient
        });
    }

    function modifyRailLockup(uint256 railId, uint256 period, uint256 lockupFixed) external {
        RailView storage rail = _rails[railId];
        require(msg.sender == rail.operator, "only operator");
        rail.lockupPeriod = period;
        rail.lockupFixed = lockupFixed;
    }

    function modifyRailPayment(uint256 railId, uint256 newRate, uint256 oneTimePayment) external {
        RailView storage rail = _rails[railId];
        require(msg.sender == rail.operator, "only operator");
        require(oneTimePayment <= rail.lockupFixed, "one-time exceeds lockup");
        rail.paymentRate = newRate;
        rail.lockupFixed -= oneTimePayment;
        oneTimeGross[railId] += oneTimePayment;
    }

    function settleRail(uint256 railId, uint256 untilEpoch)
        external
        returns (
            uint256 totalSettledAmount,
            uint256 totalNetPayeeAmount,
            uint256 totalOperatorCommission,
            uint256 totalNetworkFee,
            uint256 finalSettledEpoch,
            string memory note
        )
    {
        RailView storage rail = _rails[railId];
        uint256 target = untilEpoch;
        if (rail.endEpoch != 0 && target > rail.endEpoch) target = rail.endEpoch;
        uint256 gross = (target - rail.settledUpTo) * rail.paymentRate;
        if (rail.validator != address(0)) {
            IFilecoinPayValidator.ValidationResult memory result = IFilecoinPayValidator(rail.validator).validatePayment(
                railId, gross, rail.settledUpTo, target, rail.paymentRate
            );
            gross = result.modifiedAmount;
            target = result.settleUpto;
            note = result.note;
        }
        rail.settledUpTo = target;
        return (gross, gross, 0, 0, target, note);
    }

    function terminateRail(uint256 railId) external {
        RailView storage rail = _rails[railId];
        require(msg.sender == rail.from || msg.sender == rail.operator, "not terminator");
        rail.endEpoch = block.number + rail.lockupPeriod;
        if (rail.validator != address(0)) {
            IFilecoinPayValidator(rail.validator).railTerminated(railId, msg.sender, rail.endEpoch);
        }
    }

    function getRail(uint256 railId) external view returns (RailView memory rail) {
        return _rails[railId];
    }

    function getAccountInfoIfSettled(address, address)
        external
        pure
        returns (uint256 fundedUntilEpoch, uint256 currentFunds, uint256 availableFunds, uint256 currentLockupRate)
    {
        return (type(uint256).max, 0, 0, 0);
    }

    function operatorApprovals(address token, address client, address operator)
        external
        view
        returns (
            bool isApproved,
            uint256 rateAllowance,
            uint256 lockupAllowance,
            uint256 rateUsage,
            uint256 lockupUsage,
            uint256 maxLockupPeriod
        )
    {
        return (_approved[token][client][operator], 0, type(uint256).max, 0, 0, type(uint256).max);
    }
}

contract BossUsageClaimsTest {
    VmUsageClaims private constant vm = VmUsageClaims(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant TIB = 1 << 40;
    uint256 private constant PROVIDER_KEY = 0xA11CE;
    uint256 private constant REPORTER_KEY = 0xC0FFEE;
    address private constant PROVIDER = address(0xB0B);
    address private constant BENEFICIARY = address(0xBEEF);
    bytes32 private constant SERVICE_ID = keccak256("capped-egress");
    bytes32 private constant SERVICE_TYPE = keccak256("capped-egress");
    bytes32 private constant BUNDLE_MANIFEST = keccak256("metered-bundle-manifest");

    MockMeteredFilecoinPayV1 private pay;
    BossServiceRegistry private serviceRegistry;
    BossAdapterRegistry private adapterRegistry;
    MeteredResourceAdapter private resourceAdapter;
    CappedMeteredAdapter private pricingAdapter;
    BossAccount private account;
    BossBundles private bundles;
    address private providerSigningKey;
    address private reporter;

    function setUp() public {
        vm.roll(100);
        pay = new MockMeteredFilecoinPayV1();
        serviceRegistry = new BossServiceRegistry();
        adapterRegistry = new BossAdapterRegistry(address(this));
        resourceAdapter = new MeteredResourceAdapter();
        pricingAdapter = new CappedMeteredAdapter();
        providerSigningKey = vm.addr(PROVIDER_KEY);
        reporter = vm.addr(REPORTER_KEY);

        vm.prank(PROVIDER);
        serviceRegistry.registerProvider("ipfs://provider", providerSigningKey);
        vm.prank(PROVIDER);
        serviceRegistry.publishService(SERVICE_ID, SERVICE_TYPE, "ipfs://service");

        adapterRegistry.registerAdapter(
            address(resourceAdapter), BossTypes.AdapterKind.RESOURCE, 1, "ipfs://metered-resource"
        );
        adapterRegistry.registerAdapter(
            address(pricingAdapter), BossTypes.AdapterKind.PRICING, 1, "ipfs://metered-pricing"
        );

        account = new BossAccount(address(this), address(pay), address(serviceRegistry), address(adapterRegistry), 1);
        bundles = new BossBundles();
        pay.setOperatorApproval(address(0), address(this), address(account), true);
    }

    function testClaimsAreBoundedBySingleWindowLifetimeAndBudgetCaps() public {
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(_input(10 ether, 9 ether, 5 ether, 2 ether, 1));
        vm.roll(250);

        uint256 charged1 = account.submitUsageClaim(
            subscriptionId, _claim(1, 100, 110, TIB), _signClaim(subscriptionId, _claim(1, 100, 110, TIB))
        );
        uint256 charged2 = account.submitUsageClaim(
            subscriptionId, _claim(2, 110, 120, TIB), _signClaim(subscriptionId, _claim(2, 110, 120, TIB))
        );
        uint256 charged3 = account.submitUsageClaim(
            subscriptionId, _claim(3, 120, 130, TIB), _signClaim(subscriptionId, _claim(3, 120, 130, TIB))
        );
        uint256 charged4 = account.submitUsageClaim(
            subscriptionId, _claim(4, 130, 140, TIB), _signClaim(subscriptionId, _claim(4, 130, 140, TIB))
        );

        require(charged1 == 2 ether, "single cap first");
        require(charged2 == 2 ether, "single cap second");
        require(charged3 == 1 ether, "window remainder");
        require(charged4 == 0, "window exhausted");
        require(pay.oneTimeGross(railId) == 5 ether, "window gross");
        require(pay.getRail(railId).lockupFixed == 5 ether, "budget after window");

        BossTypes.UsageClaim memory next = _claim(5, 200, 210, TIB);
        require(
            account.submitUsageClaim(subscriptionId, next, _signClaim(subscriptionId, next)) == 2 ether, "next window"
        );
        next = _claim(6, 210, 220, TIB);
        require(
            account.submitUsageClaim(subscriptionId, next, _signClaim(subscriptionId, next)) == 2 ether,
            "lifetime remainder"
        );

        BossTypes.Subscription memory subscription = account.getSubscription(subscriptionId);
        require(subscription.oneTimeChargedGross == 9 ether, "lifetime charged");
        require(subscription.currentFixedBudget == 1 ether, "local budget");
        require(subscription.state == BossTypes.SubscriptionState.EXHAUSTED, "lifetime exhausted");
        require(pay.getRail(railId).lockupFixed == 1 ether, "Pay budget synchronized");
    }

    function testReplayOverlapWrongReporterFutureAndCrossWindowClaimsFailClosed() public {
        (bytes32 subscriptionId,) = account.acceptOffer(_input(10 ether, 20 ether, 10 ether, 5 ether, 2));
        vm.roll(250);
        BossTypes.UsageClaim memory claim = _claim(10, 100, 110, TIB / 10);
        bytes memory signature = _signClaim(subscriptionId, claim);
        account.submitUsageClaim(subscriptionId, claim, signature);

        _mustFailClaim(subscriptionId, claim, signature);

        BossTypes.UsageClaim memory sameNonce = _claim(11, 110, 120, TIB / 10);
        sameNonce.nonce = claim.nonce;
        _mustFailClaim(subscriptionId, sameNonce, _signClaim(subscriptionId, sameNonce));

        BossTypes.UsageClaim memory overlap = _claim(12, 109, 120, TIB / 10);
        _mustFailClaim(subscriptionId, overlap, _signClaim(subscriptionId, overlap));

        BossTypes.UsageClaim memory wrongReporter = _claim(13, 110, 120, TIB / 10);
        _mustFailClaim(subscriptionId, wrongReporter, _signWith(PROVIDER_KEY, subscriptionId, wrongReporter));

        BossTypes.UsageClaim memory future = _claim(14, 110, 1010, TIB / 10);
        _mustFailClaim(subscriptionId, future, _signClaim(subscriptionId, future));

        BossTypes.UsageClaim memory crossWindow = _claim(15, 190, 210, TIB / 10);
        _mustFailClaim(subscriptionId, crossWindow, _signClaim(subscriptionId, crossWindow));
    }

    function testClaimsCannotCoverPreActivationOrPriorPausedEpochs() public {
        BossTypes.AcceptanceInput memory input = _input(10 ether, 20 ether, 10 ether, 5 ether, 42);
        input.offer.activationKind = BossTypes.ActivationKind.PROVIDER_ACK;
        input.providerSignature = _signOffer(input.offer);
        (bytes32 subscriptionId,) = account.acceptOffer(input);

        vm.roll(120);
        bytes32 provisioningHash = keccak256("metered-provisioned");
        account.acknowledgeActivation(
            subscriptionId,
            provisioningHash,
            _sign(PROVIDER_KEY, account.activationAckDigest(subscriptionId, provisioningHash))
        );
        account.activate(subscriptionId);
        vm.roll(140);

        BossTypes.UsageClaim memory beforeActivation = _claim(42, 100, 110, TIB / 10);
        _mustFailClaim(subscriptionId, beforeActivation, _signClaim(subscriptionId, beforeActivation));

        BossTypes.UsageClaim memory active = _claim(43, 120, 130, TIB / 10);
        require(
            account.submitUsageClaim(subscriptionId, active, _signClaim(subscriptionId, active)) != 0,
            "active-period claim rejected"
        );

        account.pause(subscriptionId);
        vm.roll(160);
        account.resume(subscriptionId);
        vm.roll(180);

        BossTypes.UsageClaim memory priorPeriod = _claim(44, 130, 140, TIB / 10);
        _mustFailClaim(subscriptionId, priorPeriod, _signClaim(subscriptionId, priorPeriod));

        BossTypes.UsageClaim memory currentPeriod = _claim(45, 160, 170, TIB / 10);
        require(
            account.submitUsageClaim(subscriptionId, currentPeriod, _signClaim(subscriptionId, currentPeriod)) != 0,
            "current-period claim rejected"
        );
    }

    function testUnlimitedMeteredCapsFailClosed() public {
        BossTypes.AcceptanceInput memory input = _input(3 ether, 20 ether, 10 ether, 5 ether, 50);
        input.caps.maxFixedLockup = type(uint256).max;
        input.offer.providerMaxFixedLockup = type(uint256).max;
        input.providerSignature = _signOffer(input.offer);
        _mustFailAccept(input);

        input = _input(3 ether, 20 ether, 10 ether, 5 ether, 51);
        input.caps.maxSingleCharge = type(uint256).max;
        _mustFailAccept(input);

        input = _input(3 ether, 20 ether, 10 ether, 5 ether, 52);
        input.caps.maxChargePerWindow = type(uint256).max;
        _mustFailAccept(input);

        input = _input(3 ether, 20 ether, 10 ether, 5 ether, 53);
        input.caps.lifetimeCapGross = type(uint256).max;
        _mustFailAccept(input);
    }

    function testZeroByteClaimIsConsumedWithoutPayment() public {
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(_input(3 ether, 20 ether, 10 ether, 5 ether, 3));
        vm.roll(120);
        BossTypes.UsageClaim memory claim = _claim(20, 100, 110, 0);

        require(account.submitUsageClaim(subscriptionId, claim, _signClaim(subscriptionId, claim)) == 0, "zero charge");
        require(pay.oneTimeGross(railId) == 0, "no Pay payment");
        (bool claimConsumed, bool nonceConsumed, uint256 windowGross) =
            account.usageClaimState(subscriptionId, claim.claimId, claim.nonce, 0);
        require(claimConsumed, "claim consumption not readable");
        require(nonceConsumed, "nonce consumption not readable");
        require(windowGross == 0, "zero claim changed window gross");
        _mustFailClaim(subscriptionId, claim, _signClaim(subscriptionId, claim));
    }

    function testUsageClaimEventCarriesCompleteReconstructablePreimage() public {
        (bytes32 subscriptionId,) = account.acceptOffer(_input(3 ether, 20 ether, 10 ether, 5 ether, 31));
        vm.roll(120);
        BossTypes.UsageClaim memory claim = _claim(31, 100, 110, TIB / 10);

        vm.recordLogs();
        uint256 charged = account.submitUsageClaim(subscriptionId, claim, _signClaim(subscriptionId, claim));
        VmUsageClaims.Log[] memory logs = vm.getRecordedLogs();
        bytes32 signature = keccak256("UsageClaimCharged(bytes32,bytes32,bytes32,uint256,uint256,uint256,bytes32)");
        bool observed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(account) || logs[i].topics.length != 3 || logs[i].topics[0] != signature) {
                continue;
            }
            require(logs[i].topics[1] == subscriptionId, "event subscription");
            require(logs[i].topics[2] == claim.claimId, "event claim id");
            (bytes32 claimHash, uint256 units, uint256 rawGross, uint256 chargedGross, bytes32 evidenceHash) =
                abi.decode(logs[i].data, (bytes32, uint256, uint256, uint256, bytes32));
            require(claimHash == BossHashes.hashUsageClaim(subscriptionId, claim), "event claim hash");
            require(units == claim.units, "event units");
            require(rawGross == (claim.units * 7 ether) / TIB, "event raw gross");
            require(chargedGross == charged, "event charged gross");
            require(evidenceHash == claim.evidenceHash, "event evidence hash");
            observed = true;
        }
        require(observed, "usage event missing");
    }

    function testAcceptBundleAtomicallyCreatesComponentsAndKeepsLifecyclesIndependent() public {
        BossTypes.AcceptanceInput memory first = _input(3 ether, 20 ether, 10 ether, 5 ether, 60);
        BossTypes.AcceptanceInput memory second = _input(4 ether, 20 ether, 10 ether, 5 ether, 61);
        first.resource.resourceId = 777;
        second.resource.resourceId = 777;
        bytes[] memory encodedAcceptances = new bytes[](2);
        encodedAcceptances[0] = abi.encodeCall(BossAccount.acceptOffer, (first));
        encodedAcceptances[1] = abi.encodeCall(BossAccount.acceptOffer, (second));

        (bytes32 bundleId, bytes32[] memory subscriptionIds) =
            account.acceptBundle(address(bundles), BUNDLE_MANIFEST, 1, encodedAcceptances);
        require(subscriptionIds.length == 2 && subscriptionIds[0] != subscriptionIds[1], "bundle subscriptions");
        (BossTypes.Bundle memory bundle, address bundleAccount, uint256 componentCount) = bundles.getBundle(bundleId);
        require(bundle.owner == address(this), "bundle owner");
        require(bundleAccount == address(account), "bundle account");
        require(bundle.resourceKey == BossHashes.hashResource(first.resource), "bundle resource");
        require(componentCount == 2, "bundle component count");
        require(bundles.componentAt(bundleId, 0) == subscriptionIds[0], "first component");
        require(bundles.componentAt(bundleId, 1) == subscriptionIds[1], "second component");

        account.pause(subscriptionIds[0]);
        require(account.getSubscription(subscriptionIds[0]).state == BossTypes.SubscriptionState.PAUSED, "first paused");
        require(
            account.getSubscription(subscriptionIds[1]).state == BossTypes.SubscriptionState.ACTIVE, "second changed"
        );
    }

    function testAcceptBundleRollsBackEveryRailAndSubscriptionWhenOneComponentFails() public {
        BossTypes.AcceptanceInput memory first = _input(3 ether, 20 ether, 10 ether, 5 ether, 62);
        BossTypes.AcceptanceInput memory second = _input(4 ether, 20 ether, 10 ether, 5 ether, 63);
        first.resource.resourceId = 888;
        second.resource.resourceId = 888;
        second.caps.maxSingleCharge = 0;
        bytes[] memory encodedAcceptances = new bytes[](2);
        encodedAcceptances[0] = abi.encodeCall(BossAccount.acceptOffer, (first));
        encodedAcceptances[1] = abi.encodeCall(BossAccount.acceptOffer, (second));

        bytes32 firstId = _subscriptionId(first);
        bytes32 secondId = _subscriptionId(second);
        uint256 nextRailBefore = pay.nextRailId();
        (bool success,) = address(account).call(
            abi.encodeCall(BossAccount.acceptBundle, (address(bundles), BUNDLE_MANIFEST, 1, encodedAcceptances))
        );
        require(!success, "partial bundle accepted");
        require(pay.nextRailId() == nextRailBefore, "rail creation not rolled back");
        require(
            account.getSubscription(firstId).state == BossTypes.SubscriptionState.NONE, "first subscription persisted"
        );
        require(
            account.getSubscription(secondId).state == BossTypes.SubscriptionState.NONE, "second subscription persisted"
        );

        bytes32 bundleId = keccak256(
            abi.encode(
                "FILECOIN_BOSS_BUNDLE_V1",
                address(this),
                address(account),
                BossHashes.hashResource(first.resource),
                BUNDLE_MANIFEST,
                uint64(1)
            )
        );
        (bool bundleExists,) = address(bundles).call(abi.encodeCall(BossBundles.getBundle, (bundleId)));
        require(!bundleExists, "bundle record persisted");
    }

    function testAcceptBundleRejectsNonAcceptanceSelectorsAndInvalidBounds() public {
        bytes[] memory invalidSelector = new bytes[](1);
        invalidSelector[0] = abi.encodeCall(BossAccount.pause, (bytes32(0)));
        (bool selectorAccepted,) = address(account).call(
            abi.encodeCall(BossAccount.acceptBundle, (address(bundles), BUNDLE_MANIFEST, 1, invalidSelector))
        );
        require(!selectorAccepted, "non-acceptance selector executed");

        bytes[] memory empty = new bytes[](0);
        (bool emptyAccepted,) = address(account).call(
            abi.encodeCall(BossAccount.acceptBundle, (address(bundles), BUNDLE_MANIFEST, 1, empty))
        );
        require(!emptyAccepted, "empty bundle accepted");

        bytes[] memory oversized = new bytes[](bundles.MAX_COMPONENTS() + 1);
        (bool oversizedAccepted,) = address(account).call(
            abi.encodeCall(BossAccount.acceptBundle, (address(bundles), BUNDLE_MANIFEST, 1, oversized))
        );
        require(!oversizedAccepted, "oversized bundle accepted");
    }

    function testDisabledAcceptedPricingAdapterRemainsUsable() public {
        (bytes32 subscriptionId,) = account.acceptOffer(_input(3 ether, 20 ether, 10 ether, 5 ether, 40));
        adapterRegistry.setAdapterActive(address(pricingAdapter), false);
        vm.roll(120);
        BossTypes.UsageClaim memory claim = _claim(40, 100, 110, TIB / 10);
        require(
            account.submitUsageClaim(subscriptionId, claim, _signClaim(subscriptionId, claim)) != 0,
            "accepted adapter disabled retroactively"
        );
    }

    function testChangedPricingAdapterCodeFailsClosed() public {
        (bytes32 subscriptionId,) = account.acceptOffer(_input(3 ether, 20 ether, 10 ether, 5 ether, 41));
        vm.roll(120);
        BossTypes.UsageClaim memory claim = _claim(41, 100, 110, TIB / 10);
        bytes memory signature = _signClaim(subscriptionId, claim);
        vm.etch(address(pricingAdapter), hex"00");
        _mustFailClaim(subscriptionId, claim, signature);
    }

    function testOnlyOwnerCanTopUpAndTopUpCannotExceedAcceptedCap() public {
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(_input(3 ether, 20 ether, 10 ether, 5 ether, 4));
        vm.roll(120);
        BossTypes.UsageClaim memory claim = _claim(30, 100, 110, TIB);
        account.submitUsageClaim(subscriptionId, claim, _signClaim(subscriptionId, claim));
        require(pay.getRail(railId).lockupFixed == 0, "budget exhausted");
        require(account.getSubscription(subscriptionId).state == BossTypes.SubscriptionState.EXHAUSTED, "exhausted");

        vm.prank(reporter);
        (bool unauthorized,) =
            address(account).call(abi.encodeCall(BossAccount.topUpFixedBudget, (subscriptionId, 5 ether)));
        require(!unauthorized, "reporter top-up accepted");

        account.topUpFixedBudget(subscriptionId, 5 ether);
        require(pay.getRail(railId).lockupFixed == 5 ether, "Pay budget topped up");
        require(account.getSubscription(subscriptionId).currentFixedBudget == 5 ether, "local budget topped up");
        require(
            account.getSubscription(subscriptionId).state == BossTypes.SubscriptionState.ACTIVE, "service reactivated"
        );

        (bool aboveCap,) =
            address(account).call(abi.encodeCall(BossAccount.topUpFixedBudget, (subscriptionId, 11 ether)));
        require(!aboveCap, "above-cap top-up accepted");
    }

    function _input(uint256 initialBudget, uint256 lifetimeCap, uint256 windowCap, uint256 singleCap, uint256 nonce)
        private
        returns (BossTypes.AcceptanceInput memory input)
    {
        bytes memory pricingData = abi.encode(CappedMeteredAdapter.MeteredTerms({grossPricePerTiB: 7 ether}));
        BossTypes.ServiceOffer memory offer;
        offer.serviceId = SERVICE_ID;
        offer.offerVersion = 1;
        offer.provider = PROVIDER;
        offer.signingKey = providerSigningKey;
        offer.beneficiary = BENEFICIARY;
        offer.reporter = reporter;
        offer.resourceAdapter = address(resourceAdapter);
        offer.pricingAdapter = address(pricingAdapter);
        offer.serviceType = SERVICE_TYPE;
        offer.billingKind = BossTypes.BillingKind.METERED_FIXED_LOCKUP;
        offer.assuranceKind = BossTypes.AssuranceKind.TRUSTED_METERING;
        offer.dependencyKind = BossTypes.DependencyKind.NONE;
        offer.activationKind = BossTypes.ActivationKind.IMMEDIATE;
        offer.terminationBillingKind = BossTypes.TerminationBillingKind.ZERO_AFTER_REQUEST;
        offer.pricingDataHash = keccak256(pricingData);
        offer.termsHash = keccak256("metered-v1");
        offer.validUntilEpoch = 2_000;
        offer.requiredLockupPeriod = 0;
        offer.pauseAllowed = true;
        offer.providerMaxRatePerEpoch = 0;
        offer.providerMaxFixedLockup = 10 ether;
        offer.nonce = nonce;

        BossTypes.CapPolicy memory caps = BossTypes.CapPolicy({
            maxRatePerEpoch: 0,
            maxFixedLockup: 10 ether,
            maxSingleCharge: singleCap,
            maxChargePerWindow: windowCap,
            lifetimeCapGross: lifetimeCap,
            chargeWindowEpochs: 100,
            notAfterEpoch: 1_500,
            maxLockupPeriod: 0
        });
        input = BossTypes.AcceptanceInput({
            offer: offer,
            providerSignature: bytes(""),
            resource: BossTypes.ResourceRef({
                kind: BossTypes.ResourceKind.FWSS_PDP_DATASET,
                chainId: uint64(block.chainid),
                anchor: address(0xA11CE),
                resourceId: nonce,
                context: bytes32(0)
            }),
            resourceData: abi.encode("metered-resource"),
            pricingData: pricingData,
            caps: caps,
            initialFixedBudget: initialBudget,
            accessGrantHash: bytes32(0)
        });
        input.providerSignature = _signOffer(offer);
    }

    function _subscriptionId(BossTypes.AcceptanceInput memory input) private view returns (bytes32) {
        return BossHashes.deriveSubscriptionId(
            address(account), BossHashes.hashServiceOffer(input.offer), BossHashes.hashResource(input.resource)
        );
    }

    function _claim(uint256 nonce, uint64 fromEpoch, uint64 toEpoch, uint256 units)
        private
        pure
        returns (BossTypes.UsageClaim memory claim)
    {
        claim = BossTypes.UsageClaim({
            claimId: keccak256(abi.encode("claim", nonce)),
            fromEpoch: fromEpoch,
            toEpoch: toEpoch,
            units: units,
            evidenceHash: keccak256(abi.encode("evidence", nonce)),
            evidenceURI: "ipfs://usage-evidence",
            nonce: nonce
        });
    }

    function _signOffer(BossTypes.ServiceOffer memory offer) private returns (bytes memory) {
        bytes32 digest = BossHashes.hashTypedData(
            BossHashes.domainSeparator(block.chainid, address(account)), BossHashes.hashServiceOffer(offer)
        );
        return _sign(PROVIDER_KEY, digest);
    }

    function _signClaim(bytes32 subscriptionId, BossTypes.UsageClaim memory claim) private returns (bytes memory) {
        return _signWith(REPORTER_KEY, subscriptionId, claim);
    }

    function _signWith(uint256 key, bytes32 subscriptionId, BossTypes.UsageClaim memory claim)
        private
        returns (bytes memory)
    {
        bytes32 digest = BossHashes.hashTypedData(
            BossHashes.domainSeparator(block.chainid, address(account)),
            BossHashes.hashUsageClaim(subscriptionId, claim)
        );
        return _sign(key, digest);
    }

    function _sign(uint256 key, bytes32 digest) private returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _mustFailAccept(BossTypes.AcceptanceInput memory input) private {
        (bool success,) = address(account).call(abi.encodeCall(BossAccount.acceptOffer, (input)));
        require(!success, "invalid metered caps accepted");
    }

    function _mustFailClaim(bytes32 subscriptionId, BossTypes.UsageClaim memory claim, bytes memory signature)
        private
    {
        (bool success,) =
            address(account).call(abi.encodeCall(BossAccount.submitUsageClaim, (subscriptionId, claim, signature)));
        require(!success, "invalid claim accepted");
    }
}
