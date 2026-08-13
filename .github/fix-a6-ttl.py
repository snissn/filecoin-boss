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
    "            _validateCapacityQuote(resource, quote, offer.quoteTtlEpochs);\n",
    "            _validateCapacityQuote(resource, quote);\n",
)

text = replace_once(
    text,
    """        uint64 acceptedEpoch = _epoch();
        BossTypes.CapPolicy memory caps = input.caps;
        _subscriptions[subscriptionId] = BossTypes.Subscription({
""",
    """        uint64 acceptedEpoch = _epoch();
        BossTypes.CapPolicy memory caps = input.caps;
        uint64 quoteValidThrough = offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY
            ? _capacityValidThrough(acceptedEpoch, offer.quoteTtlEpochs, caps.notAfterEpoch, quote.billable)
            : _quoteValidThrough(quote.validThroughEpoch, caps.notAfterEpoch);
        _subscriptions[subscriptionId] = BossTypes.Subscription({
""",
)

text = replace_once(
    text,
    "            quoteValidThroughEpoch: _quoteValidThrough(quote.validThroughEpoch, caps.notAfterEpoch),\n",
    "            quoteValidThroughEpoch: quoteValidThrough,\n",
)

text = replace_once(
    text,
    "                _quoteValidThrough(quote.validThroughEpoch, caps.notAfterEpoch),\n",
    "                quoteValidThrough,\n",
)

text = replace_once(
    text,
    "        _validateCapacityQuote(resource, quote, _capacityQuoteTtlEpochs[subscriptionId]);\n",
    "        _validateCapacityQuote(resource, quote);\n",
)

text = replace_once(
    text,
    """        uint64 quoteEpoch = _epoch();
        uint64 validThrough = _quoteValidThrough(quote.validThroughEpoch, subscription.caps.notAfterEpoch);
""",
    """        uint64 quoteEpoch = _epoch();
        uint64 validThrough = _capacityValidThrough(
            quoteEpoch,
            _capacityQuoteTtlEpochs[subscriptionId],
            subscription.caps.notAfterEpoch,
            quote.billable
        );
""",
)

old_helper = """    function _validateCapacityQuote(
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
                resource.payer != payer || resource.statusHash == bytes32(0) || quote.validThroughEpoch <= block.number
                    || uint256(quote.validThroughEpoch) > block.number + maximumTtlEpochs
            ) revert InvalidCapacityQuote();
        } else if (quote.ratePerEpoch != 0 || quote.validThroughEpoch != block.number) {
            revert InvalidCapacityQuote();
        }
    }

"""
new_helper = """    function _validateCapacityQuote(
        BossTypes.ResourceStatus memory resource,
        BossTypes.RateQuote memory quote
    ) private view {
        bool available = resource.exists && resource.attachable && resource.billable;
        bool unavailable = !resource.exists && !resource.attachable && !resource.billable;
        if (!available && !unavailable) revert InvalidResource();
        if (
            quote.billable != available || quote.quoteHash == bytes32(0)
                || quote.validThroughEpoch != type(uint64).max
        ) revert InvalidCapacityQuote();

        if (available) {
            if (resource.payer != payer || resource.statusHash == bytes32(0)) revert InvalidCapacityQuote();
        } else if (quote.ratePerEpoch != 0) {
            revert InvalidCapacityQuote();
        }
    }

    function _capacityValidThrough(
        uint64 quoteEpoch,
        uint64 quoteTtlEpochs,
        uint64 notAfterEpoch,
        bool billable
    ) private pure returns (uint64 validThrough) {
        if (!billable) return quoteEpoch;
        uint256 candidate = uint256(quoteEpoch) + quoteTtlEpochs;
        if (quoteTtlEpochs == 0 || candidate > type(uint64).max) revert InvalidCapacityQuote();
        validThrough = uint64(candidate);
        if (notAfterEpoch != 0 && notAfterEpoch < validThrough) validThrough = notAfterEpoch;
    }

"""
text = replace_once(text, old_helper, new_helper)
account.write_text(text)

integration = Path("test/integration/PDPCapacityLifecycle.t.sol")
text = integration.read_text()
text = replace_once(
    text,
    """            PDPCapacityAdapter.CapacityTerms({
                grossPricePerTiBPerPeriod: PRICE_PER_TIB,
                periodEpochs: PERIOD_EPOCHS,
                quoteTtlEpochs: QUOTE_TTL
            })
""",
    """            PDPCapacityAdapter.CapacityTerms({
                grossPricePerTiBPerPeriod: PRICE_PER_TIB,
                periodEpochs: PERIOD_EPOCHS
            })
""",
)
integration.write_text(text)
