from pathlib import Path

path = Path("src/BossAccount.sol")
text = path.read_text()
old = '''    function _validateCapacityQuote(BossTypes.ResourceStatus memory resource, BossTypes.RateQuote memory quote)
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
'''
new = '''    function _validateCapacityQuote(BossTypes.ResourceStatus memory resource, BossTypes.RateQuote memory quote)
        private
        view
    {
        bool available = resource.exists;
        if (
            resource.attachable != available || resource.billable != available || quote.billable != available
                || quote.quoteHash == bytes32(0) || quote.validThroughEpoch != 0
        ) revert InvalidCapacityQuote();

        if (available) {
            if (resource.payer != payer || resource.statusHash == bytes32(0)) revert InvalidCapacityQuote();
        } else if (quote.ratePerEpoch != 0) {
            revert InvalidCapacityQuote();
        }
    }
'''
if text.count(old) != 1:
    raise SystemExit("unexpected capacity quote validation shape")
path.write_text(text.replace(old, new))
