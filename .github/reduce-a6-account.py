from pathlib import Path


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"anchor mismatch ({count}): {old[:160]!r}")
    return text.replace(old, new)


account = Path("src/BossAccount.sol")
text = account.read_text()

text = replace_once(
    text,
    """    event RateSynchronized(
        bytes32 indexed subscriptionId,
        uint256 oldRate,
        uint256 newRate,
        uint64 quoteEpoch,
        uint64 validThroughEpoch,
        bytes32 resourceStatusHash,
        bytes32 quoteHash
    );
""",
    """    event RateSynchronized(
        bytes32 indexed subscriptionId, uint256 oldRate, uint256 newRate, uint64 validThroughEpoch
    );
""",
)

text = replace_once(
    text,
    """    mapping(bytes32 subscriptionId => BossTypes.Subscription subscription) private _subscriptions;
""",
    """    struct CapacityState {
        BossTypes.ResourceRef resource;
        uint64 quoteTtlEpochs;
        uint64 quoteEpoch;
        bytes32 resourceStatusHash;
    }

    mapping(bytes32 subscriptionId => BossTypes.Subscription subscription) private _subscriptions;
""",
)

text = replace_once(
    text,
    """    mapping(bytes32 subscriptionId => bytes pricingData) private _pricingDataBySubscription;
    mapping(bytes32 subscriptionId => BossTypes.ResourceRef resource) private _resourceBySubscription;
    mapping(bytes32 subscriptionId => bytes resourceData) private _resourceDataBySubscription;
    mapping(bytes32 subscriptionId => uint64 quoteTtlEpochs) private _capacityQuoteTtlEpochs;
    mapping(bytes32 subscriptionId => uint64 quoteEpoch) private _capacityQuoteEpoch;
    mapping(bytes32 subscriptionId => bytes32 statusHash) private _capacityResourceStatusHash;
    mapping(bytes32 subscriptionId => bytes32 quoteHash) private _capacityQuoteHash;
""",
    """    mapping(bytes32 subscriptionId => bytes pricingData) private _pricingDataBySubscription;
    mapping(bytes32 subscriptionId => CapacityState state) private _capacityBySubscription;
""",
)

text = replace_once(
    text,
    """        if (offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY) {
            _resourceBySubscription[subscriptionId] = input.resource;
            _resourceDataBySubscription[subscriptionId] = input.resourceData;
            _capacityQuoteTtlEpochs[subscriptionId] = offer.quoteTtlEpochs;
            _capacityQuoteEpoch[subscriptionId] = acceptedEpoch;
            _capacityResourceStatusHash[subscriptionId] = resource.statusHash;
            _capacityQuoteHash[subscriptionId] = quote.quoteHash;
        }
""",
    """        if (offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY) {
            CapacityState storage capacity = _capacityBySubscription[subscriptionId];
            capacity.resource = input.resource;
            capacity.quoteTtlEpochs = offer.quoteTtlEpochs;
            capacity.quoteEpoch = acceptedEpoch;
            capacity.resourceStatusHash = resource.statusHash;
        }
""",
)

text = replace_once(
    text,
    """        if (offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY) {
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
""",
    "",
)

text = replace_once(
    text,
    """        BossTypes.ResourceRef memory resourceRef = _resourceBySubscription[subscriptionId];
        BossTypes.ResourceStatus memory resource = IBossResourceAdapter(subscription.resourceAdapter).inspect(
            resourceRef, payer, _resourceDataBySubscription[subscriptionId]
        );
""",
    """        CapacityState storage capacity = _capacityBySubscription[subscriptionId];
        BossTypes.ResourceStatus memory resource = IBossResourceAdapter(subscription.resourceAdapter).inspect(
            capacity.resource, payer, bytes("")
        );
""",
)

text = replace_once(
    text,
    """        uint64 validThrough = _capacityValidThrough(
            quoteEpoch, _capacityQuoteTtlEpochs[subscriptionId], subscription.caps.notAfterEpoch, quote.billable
        );
""",
    """        uint64 validThrough =
            _capacityValidThrough(quoteEpoch, capacity.quoteTtlEpochs, subscription.caps.notAfterEpoch, quote.billable);
""",
)

text = replace_once(
    text,
    """        _capacityQuoteEpoch[subscriptionId] = quoteEpoch;
        _capacityResourceStatusHash[subscriptionId] = resource.statusHash;
        _capacityQuoteHash[subscriptionId] = quote.quoteHash;

        emit RateSynchronized(
            subscriptionId, oldRate, quote.ratePerEpoch, quoteEpoch, validThrough, resource.statusHash, quote.quoteHash
        );
""",
    """        capacity.quoteEpoch = quoteEpoch;
        capacity.resourceStatusHash = resource.statusHash;

        emit RateSynchronized(subscriptionId, oldRate, quote.ratePerEpoch, validThrough);
""",
)

text = replace_once(
    text,
    """    function capacityQuoteState(bytes32 subscriptionId)
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
""",
    """    function capacityQuoteState(bytes32 subscriptionId)
        external
        view
        returns (uint64 quoteEpoch, bytes32 resourceStatusHash)
    {
        BossTypes.Subscription storage subscription = _requireSubscription(subscriptionId);
        if (subscription.billingKind != BossTypes.BillingKind.STREAM_CAPACITY) {
            revert InvalidState(subscriptionId, subscription.state);
        }
        CapacityState storage capacity = _capacityBySubscription[subscriptionId];
        return (capacity.quoteEpoch, capacity.resourceStatusHash);
    }
""",
)

account.write_text(text)

integration = Path("test/integration/PDPCapacityLifecycle.t.sol")
text = integration.read_text()
text = replace_once(
    text,
    'import {IFilecoinPayV1} from "../../src/interfaces/IFilecoinPayV1.sol";\n',
    "",
)
text = replace_once(
    text,
    """        (uint64 quoteEpoch, bytes32 resourceStateHash, bytes32 quoteHash) =
            account.capacityQuoteState(subscriptionId);
        require(quoteEpoch == 105, "quote epoch");
        require(resourceStateHash != bytes32(0), "resource state hash");
        require(quoteHash != bytes32(0), "quote hash");
""",
    """        (uint64 quoteEpoch, bytes32 resourceStateHash) = account.capacityQuoteState(subscriptionId);
        require(quoteEpoch == 105, "quote epoch");
        require(resourceStateHash != bytes32(0), "resource state hash");
""",
)
text = replace_once(
    text,
    """    function testPermissionlessSyncSettlesOldRateBeforeProspectiveIncrease() public {
""",
    """    function testCapacityAccountRetainsOneKiBRuntimeMargin() public view {
        require(address(account).code.length <= 23_552, "less than 1 KiB runtime margin");
    }

    function testPermissionlessSyncSettlesOldRateBeforeProspectiveIncrease() public {
""",
)
integration.write_text(text)
