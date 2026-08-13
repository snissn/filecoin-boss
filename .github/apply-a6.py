from pathlib import Path


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"anchor mismatch ({count}): {old[:160]!r}")
    return text.replace(old, new)


path = Path("src/BossAccount.sol")
text = path.read_text()

text = replace_once(
    text,
    "    error InvalidQuote();\n    error InvalidCaps();\n",
    "    error InvalidQuote();\n    error InvalidCapacityQuote();\n    error InvalidCaps();\n",
)

text = replace_once(
    text,
    "    event SubscriptionActivated(bytes32 indexed subscriptionId, uint64 activatedEpoch);\n    event SubscriptionPaused(bytes32 indexed subscriptionId, uint64 pausedEpoch);\n",
    """    event SubscriptionActivated(bytes32 indexed subscriptionId, uint64 activatedEpoch);
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
""",
)

text = replace_once(
    text,
    """    mapping(bytes32 subscriptionId => bytes pricingData) private _pricingDataBySubscription;
    mapping(bytes32 subscriptionId => mapping(bytes32 claimId => bool consumed)) private _consumedClaims;
""",
    """    mapping(bytes32 subscriptionId => bytes pricingData) private _pricingDataBySubscription;
    mapping(bytes32 subscriptionId => BossTypes.ResourceRef resource) private _resourceBySubscription;
    mapping(bytes32 subscriptionId => bytes resourceData) private _resourceDataBySubscription;
    mapping(bytes32 subscriptionId => uint64 quoteTtlEpochs) private _capacityQuoteTtlEpochs;
    mapping(bytes32 subscriptionId => uint64 quoteEpoch) private _capacityQuoteEpoch;
    mapping(bytes32 subscriptionId => bytes32 statusHash) private _capacityResourceStatusHash;
    mapping(bytes32 subscriptionId => bytes32 quoteHash) private _capacityQuoteHash;
    mapping(bytes32 subscriptionId => mapping(bytes32 claimId => bool consumed)) private _consumedClaims;
""",
)

text = replace_once(
    text,
    """        BossTypes.RateQuote memory quote =
            IBossPricingAdapter(offer.pricingAdapter).quoteRate(resource, input.pricingData);
        if (!quote.billable) revert InvalidQuote();
        _validateCaps(offer, input.caps, quote.ratePerEpoch, input.initialFixedBudget);
""",
    """        BossTypes.RateQuote memory quote =
            IBossPricingAdapter(offer.pricingAdapter).quoteRate(resource, input.pricingData);
        if (offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY) {
            _validateCapacityQuote(resource, quote, offer.quoteTtlEpochs);
        }
        if (!quote.billable) revert InvalidQuote();
        _validateCaps(offer, input.caps, quote.ratePerEpoch, input.initialFixedBudget);
""",
)

text = replace_once(
    text,
    """        _offerSigningKey[subscriptionId] = offer.signingKey;
        if (offer.billingKind == BossTypes.BillingKind.METERED_FIXED_LOCKUP) {
            _pricingDataBySubscription[subscriptionId] = input.pricingData;
        }

        emit SubscriptionAccepted(
""",
    """        _offerSigningKey[subscriptionId] = offer.signingKey;
        if (
            offer.billingKind == BossTypes.BillingKind.METERED_FIXED_LOCKUP
                || offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY
        ) {
            _pricingDataBySubscription[subscriptionId] = input.pricingData;
        }
        if (offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY) {
            _resourceBySubscription[subscriptionId] = input.resource;
            _resourceDataBySubscription[subscriptionId] = input.resourceData;
            _capacityQuoteTtlEpochs[subscriptionId] = offer.quoteTtlEpochs;
            _capacityQuoteEpoch[subscriptionId] = acceptedEpoch;
            _capacityResourceStatusHash[subscriptionId] = resource.statusHash;
            _capacityQuoteHash[subscriptionId] = quote.quoteHash;
        }

        emit SubscriptionAccepted(
""",
)

