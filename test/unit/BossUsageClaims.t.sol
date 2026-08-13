// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossAccount} from "../../src/BossAccount.sol";
import {BossAdapterRegistry} from "../../src/BossAdapterRegistry.sol";
import {BossServiceRegistry} from "../../src/BossServiceRegistry.sol";
import {CappedMeteredAdapter} from "../../src/adapters/pricing/CappedMeteredAdapter.sol";
import {IBossResourceAdapter} from "../../src/interfaces/IBossResourceAdapter.sol";
import {IFilecoinPayV1, IFilecoinPayValidator} from "../../src/interfaces/IFilecoinPayV1.sol";
import {BossHashes} from "../../src/libraries/BossHashes.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";

interface VmUsageClaims {
    function addr(uint256 privateKey) external returns (address keyAddr);
    function prank(address sender) external;
    function roll(uint256 newHeight) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
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

    MockMeteredFilecoinPayV1 private pay;
    BossServiceRegistry private serviceRegistry;
    BossAdapterRegistry private adapterRegistry;
    MeteredResourceAdapter private resourceAdapter;
    CappedMeteredAdapter private pricingAdapter;
    BossAccount private account;
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
        pay.setOperatorApproval(address(0), address(this), address(account), true);
    }

    function testClaimsAreBoundedBySingleWindowLifetimeAndBudgetCaps() public {
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(_input(10 ether, 9 ether, 5 ether, 2 ether, 1));

        uint256 charged1 = account.submitUsageClaim(subscriptionId, _claim(1, 100, 110, TIB), _signClaim(subscriptionId, _claim(1, 100, 110, TIB)));
        uint256 charged2 = account.submitUsageClaim(subscriptionId, _claim(2, 110, 120, TIB), _signClaim(subscriptionId, _claim(2, 110, 120, TIB)));
        uint256 charged3 = account.submitUsageClaim(subscriptionId, _claim(3, 120, 130, TIB), _signClaim(subscriptionId, _claim(3, 120, 130, TIB)));
        uint256 charged4 = account.submitUsageClaim(subscriptionId, _claim(4, 130, 140, TIB), _signClaim(subscriptionId, _claim(4, 130, 140, TIB)));

        require(charged1 == 2 ether, "single cap first");
        require(charged2 == 2 ether, "single cap second");
        require(charged3 == 1 ether, "window remainder");
        require(charged4 == 0, "window exhausted");
        require(pay.oneTimeGross(railId) == 5 ether, "window gross");
        require(pay.getRail(railId).lockupFixed == 5 ether, "budget after window");

        BossTypes.UsageClaim memory next = _claim(5, 200, 210, TIB);
        require(account.submitUsageClaim(subscriptionId, next, _signClaim(subscriptionId, next)) == 2 ether, "next window");
        next = _claim(6, 210, 220, TIB);
        require(account.submitUsageClaim(subscriptionId, next, _signClaim(subscriptionId, next)) == 2 ether, "lifetime remainder");

        BossTypes.Subscription memory subscription = account.getSubscription(subscriptionId);
        require(subscription.oneTimeChargedGross == 9 ether, "lifetime charged");
        require(subscription.currentFixedBudget == 1 ether, "local budget");
        require(subscription.state == BossTypes.SubscriptionState.EXHAUSTED, "lifetime exhausted");
        require(pay.getRail(railId).lockupFixed == 1 ether, "Pay budget synchronized");
    }

    function testReplayOverlapWrongReporterFutureAndCrossWindowClaimsFailClosed() public {
        (bytes32 subscriptionId,) = account.acceptOffer(_input(10 ether, 20 ether, 10 ether, 5 ether, 2));
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

    function testZeroByteClaimIsConsumedWithoutPayment() public {
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(_input(3 ether, 20 ether, 10 ether, 5 ether, 3));
        BossTypes.UsageClaim memory claim = _claim(20, 100, 110, 0);

        require(account.submitUsageClaim(subscriptionId, claim, _signClaim(subscriptionId, claim)) == 0, "zero charge");
        require(pay.oneTimeGross(railId) == 0, "no Pay payment");
        _mustFailClaim(subscriptionId, claim, _signClaim(subscriptionId, claim));
    }

    function testOnlyOwnerCanTopUpAndTopUpCannotExceedAcceptedCap() public {
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(_input(3 ether, 20 ether, 10 ether, 5 ether, 4));
        BossTypes.UsageClaim memory claim = _claim(30, 100, 110, TIB);
        account.submitUsageClaim(subscriptionId, claim, _signClaim(subscriptionId, claim));
        require(pay.getRail(railId).lockupFixed == 0, "budget exhausted");
        require(account.getSubscription(subscriptionId).state == BossTypes.SubscriptionState.EXHAUSTED, "exhausted");

        vm.prank(reporter);
        (bool unauthorized,) = address(account).call(abi.encodeCall(BossAccount.topUpFixedBudget, (subscriptionId, 5 ether)));
        require(!unauthorized, "reporter top-up accepted");

        account.topUpFixedBudget(subscriptionId, 5 ether);
        require(pay.getRail(railId).lockupFixed == 5 ether, "Pay budget topped up");
        require(account.getSubscription(subscriptionId).currentFixedBudget == 5 ether, "local budget topped up");
        require(account.getSubscription(subscriptionId).state == BossTypes.SubscriptionState.ACTIVE, "service reactivated");

        (bool aboveCap,) = address(account).call(abi.encodeCall(BossAccount.topUpFixedBudget, (subscriptionId, 11 ether)));
        require(!aboveCap, "above-cap top-up accepted");
    }

    function _input(
        uint256 initialBudget,
        uint256 lifetimeCap,
        uint256 windowCap,
        uint256 singleCap,
        uint256 nonce
    ) private returns (BossTypes.AcceptanceInput memory input) {
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

    function _signClaim(bytes32 subscriptionId, BossTypes.UsageClaim memory claim)
        private
        returns (bytes memory)
    {
        return _signWith(REPORTER_KEY, subscriptionId, claim);
    }

    function _signWith(uint256 key, bytes32 subscriptionId, BossTypes.UsageClaim memory claim)
        private
        returns (bytes memory)
    {
        bytes32 digest = BossHashes.hashTypedData(
            BossHashes.domainSeparator(block.chainid, address(account)), BossHashes.hashUsageClaim(subscriptionId, claim)
        );
        return _sign(key, digest);
    }

    function _sign(uint256 key, bytes32 digest) private returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _mustFailClaim(bytes32 subscriptionId, BossTypes.UsageClaim memory claim, bytes memory signature)
        private
    {
        (bool success,) = address(account).call(
            abi.encodeCall(BossAccount.submitUsageClaim, (subscriptionId, claim, signature))
        );
        require(!success, "invalid claim accepted");
    }
}
