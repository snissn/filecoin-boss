// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BossAccount} from "../../src/BossAccount.sol";
import {BossAdapterRegistry} from "../../src/BossAdapterRegistry.sol";
import {BossServiceRegistry} from "../../src/BossServiceRegistry.sol";
import {FlatRateAdapter} from "../../src/adapters/pricing/FlatRateAdapter.sol";
import {IBossResourceAdapter} from "../../src/interfaces/IBossResourceAdapter.sol";
import {IFilecoinPayV1, IFilecoinPayValidator} from "../../src/interfaces/IFilecoinPayV1.sol";
import {BossHashes} from "../../src/libraries/BossHashes.sol";
import {BossTypes} from "../../src/libraries/BossTypes.sol";

interface VmFlatLifecycle {
    function addr(uint256 privateKey) external returns (address keyAddr);
    function prank(address sender) external;
    function roll(uint256 newHeight) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
}

contract MockFlatResourceAdapter is IBossResourceAdapter {
    bool public valid = true;
    bytes32 public resourceKeyOverride;

    function setValid(bool valid_) external {
        valid = valid_;
    }

    function setResourceKeyOverride(bytes32 resourceKeyOverride_) external {
        resourceKeyOverride = resourceKeyOverride_;
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function inspect(BossTypes.ResourceRef calldata resource, address expectedPayer, bytes calldata resourceData)
        external
        view
        returns (BossTypes.ResourceStatus memory status)
    {
        status = BossTypes.ResourceStatus({
            resourceKey: resourceKeyOverride == bytes32(0) ? BossHashes.hashResource(resource) : resourceKeyOverride,
            exists: valid,
            attachable: valid,
            billable: valid,
            payer: expectedPayer,
            storageProvider: address(0xB0B),
            sizeInBytes: 1,
            statusHash: keccak256(resourceData)
        });
    }
}

contract MockERC1271Signer {
    bytes4 private constant MAGIC_VALUE = 0x1626ba7e;
    bytes32 public validDigest;

    function setValidDigest(bytes32 digest) external {
        validDigest = digest;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return digest == validDigest ? MAGIC_VALUE : bytes4(0xffffffff);
    }
}

/// @dev Minimal semantic harness, locked to Filecoin Pay V1 commit
/// 04ded6af6c15c4b5d98545f393dc656004d4aede; it is not production Pay code.
contract MockFilecoinPayV1 is IFilecoinPayV1 {
    mapping(uint256 railId => RailView rail) private _rails;
    mapping(address token => mapping(address client => mapping(address operator => bool approved))) private _approved;
    mapping(uint256 railId => uint256 gross) public settledGross;

    uint256 private _nextRailId = 1;
    bool public rejectRateUpdates;
    bool public underfunded;

    function setOperatorApproval(address token, address client, address operator, bool approved) external {
        require(msg.sender == client, "only client");
        _approved[token][client][operator] = approved;
    }

    function setRejectRateUpdates(bool reject) external {
        rejectRateUpdates = reject;
    }

    function setUnderfunded(bool value) external {
        underfunded = value;
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
        require(oneTimePayment == 0, "one-time unsupported");
        if (rejectRateUpdates) revert("rate update rejected");
        rail.paymentRate = newRate;
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
        require(rail.from != address(0), "unknown rail");

        uint256 targetEpoch = untilEpoch;
        if (rail.endEpoch != 0 && targetEpoch > rail.endEpoch) targetEpoch = rail.endEpoch;
        if (targetEpoch < rail.settledUpTo) targetEpoch = rail.settledUpTo;

        uint256 gross = (targetEpoch - rail.settledUpTo) * rail.paymentRate;
        uint256 settleUpto = targetEpoch;
        if (rail.validator != address(0)) {
            IFilecoinPayValidator.ValidationResult memory result = IFilecoinPayValidator(rail.validator).validatePayment(
                railId, gross, rail.settledUpTo, targetEpoch, rail.paymentRate
            );
            require(result.modifiedAmount <= gross, "validator amount");
            require(result.settleUpto <= targetEpoch, "validator epoch");
            gross = result.modifiedAmount;
            settleUpto = result.settleUpto;
            note = result.note;
        }

        rail.settledUpTo = settleUpto;
        settledGross[railId] += gross;
        return (gross, gross, 0, 0, settleUpto, note);
    }

    function terminateRail(uint256 railId) external {
        RailView storage rail = _rails[railId];
        require(msg.sender == rail.from || msg.sender == rail.operator, "not terminator");
        if (msg.sender == rail.from && underfunded) revert("client underfunded");
        require(rail.endEpoch == 0, "already terminated");

        rail.endEpoch = block.number + rail.lockupPeriod;
        if (rail.validator != address(0)) {
            IFilecoinPayValidator(rail.validator).railTerminated(railId, msg.sender, rail.endEpoch);
        }
    }

    function getRail(uint256 railId) external view returns (RailView memory rail) {
        rail = _rails[railId];
    }

    function getAccountInfoIfSettled(address, address)
        external
        pure
        returns (uint256 fundedUntilEpoch, uint256 currentFunds, uint256 availableFunds, uint256 currentLockupRate)
    {
        return (0, 0, 0, 0);
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
        return (_approved[token][client][operator], type(uint256).max, type(uint256).max, 0, 0, type(uint256).max);
    }
}

contract BossAccountFlatLifecycleTest {
    VmFlatLifecycle internal constant vm = VmFlatLifecycle(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant PROVIDER_KEY = 0xA11CE;
    address internal constant PROVIDER = address(0xB0B);
    address internal constant BENEFICIARY = address(0xBEEF);
    bytes32 internal constant SERVICE_ID = keccak256("flat-managed-storage");
    bytes32 internal constant SERVICE_TYPE = keccak256("managed-storage");

    MockFilecoinPayV1 internal pay;
    BossServiceRegistry internal serviceRegistry;
    BossAdapterRegistry internal adapterRegistry;
    MockFlatResourceAdapter internal resourceAdapter;
    FlatRateAdapter internal pricingAdapter;
    BossAccount internal account;
    address internal signingKey;
    uint256 internal baseRailId;

    function setUp() public {
        vm.roll(100);
        pay = new MockFilecoinPayV1();
        serviceRegistry = new BossServiceRegistry();
        adapterRegistry = new BossAdapterRegistry(address(this));
        resourceAdapter = new MockFlatResourceAdapter();
        pricingAdapter = new FlatRateAdapter();
        signingKey = vm.addr(PROVIDER_KEY);

        vm.prank(PROVIDER);
        serviceRegistry.registerProvider("ipfs://provider", signingKey);
        vm.prank(PROVIDER);
        serviceRegistry.publishService(SERVICE_ID, SERVICE_TYPE, "ipfs://service");

        adapterRegistry.registerAdapter(
            address(resourceAdapter), BossTypes.AdapterKind.RESOURCE, 1, "ipfs://resource-adapter"
        );
        adapterRegistry.registerAdapter(
            address(pricingAdapter), BossTypes.AdapterKind.PRICING, 1, "ipfs://flat-pricing"
        );

        account = new BossAccount(address(this), address(pay), address(serviceRegistry), address(adapterRegistry), 1);
        pay.setOperatorApproval(address(0), address(this), address(account), true);

        pay.setOperatorApproval(address(0), address(this), address(this), true);
        baseRailId = pay.createRail(address(0), address(this), address(0xF55), address(0), 0, address(0));
        pay.modifyRailLockup(baseRailId, 20, 0);
        pay.modifyRailPayment(baseRailId, 7, 0);
    }

    function testImmediateLifecyclePausesLocallyAndTerminatesWhileUnderfunded() public {
        BossTypes.AcceptanceInput memory input = _input(
            BossTypes.ActivationKind.IMMEDIATE, BossTypes.TerminationBillingKind.PAY_THROUGH_FILECOIN_PAY_END, 1_000, 1
        );
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(input);

        BossTypes.Subscription memory subscription = account.getSubscription(subscriptionId);
        IFilecoinPayV1.RailView memory rail = pay.getRail(railId);
        require(subscription.state == BossTypes.SubscriptionState.ACTIVE, "active after acceptance");
        require(subscription.acceptedRatePerEpoch == 10, "accepted rate");
        require(rail.from == address(this), "payer preserved");
        require(rail.operator == address(account), "Boss is operator");
        require(rail.paymentRate == 10, "Pay rate active");

        vm.roll(110);
        account.settle(subscriptionId, 110);
        require(account.getSubscription(subscriptionId).settledGross == 100, "first settlement");

        pay.setRejectRateUpdates(true);
        account.pause(subscriptionId);
        require(account.getSubscription(subscriptionId).state == BossTypes.SubscriptionState.PAUSED, "paused locally");
        require(pay.getRail(railId).paymentRate == 10, "nominal Pay rate retained");

        vm.roll(120);
        account.settle(subscriptionId, 120);
        subscription = account.getSubscription(subscriptionId);
        require(subscription.settledGross == 100, "pause bills zero");
        require(pay.getRail(railId).settledUpTo == 120, "pause advances cursor");

        pay.setRejectRateUpdates(false);
        account.resume(subscriptionId);
        require(account.getSubscription(subscriptionId).state == BossTypes.SubscriptionState.ACTIVE, "resumed");
        require(pay.getRail(railId).paymentRate == 10, "rate restored");

        vm.roll(125);
        account.settle(subscriptionId, 125);
        require(account.getSubscription(subscriptionId).settledGross == 150, "resumed settlement");

        pay.setUnderfunded(true);
        account.terminate(subscriptionId);
        subscription = account.getSubscription(subscriptionId);
        rail = pay.getRail(railId);
        require(subscription.state == BossTypes.SubscriptionState.TERMINATING, "terminating");
        require(subscription.payEndEpoch == 130, "Pay end observed");
        require(rail.endEpoch == 130, "operator termination accepted");

        vm.roll(130);
        account.settle(subscriptionId, 130);
        subscription = account.getSubscription(subscriptionId);
        require(subscription.state == BossTypes.SubscriptionState.ENDED, "ended after tail");
        require(subscription.settledGross == 200, "tail settlement");

        IFilecoinPayV1.RailView memory baseRail = pay.getRail(baseRailId);
        require(baseRail.paymentRate == 7, "base rail rate untouched");
        require(baseRail.endEpoch == 0, "base rail not terminated");
    }

    function testProviderAcknowledgementActivatesZeroRateRail() public {
        BossTypes.AcceptanceInput memory input = _input(
            BossTypes.ActivationKind.PROVIDER_ACK,
            BossTypes.TerminationBillingKind.PAY_THROUGH_FILECOIN_PAY_END,
            1_000,
            2
        );
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(input);

        require(
            account.getSubscription(subscriptionId).state == BossTypes.SubscriptionState.PENDING_ACTIVATION,
            "pending activation"
        );
        require(pay.getRail(railId).paymentRate == 0, "pending rate zero");
        _mustFail(address(account), abi.encodeCall(BossAccount.activate, (subscriptionId)));

        vm.roll(105);
        bytes32 provisioningHash = keccak256("provisioned");
        bytes memory acknowledgement = _signDigest(account.activationAckDigest(subscriptionId, provisioningHash));
        account.acknowledgeActivation(subscriptionId, provisioningHash, acknowledgement);
        account.activate(subscriptionId);

        require(account.activationAcknowledged(subscriptionId), "acknowledged");
        require(account.getSubscription(subscriptionId).state == BossTypes.SubscriptionState.ACTIVE, "active");
        require(pay.getRail(railId).paymentRate == 10, "activated rate");
        require(pay.getRail(railId).settledUpTo == 105, "activation settles prospectively");
    }

    function testReplayExpiredRevokedAndOverRateAcceptancesFailClosed() public {
        BossTypes.AcceptanceInput memory input =
            _input(BossTypes.ActivationKind.IMMEDIATE, BossTypes.TerminationBillingKind.ZERO_AFTER_REQUEST, 1_000, 3);
        account.acceptOffer(input);
        _mustFailAccept(input);

        BossTypes.AcceptanceInput memory expired =
            _input(BossTypes.ActivationKind.IMMEDIATE, BossTypes.TerminationBillingKind.ZERO_AFTER_REQUEST, 1_000, 4);
        expired.offer.validUntilEpoch = 99;
        expired.providerSignature = _signOffer(expired.offer);
        _mustFailAccept(expired);

        BossTypes.AcceptanceInput memory revoked =
            _input(BossTypes.ActivationKind.IMMEDIATE, BossTypes.TerminationBillingKind.ZERO_AFTER_REQUEST, 1_000, 5);
        vm.prank(PROVIDER);
        serviceRegistry.revokeOfferNonce(5);
        _mustFailAccept(revoked);

        BossTypes.AcceptanceInput memory overRate =
            _input(BossTypes.ActivationKind.IMMEDIATE, BossTypes.TerminationBillingKind.ZERO_AFTER_REQUEST, 1_000, 6);
        overRate.caps.maxRatePerEpoch = 9;
        _mustFailAccept(overRate);
    }

    function testLifetimeCapExhaustsWithoutBlockingSettlementCursor() public {
        BossTypes.AcceptanceInput memory input =
            _input(BossTypes.ActivationKind.IMMEDIATE, BossTypes.TerminationBillingKind.ZERO_AFTER_REQUEST, 25, 7);
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(input);

        vm.roll(110);
        account.settle(subscriptionId, 110);
        BossTypes.Subscription memory subscription = account.getSubscription(subscriptionId);
        require(subscription.settledGross == 25, "lifetime cap enforced");
        require(subscription.state == BossTypes.SubscriptionState.EXHAUSTED, "exhausted state");

        vm.roll(120);
        account.settle(subscriptionId, 120);
        subscription = account.getSubscription(subscriptionId);
        require(subscription.settledGross == 25, "no post-cap charge");
        require(pay.getRail(railId).settledUpTo == 120, "cap advances cursor");
    }

    function testUnauthorizedCallbacksCannotMutateOrCharge() public {
        BossTypes.AcceptanceInput memory input =
            _input(BossTypes.ActivationKind.IMMEDIATE, BossTypes.TerminationBillingKind.ZERO_AFTER_REQUEST, 1_000, 8);
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(input);

        account.railTerminated(railId, address(this), 999);
        BossTypes.Subscription memory subscription = account.getSubscription(subscriptionId);
        require(subscription.state == BossTypes.SubscriptionState.ACTIVE, "unauthorized callback ignored");
        require(subscription.payEndEpoch == 0, "unauthorized end ignored");

        _mustFail(
            address(account),
            abi.encodeCall(BossAccount.validatePayment, (railId, uint256(10), uint256(100), uint256(101), uint256(10)))
        );
    }

    function testCanonicalFwssBindingAndFlatCapShapeFailClosed() public {
        BossTypes.AcceptanceInput memory input =
            _input(BossTypes.ActivationKind.IMMEDIATE, BossTypes.TerminationBillingKind.ZERO_AFTER_REQUEST, 1_000, 10);

        resourceAdapter.setResourceKeyOverride(bytes32(uint256(1)));
        _mustFailAccept(input);

        resourceAdapter.setResourceKeyOverride(bytes32(0));
        input =
            _input(BossTypes.ActivationKind.IMMEDIATE, BossTypes.TerminationBillingKind.ZERO_AFTER_REQUEST, 1_000, 11);
        input.resource.kind = BossTypes.ResourceKind.GENERIC_CONTENT_ROOT;
        _mustFailAccept(input);

        input.resource.kind = BossTypes.ResourceKind.FWSS_PDP_DATASET;
        input.resource.context = keccak256("nonzero-context");
        _mustFailAccept(input);

        input.resource.context = bytes32(0);
        input.caps.chargeWindowEpochs = 1;
        _mustFailAccept(input);
    }

    function testERC1271ProviderOfferAndActivationSignatures() public {
        MockERC1271Signer contractSigner = new MockERC1271Signer();
        vm.prank(PROVIDER);
        serviceRegistry.setSigningKey(address(contractSigner), true);

        BossTypes.AcceptanceInput memory input = _input(
            BossTypes.ActivationKind.PROVIDER_ACK,
            BossTypes.TerminationBillingKind.PAY_THROUGH_FILECOIN_PAY_END,
            1_000,
            12
        );
        input.offer.signingKey = address(contractSigner);
        bytes32 offerDigest = BossHashes.hashTypedData(
            BossHashes.domainSeparator(block.chainid, address(account)), BossHashes.hashServiceOffer(input.offer)
        );
        contractSigner.setValidDigest(offerDigest);
        input.providerSignature = hex"01";
        (bytes32 subscriptionId, uint256 railId) = account.acceptOffer(input);

        bytes32 provisioningHash = keccak256("contract-provisioned");
        contractSigner.setValidDigest(account.activationAckDigest(subscriptionId, provisioningHash));
        account.acknowledgeActivation(subscriptionId, provisioningHash, hex"02");
        account.activate(subscriptionId);

        require(
            account.getSubscription(subscriptionId).state == BossTypes.SubscriptionState.ACTIVE,
            "contract signer active"
        );
        require(pay.getRail(railId).paymentRate == 10, "contract signer rate");
    }

    function testInvalidResourceAndFlatPricingFailuresAreClosed() public {
        BossTypes.AcceptanceInput memory input =
            _input(BossTypes.ActivationKind.IMMEDIATE, BossTypes.TerminationBillingKind.ZERO_AFTER_REQUEST, 1_000, 9);
        resourceAdapter.setValid(false);
        _mustFailAccept(input);

        BossTypes.ResourceStatus memory resource;
        bytes memory zeroPeriod =
            abi.encode(FlatRateAdapter.FlatRateTerms({grossPricePerPeriod: 1_000, periodEpochs: 0}));
        _mustFail(address(pricingAdapter), abi.encodeCall(FlatRateAdapter.quoteRate, (resource, zeroPeriod)));

        bytes memory pricingData =
            abi.encode(FlatRateAdapter.FlatRateTerms({grossPricePerPeriod: 1_000, periodEpochs: 30}));
        BossTypes.RateQuote memory quote = pricingAdapter.quoteRate(resource, pricingData);
        require(quote.ratePerEpoch == 33, "floor rate");
        require(keccak256(bytes(quote.note)) == keccak256("floor remainder=10"), "remainder disclosed");
    }

    function _input(
        BossTypes.ActivationKind activationKind,
        BossTypes.TerminationBillingKind terminationBillingKind,
        uint256 lifetimeCap,
        uint256 nonce
    ) private returns (BossTypes.AcceptanceInput memory input) {
        bytes memory pricingData =
            abi.encode(FlatRateAdapter.FlatRateTerms({grossPricePerPeriod: 300, periodEpochs: 30}));

        BossTypes.ServiceOffer memory offer;
        offer.serviceId = SERVICE_ID;
        offer.offerVersion = 1;
        offer.provider = PROVIDER;
        offer.signingKey = signingKey;
        offer.beneficiary = BENEFICIARY;
        offer.token = address(0);
        offer.resourceAdapter = address(resourceAdapter);
        offer.pricingAdapter = address(pricingAdapter);
        offer.serviceType = SERVICE_TYPE;
        offer.billingKind = BossTypes.BillingKind.STREAM_FLAT;
        offer.assuranceKind = BossTypes.AssuranceKind.CANCELLABLE_ONLY;
        offer.dependencyKind = BossTypes.DependencyKind.NONE;
        offer.activationKind = activationKind;
        offer.terminationBillingKind = terminationBillingKind;
        offer.pricingDataHash = keccak256(pricingData);
        offer.termsHash = keccak256("flat-v1");
        offer.validUntilEpoch = uint64(block.number + 1_000);
        offer.requiredLockupPeriod = 5;
        offer.pauseAllowed = true;
        offer.providerMaxRatePerEpoch = 10;
        offer.providerMaxFixedLockup = 100;
        offer.nonce = nonce;

        BossTypes.ResourceRef memory resource = BossTypes.ResourceRef({
            kind: BossTypes.ResourceKind.FWSS_PDP_DATASET,
            chainId: uint64(block.chainid),
            anchor: address(0xA11CE),
            resourceId: 1,
            context: bytes32(0)
        });
        BossTypes.CapPolicy memory caps = BossTypes.CapPolicy({
            maxRatePerEpoch: 10,
            maxFixedLockup: 100,
            maxSingleCharge: type(uint256).max,
            maxChargePerWindow: type(uint256).max,
            lifetimeCapGross: lifetimeCap,
            chargeWindowEpochs: 0,
            notAfterEpoch: uint64(block.number + 1_000),
            maxLockupPeriod: 5
        });

        input = BossTypes.AcceptanceInput({
            offer: offer,
            providerSignature: bytes(""),
            resource: resource,
            resourceData: abi.encode("resource"),
            pricingData: pricingData,
            caps: caps,
            initialFixedBudget: 20,
            accessGrantHash: keccak256("access")
        });
        input.providerSignature = _signOffer(offer);
    }

    function _signOffer(BossTypes.ServiceOffer memory offer) private returns (bytes memory) {
        bytes32 digest = BossHashes.hashTypedData(
            BossHashes.domainSeparator(block.chainid, address(account)), BossHashes.hashServiceOffer(offer)
        );
        return _signDigest(digest);
    }

    function _signDigest(bytes32 digest) private returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PROVIDER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _mustFailAccept(BossTypes.AcceptanceInput memory input) private {
        _mustFail(address(account), abi.encodeCall(BossAccount.acceptOffer, (input)));
    }

    function _mustFail(address target, bytes memory callData) private {
        (bool success,) = target.call(callData);
        require(!success, "expected failure");
    }
}
