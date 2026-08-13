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
    "    mapping(bytes32 subscriptionId => bytes resourceData) private _resourceDataBySubscription;\n",
    "",
)
text = replace_once(
    text,
    """            input.resource.kind != BossTypes.ResourceKind.FWSS_PDP_DATASET || input.resource.chainId != block.chainid
                || input.resource.anchor == address(0) || input.resource.context != bytes32(0)
""",
    """            input.resource.kind != BossTypes.ResourceKind.FWSS_PDP_DATASET || input.resource.chainId != block.chainid
                || input.resource.anchor == address(0) || input.resource.context != bytes32(0)
                || (offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY && input.resourceData.length != 0)
""",
)
text = replace_once(
    text,
    "            _resourceDataBySubscription[subscriptionId] = input.resourceData;\n",
    "",
)
text = replace_once(
    text,
    """        BossTypes.ResourceStatus memory resource = IBossResourceAdapter(subscription.resourceAdapter).inspect(
            resourceRef, payer, _resourceDataBySubscription[subscriptionId]
        );
""",
    """        BossTypes.ResourceStatus memory resource =
            IBossResourceAdapter(subscription.resourceAdapter).inspect(resourceRef, payer, bytes(""));
""",
)
account.write_text(text)

integration = Path("test/integration/PDPCapacityLifecycle.t.sol")
text = integration.read_text()
marker = "    function testSignedOfferTtlOwnsExpiryWhileAdapterQuoteIsStable() public {\n"
if text.count(marker) != 1:
    raise SystemExit("unexpected capacity integration marker")
new_test = '''    function testCapacityRejectsNonEmptyResourceData() public {
        BossTypes.AcceptanceInput memory input = _input(9, type(uint256).max);
        input.resourceData = hex"01";
        _mustFail(abi.encodeCall(BossAccount.acceptOffer, (input)));
    }

'''
text = text.replace(marker, new_test + marker)
integration.write_text(text)