text = replace_once(
    text,
    """        );
        if (input.accessGrantHash != bytes32(0)) {
""",
    """        );
        if (offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY) {
            emit RateSynchronized(
                subscriptionId,
                0,
                quote.ratePerEpoch,
                acceptedEpoch,
                _quoteValidThrough(quote.validThroughEpoch, caps.notAfterEpoch),
                resource.statusHash,
                quote.quoteHash
            );
        }
        if (input.accessGrantHash != bytes32(0)) {
""",
)

text = replace_once(
    text,
    """        if (!_activationAcknowledged[subscriptionId]) revert ActivationNotAcknowledged(subscriptionId);
        _requireNotExpired(subscription);

        uint256 currentEpoch = block.number;
""",
    """        if (!_activationAcknowledged[subscriptionId]) revert ActivationNotAcknowledged(subscriptionId);
        _requireNotExpired(subscription);
        _requireCurrentCapacityQuote(subscription);

        uint256 currentEpoch = block.number;
""",
)

text = replace_once(
    text,
    """    function pause(bytes32 subscriptionId) external onlyOwner {
""",
    """    function syncRate(bytes32 subscriptionId) external {
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
        BossTypes.ResourceStatus memory resource = IBossResourceAdapter(subscription.resourceAdapter).inspect(
            resourceRef, payer, _resourceDataBySubscription[subscriptionId]
        );
        if (resource.resourceKey != subscription.resourceKey) revert InvalidResource();

        BossTypes.RateQuote memory quote = IBossPricingAdapter(subscription.pricingAdapter).quoteRate(
            resource, _pricingDataBySubscription[subscriptionId]
        );
        _validateCapacityQuote(resource, quote, _capacityQuoteTtlEpochs[subscriptionId]);
        if (quote.ratePerEpoch > subscription.caps.maxRatePerEpoch) revert InvalidCaps();

        uint256 oldRate = subscription.acceptedRatePerEpoch;
        uint256 desiredRailRate =
            subscription.state == BossTypes.SubscriptionState.ACTIVE ? quote.ratePerEpoch : 0;
        IFilecoinPayV1.RailView memory rail = pay.getRail(subscription.railId);
        if (rail.paymentRate != desiredRailRate) {
            pay.modifyRailPayment(subscription.railId, desiredRailRate, 0);
        }

        uint64 quoteEpoch = _epoch();
        uint64 validThrough = _quoteValidThrough(quote.validThroughEpoch, subscription.caps.notAfterEpoch);
        subscription.acceptedRatePerEpoch = quote.ratePerEpoch;
        subscription.quoteValidThroughEpoch = validThrough;
        _capacityQuoteEpoch[subscriptionId] = quoteEpoch;
        _capacityResourceStatusHash[subscriptionId] = resource.statusHash;
        _capacityQuoteHash[subscriptionId] = quote.quoteHash;

        emit RateSynchronized(
            subscriptionId,
            oldRate,
            quote.ratePerEpoch,
            quoteEpoch,
            validThrough,
            resource.statusHash,
            quote.quoteHash
        );
    }

    function capacityQuoteState(bytes32 subscriptionId)
        external
        view
        returns (uint64 quoteEpoch, bytes32 resourceStatusHash, bytes32 quoteHash)
    {
        BossTypes.Subscription storage subscription = _requireSubscription(subscriptionId);
        if (subscription.billingKind != BossTypes.BillingKind.STREAM_CAPACITY) {
            revert InvalidState(subscriptionId, subscription.state);
        }
        return (
            _capacityQuoteEpoch[subscriptionId],
            _capacityResourceStatusHash[subscriptionId],
            _capacityQuoteHash[subscriptionId]
        );
    }

    function pause(bytes32 subscriptionId) external onlyOwner {
""",
)

