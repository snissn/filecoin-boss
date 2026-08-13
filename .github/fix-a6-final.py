from pathlib import Path
import re

# The adapter quotes economics only. Signed offer policy owns quote freshness.
path = Path("src/adapters/pricing/PDPCapacityAdapter.sol")
text = path.read_text()
old = "validThroughEpoch: type(uint64).max,"
if text.count(old) != 1:
    raise SystemExit("unexpected capacity adapter validity sentinel")
path.write_text(text.replace(old, "validThroughEpoch: 0,"))

path = Path("src/BossAccount.sol")
text = path.read_text()
text = text.replace(
    "    mapping(bytes32 subscriptionId => uint64 quoteEpoch) private _capacityQuoteEpoch;\n"
    "    mapping(bytes32 subscriptionId => bytes32 statusHash) private _capacityResourceStatusHash;\n"
    "    mapping(bytes32 subscriptionId => bytes32 quoteHash) private _capacityQuoteHash;\n",
    "",
)
text = text.replace(
    "            _capacityQuoteEpoch[subscriptionId] = acceptedEpoch;\n"
    "            _capacityResourceStatusHash[subscriptionId] = resource.statusHash;\n"
    "            _capacityQuoteHash[subscriptionId] = quote.quoteHash;\n",
    "",
)
text = text.replace(
    "        _capacityQuoteEpoch[subscriptionId] = quoteEpoch;\n"
    "        _capacityResourceStatusHash[subscriptionId] = resource.statusHash;\n"
    "        _capacityQuoteHash[subscriptionId] = quote.quoteHash;\n",
    "",
)
old = "quote.validThroughEpoch != type(uint64).max"
if text.count(old) != 1:
    raise SystemExit("unexpected account capacity validity sentinel")
text = text.replace(old, "quote.validThroughEpoch != 0")

state_view = re.compile(
    r"\n    function capacityQuoteState\(bytes32 subscriptionId\).*?\n    \}\n\n    function pause",
    re.S,
)
text, count = state_view.subn("\n    function pause", text)
if count != 1:
    raise SystemExit("unexpected capacityQuoteState shape")

validity = re.compile(
    r"    function _capacityValidThrough\(uint64 quoteEpoch, uint64 quoteTtlEpochs, uint64 notAfterEpoch, bool billable\)\n"
    r"        private\n"
    r"        pure\n"
    r"        returns \(uint64 validThrough\)\n"
    r"    \{\n"
    r"        if \(!billable\) return quoteEpoch;\n"
    r"        uint256 candidate = uint256\(quoteEpoch\) \+ quoteTtlEpochs;\n"
    r"        if \(quoteTtlEpochs == 0 \|\| candidate > type\(uint64\)\.max\) revert InvalidCapacityQuote\(\);\n"
    r"        validThrough = uint64\(candidate\);\n"
    r"        if \(notAfterEpoch != 0 && notAfterEpoch < validThrough\) validThrough = notAfterEpoch;\n"
    r"    \}",
)
replacement = """    function _capacityValidThrough(uint64 quoteEpoch, uint64 quoteTtlEpochs, uint64 notAfterEpoch, bool billable)
        private
        pure
        returns (uint64 validThrough)
    {
        if (!billable) return quoteEpoch;
        validThrough = quoteEpoch + quoteTtlEpochs;
        if (notAfterEpoch != 0 && notAfterEpoch < validThrough) validThrough = notAfterEpoch;
    }"""
text, count = validity.subn(replacement, text)
if count != 1:
    raise SystemExit("unexpected capacity validity helper shape")
path.write_text(text)

path = Path("test/unit/PDPCapacityAdapter.t.sol")
text = path.read_text()
if text.count("validThroughEpoch == type(uint64).max") != 2:
    raise SystemExit("unexpected adapter test sentinel count")
text = text.replace("validThroughEpoch == type(uint64).max", "validThroughEpoch == 0")
text = text.replace("adapter chose ttl", "adapter validity is not neutral")
text = text.replace("adapter chose unavailable ttl", "unavailable adapter validity is not neutral")
path.write_text(text)

path = Path("test/integration/PDPCapacityLifecycle.t.sol")
text = path.read_text()
old = '''
        (uint64 quoteEpoch, bytes32 resourceStateHash, bytes32 quoteHash) = account.capacityQuoteState(subscriptionId);
        require(quoteEpoch == 105, "quote epoch");
        require(resourceStateHash != bytes32(0), "resource state hash");
        require(quoteHash != bytes32(0), "quote hash");
'''
if text.count(old) != 1:
    raise SystemExit("unexpected duplicate capacity state assertions")
text = text.replace(old, "")

marker = "    function _input(uint256 nonce, uint256 maxRate) private returns (BossTypes.AcceptanceInput memory input) {"
if text.count(marker) != 1:
    raise SystemExit("unexpected integration helper marker")
new_tests = '''    function testSignedOfferTtlOwnsExpiryWhileAdapterQuoteIsStable() public {
        BossTypes.AcceptanceInput memory shortTtl = _input(7, type(uint256).max);
        (bytes32 shortId,) = account.acceptOffer(shortTtl);

        BossTypes.AcceptanceInput memory longTtl = _input(8, type(uint256).max);
        longTtl.offer.quoteTtlEpochs = QUOTE_TTL * 2;
        longTtl.providerSignature = _signOffer(longTtl.offer);
        (bytes32 longId,) = account.acceptOffer(longTtl);

        require(account.getSubscription(shortId).quoteValidThroughEpoch == 110, "short signed ttl");
        require(account.getSubscription(longId).quoteValidThroughEpoch == 120, "long signed ttl");
        require(shortTtl.offer.pricingDataHash == longTtl.offer.pricingDataHash, "pricing bytes changed");

        BossTypes.ResourceStatus memory resource =
            resourceAdapter.inspect(shortTtl.resource, address(this), shortTtl.resourceData);
        BossTypes.RateQuote memory shortQuote = pricingAdapter.quoteRate(resource, shortTtl.pricingData);
        BossTypes.RateQuote memory longQuote = pricingAdapter.quoteRate(resource, longTtl.pricingData);
        require(shortQuote.quoteHash == longQuote.quoteHash, "adapter quote depends on ttl");
        require(shortQuote.validThroughEpoch == 0, "adapter selected ttl");
    }

    function testBossAccountKeepsOneKiBRuntimeMargin() public view {
        require(address(account).code.length <= 23_552, "BossAccount has less than 1 KiB EIP-170 margin");
    }

'''
text = text.replace(marker, new_tests + marker)
path.write_text(text)
