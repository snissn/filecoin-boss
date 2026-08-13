from pathlib import Path

path = Path("src/BossAccount.sol")
text = path.read_text()

old = '''    function _capacityValidThrough(uint64 quoteEpoch, uint64 quoteTtlEpochs, uint64 notAfterEpoch, bool billable)
        private
        pure
        returns (uint64 validThrough)
    {
        if (!billable) return quoteEpoch;
        validThrough = quoteEpoch + quoteTtlEpochs;
        if (notAfterEpoch != 0 && notAfterEpoch < validThrough) validThrough = notAfterEpoch;
    }
'''
new = '''    function _capacityValidThrough(uint64 quoteEpoch, uint64 quoteTtlEpochs, uint64 notAfterEpoch, bool billable)
        private
        pure
        returns (uint64)
    {
        return billable ? _quoteValidThrough(quoteEpoch + quoteTtlEpochs, notAfterEpoch) : quoteEpoch;
    }
'''
if text.count(old) != 1:
    raise SystemExit("unexpected capacity-validity helper")
text = text.replace(old, new)

old = '''        if (
            subscription.billingKind == BossTypes.BillingKind.STREAM_CAPACITY
                && (subscription.quoteValidThroughEpoch == 0 || block.number >= subscription.quoteValidThroughEpoch)
        ) revert InvalidCapacityQuote();
'''
new = '''        if (
            subscription.billingKind == BossTypes.BillingKind.STREAM_CAPACITY
                && block.number >= subscription.quoteValidThroughEpoch
        ) revert InvalidCapacityQuote();
'''
if text.count(old) != 1:
    raise SystemExit("unexpected current-capacity-quote guard")
path.write_text(text.replace(old, new))
