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
    event SubscriptionPaused(bytes32 indexed subscriptionId, uint64 pausedEpoch);
    event PauseRateUpdateDeferred(bytes32 indexed subscriptionId, bytes reason);
    event SubscriptionResumed(bytes32 indexed subscriptionId, uint64 resumedEpoch);
    event SubscriptionTerminationRequested(bytes32 indexed subscriptionId, uint64 requestEpoch);
    event SubscriptionPayTerminationObserved(bytes32 indexed subscriptionId, uint256 indexed railId, uint256 endEpoch);
    event SubscriptionEnded(bytes32 indexed subscriptionId, uint64 endedEpoch);
    event AccessGrantCommitted(bytes32 indexed subscriptionId, bytes32 accessGrantHash);

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
            quoteValidThroughEpoch: _quoteValidThrough(quote.validThroughEpoch, caps.notAfterEpoch),
            pausedEpoch: 0,
            terminationRequestedEpoch: 0,
            payEndEpoch: 0,
            lastUsageToEpoch: 0,
            state: active ? BossTypes.SubscriptionState.ACTIVE : BossTypes.SubscriptionState.PENDING_ACTIVATION
        });
        _subscriptionForRail[railId] = subscriptionId;
        _offerSigningKey[subscriptionId] = offer.signingKey;

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

            uint256 remaining = BossTypes.remainingCap(subscription.caps.lifetimeCapGross, subscription.settledGross);
            if (modifiedAmount > remaining) modifiedAmount = remaining;
            subscription.settledGross += modifiedAmount;

            if (
                !BossTypes.isUnlimitedCap(subscription.caps.lifetimeCapGross)
                    && subscription.settledGross >= subscription.caps.lifetimeCapGross
                    && subscription.state == BossTypes.SubscriptionState.ACTIVE
            ) subscription.state = BossTypes.SubscriptionState.EXHAUSTED;
        }

        result = IFilecoinPayValidator.ValidationResult({
            modifiedAmount: modifiedAmount,
            settleUpto: toEpoch,
            note: "FILECOIN_BOSS_FLAT_V1"
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
        if (offer.billingKind != BossTypes.BillingKind.STREAM_FLAT) revert UnsupportedBillingKind();
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
                || offer.requiredLockupPeriod > caps.maxLockupPeriod || caps.chargeWindowEpochs != 0
        ) revert InvalidCaps();
        if (caps.notAfterEpoch != 0 && block.number >= caps.notAfterEpoch) revert InvalidCaps();
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