text = replace_once(
    text,
    """    function resume(bytes32 subscriptionId) external onlyOwner {
        BossTypes.Subscription storage subscription = _requireSubscription(subscriptionId);
        if (subscription.state != BossTypes.SubscriptionState.PAUSED) {
            revert InvalidState(subscriptionId, subscription.state);
        }
        _requireNotExpired(subscription);

        uint256 currentEpoch = block.number;
""",
    """    function resume(bytes32 subscriptionId) external onlyOwner {
        BossTypes.Subscription storage subscription = _requireSubscription(subscriptionId);
        if (subscription.state != BossTypes.SubscriptionState.PAUSED) {
            revert InvalidState(subscriptionId, subscription.state);
        }
        _requireNotExpired(subscription);
        _requireCurrentCapacityQuote(subscription);

        uint256 currentEpoch = block.number;
""",
)

text = replace_once(
    text,
    """            note: "FILECOIN_BOSS_FLAT_V1"
""",
    """            note: subscription.billingKind == BossTypes.BillingKind.STREAM_CAPACITY
                ? "FILECOIN_BOSS_CAPACITY_V1"
                : "FILECOIN_BOSS_FLAT_V1"
""",
)

text = replace_once(
    text,
    """        bool isMetered = offer.billingKind == BossTypes.BillingKind.METERED_FIXED_LOCKUP;
        if (offer.billingKind != BossTypes.BillingKind.STREAM_FLAT && !isMetered) {
            revert UnsupportedBillingKind();
        }
        if (
            isMetered
                && (offer.reporter == address(0) || offer.assuranceKind != BossTypes.AssuranceKind.TRUSTED_METERING)
        ) revert InvalidOffer();
""",
    """        bool isCapacity = offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY;
        bool isMetered = offer.billingKind == BossTypes.BillingKind.METERED_FIXED_LOCKUP;
        if (offer.billingKind != BossTypes.BillingKind.STREAM_FLAT && !isCapacity && !isMetered) {
            revert UnsupportedBillingKind();
        }
        if (
            isCapacity
                && (
                    offer.quoteTtlEpochs == 0
                        || offer.assuranceKind != BossTypes.AssuranceKind.ONCHAIN_DETERMINISTIC
                )
        ) revert InvalidOffer();
        if (
            isMetered
                && (offer.reporter == address(0) || offer.assuranceKind != BossTypes.AssuranceKind.TRUSTED_METERING)
        ) revert InvalidOffer();
""",
)

text = replace_once(
    text,
    """        if (offer.billingKind == BossTypes.BillingKind.STREAM_FLAT) {
            if (caps.chargeWindowEpochs != 0) revert InvalidCaps();
            return;
        }
""",
    """        if (
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
""",
)

text = replace_once(
    text,
    """    function _requireSubscription(bytes32 subscriptionId)
""",
    """    function _validateCapacityQuote(
        BossTypes.ResourceStatus memory resource,
        BossTypes.RateQuote memory quote,
        uint64 maximumTtlEpochs
    ) private view {
        bool available = resource.exists && resource.attachable && resource.billable;
        bool unavailable = !resource.exists && !resource.attachable && !resource.billable;
        if (!available && !unavailable) revert InvalidResource();
        if (quote.billable != available || quote.quoteHash == bytes32(0) || maximumTtlEpochs == 0) {
            revert InvalidCapacityQuote();
        }

        if (available) {
            if (
                resource.payer != payer || resource.statusHash == bytes32(0)
                    || quote.validThroughEpoch <= block.number
                    || uint256(quote.validThroughEpoch) > block.number + maximumTtlEpochs
            ) revert InvalidCapacityQuote();
        } else if (quote.ratePerEpoch != 0 || quote.validThroughEpoch != block.number) {
            revert InvalidCapacityQuote();
        }
    }

    function _requireCurrentCapacityQuote(BossTypes.Subscription storage subscription) private view {
        if (
            subscription.billingKind == BossTypes.BillingKind.STREAM_CAPACITY
                && (
                    subscription.quoteValidThroughEpoch == 0
                        || block.number >= subscription.quoteValidThroughEpoch
                )
        ) revert InvalidCapacityQuote();
    }

    function _requireSubscription(bytes32 subscriptionId)
""",
)

path.write_text(text)
