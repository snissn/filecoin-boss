// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {BossAdapterRegistry} from "./BossAdapterRegistry.sol";
import {BossServiceRegistry} from "./BossServiceRegistry.sol";
import {IBossPricingAdapter} from "./interfaces/IBossPricingAdapter.sol";
import {IBossResourceAdapter} from "./interfaces/IBossResourceAdapter.sol";
import {IFilecoinPayV1, IFilecoinPayValidator} from "./interfaces/IFilecoinPayV1.sol";
import {BossHashes} from "./libraries/BossHashes.sol";
import {BossTypes} from "./libraries/BossTypes.sol";

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue);
}

/// @notice Immutable user-owned account for independently bounded service rails.
contract BossAccount is IFilecoinPayValidator {
    uint256 private constant SECP256K1N_HALF = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;
    bytes4 private constant ERC1271_MAGIC_VALUE = 0x1626ba7e;
    bytes32 private constant ACTIVATION_ACK_TYPEHASH =
        keccak256("ActivationAcknowledgement(bytes32 subscriptionId,bytes32 provisioningHash)");

    error Unauthorized(address caller);
    error InvalidOwner();
    error InvalidFilecoinPay();
    error InvalidServiceRegistry();
    error InvalidAdapterRegistry();
    error InvalidAccountVersion();
    error InvalidOffer();
    error UnsupportedBillingKind();
    error UnsupportedTerminationBillingKind();
    error OfferNotYetValid(uint256 currentEpoch, uint256 validAfterEpoch);
    error OfferExpired(uint256 currentEpoch, uint256 validUntilEpoch);
    error InvalidProviderAuthority();
    error InvalidProviderSignature();
    error InvalidService();
    error InvalidAdapter(address adapter, BossTypes.AdapterKind kind);
    error InvalidResource();
    error InvalidQuote();
    error InvalidCapacityQuote();
    error InvalidCaps();
    error SubscriptionAlreadyExists(bytes32 subscriptionId);
    error UnknownSubscription(bytes32 subscriptionId);
    error UnknownRail(uint256 railId);
    error InvalidState(bytes32 subscriptionId, BossTypes.SubscriptionState state);
    error PauseNotAllowed(bytes32 subscriptionId);
    error ActivationNotAcknowledged(bytes32 subscriptionId);
    error ActivationAlreadyAcknowledged(bytes32 subscriptionId);
    error RailNotCurrent(uint256 railId, uint256 expectedEpoch, uint256 observedEpoch);
    error InvalidSettlementRange(uint256 fromEpoch, uint256 toEpoch);
    error InvalidReporter();
    error InvalidUsageClaim();
    error UsageClaimAlreadyConsumed(bytes32 claimId);
    error UsageNonceAlreadyConsumed(uint256 nonce);
    error UsageWindowMismatch(uint256 startWindow, uint256 endWindow);
    error FixedBudgetOutOfSync(uint256 expected, uint256 observed);
    error InvalidTopUp(uint256 currentBudget, uint256 requestedBudget);

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
    event ProviderActivationAcknowledged(bytes32 indexed subscriptionId, bytes32 provisioningHash);
    event SubscriptionActivated(bytes32 indexed subscriptionId, uint64 activatedEpoch);
    event RateSynchronized(
        bytes32 indexed subscriptionId,
        uint256 oldRate,
        uint256 newRate,
        uint64 quoteEpoch,
        uint64 validThroughEpoch,
        bytes32 resourceStatusHash,
        bytes32 quoteHash
    );
    event SubscriptionPaused(bytes32 indexed subscriptionId, uint64 pausedEpoch);
    event PauseRateUpdateDeferred(bytes32 indexed subscriptionId, bytes reason);
    event SubscriptionResumed(bytes32 indexed subscriptionId, uint64 resumedEpoch);
    event SubscriptionTerminationRequested(bytes32 indexed subscriptionId, uint64 requestEpoch);
    event SubscriptionPayTerminationObserved(bytes32 indexed subscriptionId, uint256 indexed railId, uint256 endEpoch);
    event SubscriptionEnded(bytes32 indexed subscriptionId, uint64 endedEpoch);
    event AccessGrantCommitted(bytes32 indexed subscriptionId, bytes32 accessGrantHash);
    event UsageClaimCharged(
        bytes32 indexed subscriptionId,
        bytes32 indexed claimId,
        uint256 units,
        uint256 rawGross,
        uint256 chargedGross,
        bytes32 evidenceHash
    );
    event FixedBudgetToppedUp(bytes32 indexed subscriptionId, uint256 oldBudget, uint256 newBudget);

    address public immutable owner;
    address public immutable payer;
    address public immutable filecoinPay;
    address public immutable serviceRegistry;
    address public immutable adapterRegistry;
    address public immutable factory;
    uint64 public immutable accountVersion;

    mapping(bytes32 subscriptionId => BossTypes.Subscription subscription) private _subscriptions;
    mapping(uint256 railId => bytes32 subscriptionId) private _subscriptionForRail;
    mapping(bytes32 subscriptionId => address signingKey) private _offerSigningKey;
    mapping(bytes32 subscriptionId => bool acknowledged) private _activationAcknowledged;
    mapping(bytes32 subscriptionId => bytes pricingData) private _pricingDataBySubscription;
    mapping(bytes32 subscriptionId => BossTypes.ResourceRef resource) private _resourceBySubscription;
    mapping(bytes32 subscriptionId => uint64 quoteTtlEpochs) private _capacityQuoteTtlEpochs;
    mapping(bytes32 subscriptionId => mapping(bytes32 claimId => bool consumed)) private _consumedClaims;
    mapping(bytes32 subscriptionId => mapping(uint256 nonce => bool consumed)) private _consumedUsageNonces;
    mapping(bytes32 subscriptionId => mapping(uint256 window => uint256 gross)) private _usageGrossByWindow;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized(msg.sender);
        _;
    }

    constructor(
        address owner_,
        address filecoinPay_,
        address serviceRegistry_,
        address adapterRegistry_,
        uint64 accountVersion_
    ) {
        if (owner_ == address(0)) revert InvalidOwner();
        if (filecoinPay_ == address(0)) revert InvalidFilecoinPay();
        if (serviceRegistry_ == address(0)) revert InvalidServiceRegistry();
        if (adapterRegistry_ == address(0)) revert InvalidAdapterRegistry();
        if (accountVersion_ != 1) revert InvalidAccountVersion();

        owner = owner_;
        payer = owner_;
        filecoinPay = filecoinPay_;
        serviceRegistry = serviceRegistry_;
        adapterRegistry = adapterRegistry_;
        accountVersion = accountVersion_;
        factory = msg.sender;
    }

    function acceptOffer(BossTypes.AcceptanceInput calldata input)
        external
        onlyOwner
        returns (bytes32 subscriptionId, uint256 railId)
    {
        BossTypes.ServiceOffer calldata offer = input.offer;
        _validateOfferAndService(offer, input.pricingData);
        _validateProviderSignature(offer, input.providerSignature);
        _requireAdapter(offer.resourceAdapter, BossTypes.AdapterKind.RESOURCE);
        _requireAdapter(offer.pricingAdapter, BossTypes.AdapterKind.PRICING);

        if (
            input.resource.kind != BossTypes.ResourceKind.FWSS_PDP_DATASET || input.resource.chainId != block.chainid
                || input.resource.anchor == address(0) || input.resource.context != bytes32(0)
                || (offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY && input.resourceData.length != 0)
        ) revert InvalidResource();
        bytes32 canonicalResourceKey = BossHashes.hashResource(input.resource);
        BossTypes.ResourceStatus memory resource =
            IBossResourceAdapter(offer.resourceAdapter).inspect(input.resource, payer, input.resourceData);
        if (
            !resource.exists || !resource.attachable || !resource.billable || resource.payer != payer
                || resource.resourceKey != canonicalResourceKey
        ) revert InvalidResource();

        BossTypes.RateQuote memory quote =
            IBossPricingAdapter(offer.pricingAdapter).quoteRate(resource, input.pricingData);
        if (offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY) {
            _validateCapacityQuote(resource, quote);
        }
        if (!quote.billable) revert InvalidQuote();
        _validateCaps(offer, input.caps, quote.ratePerEpoch, input.initialFixedBudget);

        bytes32 offerHash = BossHashes.hashServiceOffer(offer);
        subscriptionId = BossHashes.deriveSubscriptionId(address(this), offerHash, resource.resourceKey);
        if (_subscriptions[subscriptionId].state != BossTypes.SubscriptionState.NONE) {
            revert SubscriptionAlreadyExists(subscriptionId);
        }

        IFilecoinPayV1 pay = IFilecoinPayV1(filecoinPay);
        railId = pay.createRail(
            offer.token, payer, offer.beneficiary, address(this), offer.commissionBps, offer.commissionRecipient
        );
        pay.modifyRailLockup(railId, offer.requiredLockupPeriod, input.initialFixedBudget);

        bool active = offer.activationKind == BossTypes.ActivationKind.IMMEDIATE;
        if (active && quote.ratePerEpoch != 0) pay.modifyRailPayment(railId, quote.ratePerEpoch, 0);

        uint64 acceptedEpoch = _epoch();
        BossTypes.CapPolicy memory caps = input.caps;
        uint64 quoteValidThrough = offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY
            ? _capacityValidThrough(acceptedEpoch, offer.quoteTtlEpochs, caps.notAfterEpoch, quote.billable)
            : _quoteValidThrough(quote.validThroughEpoch, caps.notAfterEpoch);
        _subscriptions[subscriptionId] = BossTypes.Subscription({
            offerHash: offerHash,
            resourceKey: resource.resourceKey,
            resourceDataHash: keccak256(input.resourceData),
            pricingDataHash: keccak256(input.pricingData),
            accessGrantHash: input.accessGrantHash,
            provider: offer.provider,
            beneficiary: offer.beneficiary,
            reporter: offer.reporter,
            token: offer.token,
            resourceAdapter: offer.resourceAdapter,
            pricingAdapter: offer.pricingAdapter,
            railId: railId,
            billingKind: offer.billingKind,
            assuranceKind: offer.assuranceKind,
            dependencyKind: offer.dependencyKind,
            activationKind: offer.activationKind,
            terminationBillingKind: offer.terminationBillingKind,
            pauseAllowed: offer.pauseAllowed,
            caps: caps,
            acceptedRatePerEpoch: quote.ratePerEpoch,
            settledGross: 0,
            oneTimeChargedGross: 0,
            currentFixedBudget: input.initialFixedBudget,
            acceptedEpoch: acceptedEpoch,
            activatedEpoch: active ? acceptedEpoch : 0,
            quoteValidThroughEpoch: quoteValidThrough,
            pausedEpoch: 0,
            terminationRequestedEpoch: 0,
            payEndEpoch: 0,
            lastUsageToEpoch: 0,
            state: active ? BossTypes.SubscriptionState.ACTIVE : BossTypes.SubscriptionState.PENDING_ACTIVATION
        });
        _subscriptionForRail[railId] = subscriptionId;
        _offerSigningKey[subscriptionId] = offer.signingKey;
        if (
            offer.billingKind == BossTypes.BillingKind.METERED_FIXED_LOCKUP
                || offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY
        ) {
            _pricingDataBySubscription[subscriptionId] = input.pricingData;
        }
        if (offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY) {
            _resourceBySubscription[subscriptionId] = input.resource;
            _capacityQuoteTtlEpochs[subscriptionId] = offer.quoteTtlEpochs;
        }

        emit SubscriptionAccepted(
            subscriptionId,
            address(this),
            offerHash,
            resource.resourceKey,
            railId,
            offer.beneficiary,
            offer.token,
            active ? quote.ratePerEpoch : 0,
            input.initialFixedBudget
        );
        if (offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY) {
            emit RateSynchronized(
                subscriptionId,
                0,
                quote.ratePerEpoch,
                acceptedEpoch,
                quoteValidThrough,
                resource.statusHash,
                quote.quoteHash
            );
        }
        if (input.accessGrantHash != bytes32(0)) {
            emit AccessGrantCommitted(subscriptionId, input.accessGrantHash);
        }
        if (active) emit SubscriptionActivated(subscriptionId, acceptedEpoch);
    }

    function activationAckDigest(bytes32 subscriptionId, bytes32 provisioningHash) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(ACTIVATION_ACK_TYPEHASH, subscriptionId, provisioningHash));
        return BossHashes.hashTypedData(BossHashes.domainSeparator(block.chainid, address(this)), structHash);
    }

    function acknowledgeActivation(bytes32 subscriptionId, bytes32 provisioningHash, bytes calldata providerSignature)
        external
    {
        BossTypes.Subscription storage subscription = _requireSubscription(subscriptionId);
        if (subscription.state != BossTypes.SubscriptionState.PENDING_ACTIVATION) {
            revert InvalidState(subscriptionId, subscription.state);
        }
        if (_activationAcknowledged[subscriptionId]) revert ActivationAlreadyAcknowledged(subscriptionId);
        if (
            !_isValidSignature(
                _offerSigningKey[subscriptionId],
                activationAckDigest(subscriptionId, provisioningHash),
                providerSignature
            )
        ) revert InvalidProviderSignature();

        _activationAcknowledged[subscriptionId] = true;
        emit ProviderActivationAcknowledged(subscriptionId, provisioningHash);
    }

    function activate(bytes32 subscriptionId) external {
        BossTypes.Subscription storage subscription = _requireSubscription(subscriptionId);
        if (subscription.state != BossTypes.SubscriptionState.PENDING_ACTIVATION) {
            revert InvalidState(subscriptionId, subscription.state);
        }
        if (!_activationAcknowledged[subscriptionId]) revert ActivationNotAcknowledged(subscriptionId);
        _requireNotExpired(subscription);
        _requireCurrentCapacityQuote(subscription);

        uint256 currentEpoch = block.number;
        (,,,, uint256 finalSettledEpoch,) = IFilecoinPayV1(filecoinPay).settleRail(subscription.railId, currentEpoch);
        if (finalSettledEpoch != currentEpoch) {
            revert RailNotCurrent(subscription.railId, currentEpoch, finalSettledEpoch);
        }
        IFilecoinPayV1(filecoinPay).modifyRailPayment(subscription.railId, subscription.acceptedRatePerEpoch, 0);
        uint64 activatedEpoch = _epoch();
        subscription.activatedEpoch = activatedEpoch;
        subscription.state = BossTypes.SubscriptionState.ACTIVE;
        emit SubscriptionActivated(subscriptionId, activatedEpoch);
    }

    function syncRate(bytes32 subscriptionId) external {
        BossTypes.Subscription storage subscription = _requireSubscription(subscriptionId);
        if (
            subscription.billingKind != BossTypes.BillingKind.STREAM_CAPACITY
                || (
                    subscription.state != BossTypes.SubscriptionState.PENDING_ACTIVATION
                        && subscription.state != BossTypes.SubscriptionState.ACTIVE
                        && subscription.state != BossTypes.SubscriptionState.PAUSED
                )
        ) revert InvalidState(subscriptionId, subscription.state);
        _requireNotExpired(subscription);

        IFilecoinPayV1 pay = IFilecoinPayV1(filecoinPay);
        uint256 currentEpoch = block.number;
        (,,,, uint256 finalSettledEpoch,) = pay.settleRail(subscription.railId, currentEpoch);
        if (finalSettledEpoch != currentEpoch) {
            revert RailNotCurrent(subscription.railId, currentEpoch, finalSettledEpoch);
        }

        _requirePinnedAdapterCode(subscription.resourceAdapter, BossTypes.AdapterKind.RESOURCE);
        _requirePinnedAdapterCode(subscription.pricingAdapter, BossTypes.AdapterKind.PRICING);

        BossTypes.ResourceRef memory resourceRef = _resourceBySubscription[subscriptionId];
        BossTypes.ResourceStatus memory resource =
            IBossResourceAdapter(subscription.resourceAdapter).inspect(resourceRef, payer, bytes(""));
        if (resource.resourceKey != subscription.resourceKey) revert InvalidResource();

        BossTypes.RateQuote memory quote = IBossPricingAdapter(subscription.pricingAdapter).quoteRate(
            resource, _pricingDataBySubscription[subscriptionId]
        );
        _validateCapacityQuote(resource, quote);
        if (quote.ratePerEpoch > subscription.caps.maxRatePerEpoch) revert InvalidCaps();

        uint256 oldRate = subscription.acceptedRatePerEpoch;
        uint256 desiredRailRate = subscription.state == BossTypes.SubscriptionState.ACTIVE ? quote.ratePerEpoch : 0;
        IFilecoinPayV1.RailView memory rail = pay.getRail(subscription.railId);
        if (rail.paymentRate != desiredRailRate) {
            pay.modifyRailPayment(subscription.railId, desiredRailRate, 0);
        }

        uint64 quoteEpoch = _epoch();
        uint64 validThrough = _capacityValidThrough(
            quoteEpoch, _capacityQuoteTtlEpochs[subscriptionId], subscription.caps.notAfterEpoch, quote.billable
        );
        subscription.acceptedRatePerEpoch = quote.ratePerEpoch;
        subscription.quoteValidThroughEpoch = validThrough;

        emit RateSynchronized(
            subscriptionId, oldRate, quote.ratePerEpoch, quoteEpoch, validThrough, resource.statusHash, quote.quoteHash
        );
    }

    function pause(bytes32 subscriptionId) external onlyOwner {
        BossTypes.Subscription storage subscription = _requireSubscription(subscriptionId);
        if (subscription.state != BossTypes.SubscriptionState.ACTIVE) {
            revert InvalidState(subscriptionId, subscription.state);
        }
        if (!subscription.pauseAllowed) revert PauseNotAllowed(subscriptionId);

        uint64 pausedEpoch = _epoch();
        subscription.pausedEpoch = pausedEpoch;
        subscription.state = BossTypes.SubscriptionState.PAUSED;
        emit SubscriptionPaused(subscriptionId, pausedEpoch);

        try IFilecoinPayV1(filecoinPay).modifyRailPayment(subscription.railId, 0, 0) {}
        catch (bytes memory reason) {
            emit PauseRateUpdateDeferred(subscriptionId, reason);
        }
    }

    function resume(bytes32 subscriptionId) external onlyOwner {
        BossTypes.Subscription storage subscription = _requireSubscription(subscriptionId);
        if (subscription.state != BossTypes.SubscriptionState.PAUSED) {
            revert InvalidState(subscriptionId, subscription.state);
        }
        _requireNotExpired(subscription);
        _requireCurrentCapacityQuote(subscription);

        uint256 currentEpoch = block.number;
        (,,,, uint256 finalSettledEpoch,) = IFilecoinPayV1(filecoinPay).settleRail(subscription.railId, currentEpoch);
        if (finalSettledEpoch != currentEpoch) {
            revert RailNotCurrent(subscription.railId, currentEpoch, finalSettledEpoch);
        }
        IFilecoinPayV1(filecoinPay).modifyRailPayment(subscription.railId, subscription.acceptedRatePerEpoch, 0);

        uint64 resumedEpoch = _epoch();
        subscription.activatedEpoch = resumedEpoch;
        subscription.pausedEpoch = 0;
        subscription.state = BossTypes.SubscriptionState.ACTIVE;
        emit SubscriptionResumed(subscriptionId, resumedEpoch);
    }

    function terminate(bytes32 subscriptionId) external onlyOwner {
        BossTypes.Subscription storage subscription = _requireSubscription(subscriptionId);
        if (
            subscription.state != BossTypes.SubscriptionState.PENDING_ACTIVATION
                && subscription.state != BossTypes.SubscriptionState.ACTIVE
                && subscription.state != BossTypes.SubscriptionState.PAUSED
                && subscription.state != BossTypes.SubscriptionState.EXHAUSTED
        ) revert InvalidState(subscriptionId, subscription.state);

        uint64 requestEpoch = _epoch();
        subscription.terminationRequestedEpoch = requestEpoch;
        subscription.state = BossTypes.SubscriptionState.TERMINATING;
        emit SubscriptionTerminationRequested(subscriptionId, requestEpoch);
        IFilecoinPayV1(filecoinPay).terminateRail(subscription.railId);
    }

    function settle(bytes32 subscriptionId, uint256 untilEpoch) external {
        BossTypes.Subscription storage subscription = _requireSubscription(subscriptionId);
        (,,,, uint256 finalSettledEpoch,) = IFilecoinPayV1(filecoinPay).settleRail(subscription.railId, untilEpoch);
        if (
            subscription.state == BossTypes.SubscriptionState.TERMINATING && subscription.payEndEpoch != 0
                && finalSettledEpoch >= subscription.payEndEpoch
        ) {
            subscription.state = BossTypes.SubscriptionState.ENDED;
            emit SubscriptionEnded(subscriptionId, uint64(finalSettledEpoch));
        }
    }

    function submitUsageClaim(
        bytes32 subscriptionId,
        BossTypes.UsageClaim calldata claim,
        bytes calldata reporterSignature
    ) external returns (uint256 chargedGross) {
        BossTypes.Subscription storage subscription = _requireSubscription(subscriptionId);
        if (
            subscription.billingKind != BossTypes.BillingKind.METERED_FIXED_LOCKUP
                || subscription.state != BossTypes.SubscriptionState.ACTIVE
        ) revert InvalidState(subscriptionId, subscription.state);
        _requireNotExpired(subscription);

        if (
            claim.claimId == bytes32(0) || claim.toEpoch <= claim.fromEpoch || claim.toEpoch > block.number
                || claim.fromEpoch < subscription.activatedEpoch || claim.fromEpoch < subscription.lastUsageToEpoch
        ) revert InvalidUsageClaim();
        if (_consumedClaims[subscriptionId][claim.claimId]) {
            revert UsageClaimAlreadyConsumed(claim.claimId);
        }
        if (_consumedUsageNonces[subscriptionId][claim.nonce]) {
            revert UsageNonceAlreadyConsumed(claim.nonce);
        }

        uint256 windowSize = subscription.caps.chargeWindowEpochs;
        uint256 startWindow = (uint256(claim.fromEpoch) - subscription.acceptedEpoch) / windowSize;
        uint256 endWindow = (uint256(claim.toEpoch) - 1 - subscription.acceptedEpoch) / windowSize;
        if (startWindow != endWindow) revert UsageWindowMismatch(startWindow, endWindow);

        bytes32 claimHash = BossHashes.hashUsageClaim(subscriptionId, claim);
        bytes32 digest = BossHashes.hashTypedData(BossHashes.domainSeparator(block.chainid, address(this)), claimHash);
        if (!_isValidSignature(subscription.reporter, digest, reporterSignature)) revert InvalidReporter();

        _requirePinnedAdapterCode(subscription.pricingAdapter, BossTypes.AdapterKind.PRICING);
        uint256 rawGross = IBossPricingAdapter(subscription.pricingAdapter).quoteUsage(
            claim.units, _pricingDataBySubscription[subscriptionId]
        );
        IFilecoinPayV1.RailView memory rail = IFilecoinPayV1(filecoinPay).getRail(subscription.railId);
        if (rail.lockupFixed != subscription.currentFixedBudget) {
            revert FixedBudgetOutOfSync(subscription.currentFixedBudget, rail.lockupFixed);
        }

        chargedGross = _min(rawGross, subscription.caps.maxSingleCharge);
        chargedGross = _min(
            chargedGross,
            BossTypes.remainingCap(
                subscription.caps.maxChargePerWindow, _usageGrossByWindow[subscriptionId][startWindow]
            )
        );
        chargedGross = _min(chargedGross, _remainingLifetime(subscription));
        chargedGross = _min(chargedGross, rail.lockupFixed);

        _consumedClaims[subscriptionId][claim.claimId] = true;
        _consumedUsageNonces[subscriptionId][claim.nonce] = true;
        _usageGrossByWindow[subscriptionId][startWindow] += chargedGross;
        subscription.oneTimeChargedGross += chargedGross;
        subscription.currentFixedBudget = rail.lockupFixed - chargedGross;
        subscription.lastUsageToEpoch = claim.toEpoch;

        if (subscription.currentFixedBudget == 0 || _remainingLifetime(subscription) == 0) {
            subscription.state = BossTypes.SubscriptionState.EXHAUSTED;
        }

        if (chargedGross != 0) {
            IFilecoinPayV1(filecoinPay).modifyRailPayment(subscription.railId, 0, chargedGross);
        }
        emit UsageClaimCharged(subscriptionId, claim.claimId, claim.units, rawGross, chargedGross, claim.evidenceHash);
    }

    function topUpFixedBudget(bytes32 subscriptionId, uint256 newFixedBudget) external onlyOwner {
        BossTypes.Subscription storage subscription = _requireSubscription(subscriptionId);
        if (
            subscription.billingKind != BossTypes.BillingKind.METERED_FIXED_LOCKUP
                || subscription.state == BossTypes.SubscriptionState.TERMINATING
                || subscription.state == BossTypes.SubscriptionState.ENDED
        ) revert InvalidState(subscriptionId, subscription.state);
        _requireNotExpired(subscription);

        uint256 oldBudget = subscription.currentFixedBudget;
        if (
            newFixedBudget <= oldBudget || newFixedBudget > subscription.caps.maxFixedLockup
                || _remainingLifetime(subscription) == 0
        ) revert InvalidTopUp(oldBudget, newFixedBudget);

        IFilecoinPayV1 pay = IFilecoinPayV1(filecoinPay);
        IFilecoinPayV1.RailView memory rail = pay.getRail(subscription.railId);
        if (rail.lockupFixed != oldBudget) revert FixedBudgetOutOfSync(oldBudget, rail.lockupFixed);

        pay.modifyRailLockup(subscription.railId, rail.lockupPeriod, newFixedBudget);
        subscription.currentFixedBudget = newFixedBudget;
        if (subscription.state == BossTypes.SubscriptionState.EXHAUSTED) {
            subscription.state = BossTypes.SubscriptionState.ACTIVE;
        }
        emit FixedBudgetToppedUp(subscriptionId, oldBudget, newFixedBudget);
    }

    function getSubscription(bytes32 subscriptionId)
        external
        view
        returns (BossTypes.Subscription memory subscription)
    {
        subscription = _subscriptions[subscriptionId];
    }

    function subscriptionForRail(uint256 railId) external view returns (bytes32) {
        return _subscriptionForRail[railId];
    }

    function activationAcknowledged(bytes32 subscriptionId) external view returns (bool) {
        return _activationAcknowledged[subscriptionId];
    }

    function validatePayment(uint256 railId, uint256 proposedAmount, uint256 fromEpoch, uint256 toEpoch, uint256 rate)
        external
        returns (IFilecoinPayValidator.ValidationResult memory result)
    {
        if (msg.sender != filecoinPay) revert Unauthorized(msg.sender);
        if (toEpoch < fromEpoch) revert InvalidSettlementRange(fromEpoch, toEpoch);

        bytes32 subscriptionId = _subscriptionForRail[railId];
        if (subscriptionId == bytes32(0)) revert UnknownRail(railId);
        BossTypes.Subscription storage subscription = _subscriptions[subscriptionId];

        uint256 billableEnd = _billableEnd(subscription, toEpoch);
        uint256 billableStart = fromEpoch;
        if (billableStart < subscription.activatedEpoch) billableStart = subscription.activatedEpoch;

        uint256 modifiedAmount;
        if (billableEnd > billableStart) {
            uint256 acceptedRate = rate < subscription.acceptedRatePerEpoch ? rate : subscription.acceptedRatePerEpoch;
            modifiedAmount = (billableEnd - billableStart) * acceptedRate;
            if (modifiedAmount > proposedAmount) modifiedAmount = proposedAmount;

            uint256 remaining = _remainingLifetime(subscription);
            if (modifiedAmount > remaining) modifiedAmount = remaining;
            subscription.settledGross += modifiedAmount;

            if (
                !BossTypes.isUnlimitedCap(subscription.caps.lifetimeCapGross) && _remainingLifetime(subscription) == 0
                    && subscription.state == BossTypes.SubscriptionState.ACTIVE
            ) subscription.state = BossTypes.SubscriptionState.EXHAUSTED;
        }

        result = IFilecoinPayValidator.ValidationResult({
            modifiedAmount: modifiedAmount,
            settleUpto: toEpoch,
            note: subscription.billingKind == BossTypes.BillingKind.STREAM_CAPACITY
                ? "FILECOIN_BOSS_CAPACITY_V1"
                : "FILECOIN_BOSS_FLAT_V1"
        });
    }

    function railTerminated(uint256 railId, address, uint256 endEpoch) external {
        if (msg.sender != filecoinPay) return;

        bytes32 subscriptionId = _subscriptionForRail[railId];
        if (subscriptionId == bytes32(0)) return;
        BossTypes.Subscription storage subscription = _subscriptions[subscriptionId];
        if (subscription.state == BossTypes.SubscriptionState.NONE) return;

        uint64 boundedEndEpoch = endEpoch > type(uint64).max ? type(uint64).max : uint64(endEpoch);
        subscription.payEndEpoch = boundedEndEpoch;
        if (subscription.state != BossTypes.SubscriptionState.ENDED) {
            subscription.state = BossTypes.SubscriptionState.TERMINATING;
        }
        emit SubscriptionPayTerminationObserved(subscriptionId, railId, endEpoch);
    }

    function _validateOfferAndService(BossTypes.ServiceOffer calldata offer, bytes calldata pricingData) private view {
        if (
            offer.provider == address(0) || offer.signingKey == address(0) || offer.beneficiary == address(0)
                || offer.resourceAdapter == address(0) || offer.pricingAdapter == address(0)
                || offer.serviceId == bytes32(0) || offer.serviceType == bytes32(0)
        ) revert InvalidOffer();
        bool isCapacity = offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY;
        bool isMetered = offer.billingKind == BossTypes.BillingKind.METERED_FIXED_LOCKUP;
        if (offer.billingKind != BossTypes.BillingKind.STREAM_FLAT && !isCapacity && !isMetered) {
            revert UnsupportedBillingKind();
        }
        if (
            isCapacity
                && (offer.quoteTtlEpochs == 0 || offer.assuranceKind != BossTypes.AssuranceKind.ONCHAIN_DETERMINISTIC)
        ) revert InvalidOffer();
        if (
            isMetered
                && (offer.reporter == address(0) || offer.assuranceKind != BossTypes.AssuranceKind.TRUSTED_METERING)
        ) revert InvalidOffer();
        if (offer.terminationBillingKind == BossTypes.TerminationBillingKind.ADAPTER_DECIDES) {
            revert UnsupportedTerminationBillingKind();
        }
        if (offer.commissionBps > 10_000 || offer.pricingDataHash != keccak256(pricingData)) revert InvalidOffer();
        if (offer.validAfterEpoch != 0 && block.number < offer.validAfterEpoch) {
            revert OfferNotYetValid(block.number, offer.validAfterEpoch);
        }
        if (offer.validUntilEpoch != 0 && block.number > offer.validUntilEpoch) {
            revert OfferExpired(block.number, offer.validUntilEpoch);
        }

        BossServiceRegistry registry = BossServiceRegistry(serviceRegistry);
        if (
            !registry.isAuthorizedSigner(offer.provider, offer.signingKey)
                || registry.isOfferNonceRevoked(offer.provider, offer.nonce)
        ) {
            revert InvalidProviderAuthority();
        }
        BossServiceRegistry.ServiceRecord memory service = registry.getService(offer.provider, offer.serviceId);
        if (!service.published || service.serviceType != offer.serviceType) revert InvalidService();
    }

    function _validateProviderSignature(BossTypes.ServiceOffer calldata offer, bytes calldata providerSignature)
        private
        view
    {
        bytes32 offerHash = BossHashes.hashServiceOffer(offer);
        bytes32 digest = BossHashes.hashTypedData(BossHashes.domainSeparator(block.chainid, address(this)), offerHash);
        if (!_isValidSignature(offer.signingKey, digest, providerSignature)) revert InvalidProviderSignature();
    }

    function _requireAdapter(address adapter, BossTypes.AdapterKind kind) private view {
        if (!BossAdapterRegistry(adapterRegistry).isActive(adapter, kind, 1)) revert InvalidAdapter(adapter, kind);
    }

    function _requirePinnedAdapterCode(address adapter, BossTypes.AdapterKind kind) private view {
        BossTypes.AdapterRecord memory record = BossAdapterRegistry(adapterRegistry).getAdapter(adapter);
        if (
            record.kind != kind || record.interfaceVersion != 1 || record.codeHash == bytes32(0)
                || adapter.code.length == 0 || adapter.codehash != record.codeHash
        ) revert InvalidAdapter(adapter, kind);
    }

    function _validateCaps(
        BossTypes.ServiceOffer calldata offer,
        BossTypes.CapPolicy calldata caps,
        uint256 ratePerEpoch,
        uint256 initialFixedBudget
    ) private view {
        if (
            caps.maxRatePerEpoch > offer.providerMaxRatePerEpoch || ratePerEpoch > caps.maxRatePerEpoch
                || ratePerEpoch > offer.providerMaxRatePerEpoch || caps.maxFixedLockup > offer.providerMaxFixedLockup
                || initialFixedBudget > caps.maxFixedLockup || initialFixedBudget > offer.providerMaxFixedLockup
                || offer.requiredLockupPeriod > caps.maxLockupPeriod
        ) revert InvalidCaps();
        if (caps.notAfterEpoch != 0 && block.number >= caps.notAfterEpoch) revert InvalidCaps();

        if (
            offer.billingKind == BossTypes.BillingKind.STREAM_FLAT
                || offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY
        ) {
            if (caps.chargeWindowEpochs != 0) revert InvalidCaps();
            if (
                offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY
                    && (
                        offer.quoteTtlEpochs == 0 || initialFixedBudget != 0 || caps.maxFixedLockup != 0
                            || offer.providerMaxFixedLockup != 0
                    )
            ) revert InvalidCaps();
            return;
        }
        if (
            ratePerEpoch != 0 || caps.maxRatePerEpoch != 0 || offer.providerMaxRatePerEpoch != 0
                || initialFixedBudget == 0 || caps.maxSingleCharge == 0 || caps.maxChargePerWindow == 0
                || caps.lifetimeCapGross == 0 || caps.chargeWindowEpochs == 0
                || BossTypes.isUnlimitedCap(caps.maxFixedLockup) || BossTypes.isUnlimitedCap(caps.maxSingleCharge)
                || BossTypes.isUnlimitedCap(caps.maxChargePerWindow) || BossTypes.isUnlimitedCap(caps.lifetimeCapGross)
        ) revert InvalidCaps();
    }

    function _validateCapacityQuote(BossTypes.ResourceStatus memory resource, BossTypes.RateQuote memory quote)
        private
        view
    {
        bool available = resource.exists && resource.attachable && resource.billable;
        bool unavailable = !resource.exists && !resource.attachable && !resource.billable;
        if (!available && !unavailable) revert InvalidResource();
        if (quote.billable != available || quote.quoteHash == bytes32(0) || quote.validThroughEpoch != 0) {
            revert InvalidCapacityQuote();
        }

        if (available) {
            if (resource.payer != payer || resource.statusHash == bytes32(0)) revert InvalidCapacityQuote();
        } else if (quote.ratePerEpoch != 0) {
            revert InvalidCapacityQuote();
        }
    }

    function _capacityValidThrough(uint64 quoteEpoch, uint64 quoteTtlEpochs, uint64 notAfterEpoch, bool billable)
        private
        pure
        returns (uint64 validThrough)
    {
        if (!billable) return quoteEpoch;
        validThrough = quoteEpoch + quoteTtlEpochs;
        if (notAfterEpoch != 0 && notAfterEpoch < validThrough) validThrough = notAfterEpoch;
    }

    function _requireCurrentCapacityQuote(BossTypes.Subscription storage subscription) private view {
        if (
            subscription.billingKind == BossTypes.BillingKind.STREAM_CAPACITY
                && (subscription.quoteValidThroughEpoch == 0 || block.number >= subscription.quoteValidThroughEpoch)
        ) revert InvalidCapacityQuote();
    }

    function _requireSubscription(bytes32 subscriptionId)
        private
        view
        returns (BossTypes.Subscription storage subscription)
    {
        subscription = _subscriptions[subscriptionId];
        if (subscription.state == BossTypes.SubscriptionState.NONE) revert UnknownSubscription(subscriptionId);
    }

    function _requireNotExpired(BossTypes.Subscription storage subscription) private view {
        uint64 notAfterEpoch = subscription.caps.notAfterEpoch;
        if (notAfterEpoch != 0 && block.number >= notAfterEpoch) {
            revert OfferExpired(block.number, notAfterEpoch);
        }
    }

    function _billableEnd(BossTypes.Subscription storage subscription, uint256 requestedEnd)
        private
        view
        returns (uint256 end)
    {
        if (
            subscription.state == BossTypes.SubscriptionState.NONE
                || subscription.state == BossTypes.SubscriptionState.PENDING_ACTIVATION
                || subscription.state == BossTypes.SubscriptionState.ENDED
                || subscription.state == BossTypes.SubscriptionState.EXHAUSTED
        ) return 0;

        end = requestedEnd;
        uint64 validThrough = subscription.quoteValidThroughEpoch;
        if (validThrough != 0 && end > validThrough) end = validThrough;
        uint64 notAfterEpoch = subscription.caps.notAfterEpoch;
        if (notAfterEpoch != 0 && end > notAfterEpoch) end = notAfterEpoch;

        if (subscription.state == BossTypes.SubscriptionState.PAUSED && end > subscription.pausedEpoch) {
            end = subscription.pausedEpoch;
        }
        if (subscription.state == BossTypes.SubscriptionState.TERMINATING) {
            if (subscription.pausedEpoch != 0 && end > subscription.pausedEpoch) end = subscription.pausedEpoch;
            if (
                subscription.terminationBillingKind == BossTypes.TerminationBillingKind.ZERO_AFTER_REQUEST
                    && end > subscription.terminationRequestedEpoch
            ) end = subscription.terminationRequestedEpoch;
            if (
                subscription.terminationBillingKind == BossTypes.TerminationBillingKind.PAY_THROUGH_FILECOIN_PAY_END
                    && subscription.payEndEpoch != 0 && end > subscription.payEndEpoch
            ) end = subscription.payEndEpoch;
        }
    }

    function _remainingLifetime(BossTypes.Subscription storage subscription) private view returns (uint256) {
        return BossTypes.remainingCap(
            subscription.caps.lifetimeCapGross, subscription.settledGross + subscription.oneTimeChargedGross
        );
    }

    function _min(uint256 left, uint256 right) private pure returns (uint256) {
        return left < right ? left : right;
    }

    function _quoteValidThrough(uint64 quoteValidThroughEpoch, uint64 notAfterEpoch) private pure returns (uint64) {
        if (notAfterEpoch == 0) return quoteValidThroughEpoch;
        if (quoteValidThroughEpoch == 0 || notAfterEpoch < quoteValidThroughEpoch) return notAfterEpoch;
        return quoteValidThroughEpoch;
    }

    function _isValidSignature(address signer, bytes32 digest, bytes calldata signature) private view returns (bool) {
        if (signer.code.length == 0) return _recover(digest, signature) == signer;

        (bool success, bytes memory result) = signer.staticcall{gas: 50_000}(
            abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, signature)
        );
        return success && result.length >= 32 && abi.decode(result, (bytes4)) == ERC1271_MAGIC_VALUE;
    }

    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address signer) {
        if (signature.length != 65) return address(0);

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) v += 27;
        if ((v != 27 && v != 28) || uint256(s) > SECP256K1N_HALF) return address(0);
        signer = ecrecover(digest, v, r, s);
    }

    function _epoch() private view returns (uint64) {
        return uint64(block.number);
    }
}
