from pathlib import Path


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"anchor mismatch ({count}): {old[:160]!r}")
    return text.replace(old, new)


types = Path("src/libraries/BossTypes.sol")
text = types.read_text()
text = replace_once(
    text,
    "        uint64 quoteValidThroughEpoch;\n        uint64 pausedEpoch;\n",
    "        uint64 quoteValidThroughEpoch;\n        uint64 quoteTtlEpochs;\n        uint64 pausedEpoch;\n",
)
types.write_text(text)

account = Path("src/BossAccount.sol")
text = account.read_text()
text = replace_once(
    text,
    "    mapping(bytes32 subscriptionId => uint64 quoteTtlEpochs) private _capacityQuoteTtlEpochs;\n",
    "",
)
text = replace_once(
    text,
    "            quoteValidThroughEpoch: quoteValidThrough,\n            pausedEpoch: 0,\n",
    """            quoteValidThroughEpoch: quoteValidThrough,
            quoteTtlEpochs: offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY ? offer.quoteTtlEpochs : 0,
            pausedEpoch: 0,
""",
)
text = replace_once(
    text,
    "            _capacityQuoteTtlEpochs[subscriptionId] = offer.quoteTtlEpochs;\n",
    "",
)
text = replace_once(
    text,
    "            quoteEpoch, _capacityQuoteTtlEpochs[subscriptionId], subscription.caps.notAfterEpoch, quote.billable\n",
    "            quoteEpoch, subscription.quoteTtlEpochs, subscription.caps.notAfterEpoch, quote.billable\n",
)
account.write_text(text)

integration = Path("test/integration/PDPCapacityLifecycle.t.sol")
text = integration.read_text()
text = replace_once(
    text,
    '''        require(account.getSubscription(shortId).quoteValidThroughEpoch == 110, "short signed ttl");
        require(account.getSubscription(longId).quoteValidThroughEpoch == 120, "long signed ttl");
''',
    '''        require(account.getSubscription(shortId).quoteValidThroughEpoch == 110, "short signed ttl");
        require(account.getSubscription(longId).quoteValidThroughEpoch == 120, "long signed ttl");
        require(account.getSubscription(shortId).quoteTtlEpochs == QUOTE_TTL, "short ttl not discoverable");
        require(account.getSubscription(longId).quoteTtlEpochs == QUOTE_TTL * 2, "long ttl not discoverable");
''',
)
integration.write_text(text)
