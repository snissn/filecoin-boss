from pathlib import Path


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"anchor mismatch ({count}): {old[:160]!r}")
    return text.replace(old, new)


path = Path("src/BossAccount.sol")
text = path.read_text()

block_direct = '''        uint256 currentEpoch = block.number;
        (,,,, uint256 finalSettledEpoch,) = IFilecoinPayV1(filecoinPay).settleRail(subscription.railId, currentEpoch);
        if (finalSettledEpoch != currentEpoch) {
            revert RailNotCurrent(subscription.railId, currentEpoch, finalSettledEpoch);
        }
'''
if text.count(block_direct) != 2:
    raise SystemExit(f"unexpected direct settlement block count: {text.count(block_direct)}")
text = text.replace(block_direct, "        _settleCurrent(subscription.railId);\n")

block_sync = '''        IFilecoinPayV1 pay = IFilecoinPayV1(filecoinPay);
        uint256 currentEpoch = block.number;
        (,,,, uint256 finalSettledEpoch,) = pay.settleRail(subscription.railId, currentEpoch);
        if (finalSettledEpoch != currentEpoch) {
            revert RailNotCurrent(subscription.railId, currentEpoch, finalSettledEpoch);
        }
'''
text = replace_once(
    text,
    block_sync,
    '''        IFilecoinPayV1 pay = IFilecoinPayV1(filecoinPay);
        _settleCurrent(subscription.railId);
''',
)

marker = '''    function _validateCapacityQuote(BossTypes.ResourceStatus memory resource, BossTypes.RateQuote memory quote)
'''
if text.count(marker) != 1:
    raise SystemExit("unexpected helper insertion marker")
helper = '''    function _settleCurrent(uint256 railId) private {
        uint256 currentEpoch = block.number;
        (,,,, uint256 finalSettledEpoch,) = IFilecoinPayV1(filecoinPay).settleRail(railId, currentEpoch);
        if (finalSettledEpoch != currentEpoch) revert RailNotCurrent(railId, currentEpoch, finalSettledEpoch);
    }

'''
text = text.replace(marker, helper + marker)
path.write_text(text)
