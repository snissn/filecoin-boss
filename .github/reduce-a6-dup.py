from pathlib import Path


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"anchor mismatch ({count}): {old[:160]!r}")
    return text.replace(old, new)


path = Path("src/BossAccount.sol")
text = path.read_text()

settle_block = """        uint256 currentEpoch = block.number;
        (,,,, uint256 finalSettledEpoch,) = IFilecoinPayV1(filecoinPay).settleRail(subscription.railId, currentEpoch);
        if (finalSettledEpoch != currentEpoch) {
            revert RailNotCurrent(subscription.railId, currentEpoch, finalSettledEpoch);
        }
"""
text = replace_once(text, settle_block, "        _settleCurrent(subscription.railId);\n")
text = replace_once(text, settle_block, "        _settleCurrent(subscription.railId);\n")

sync_block = """        IFilecoinPayV1 pay = IFilecoinPayV1(filecoinPay);
        uint256 currentEpoch = block.number;
        (,,,, uint256 finalSettledEpoch,) = pay.settleRail(subscription.railId, currentEpoch);
        if (finalSettledEpoch != currentEpoch) {
            revert RailNotCurrent(subscription.railId, currentEpoch, finalSettledEpoch);
        }
"""
text = replace_once(
    text,
    sync_block,
    """        IFilecoinPayV1 pay = IFilecoinPayV1(filecoinPay);
        _settleCurrent(subscription.railId);
""",
)

note = """            note: subscription.billingKind == BossTypes.BillingKind.STREAM_CAPACITY
                ? "FILECOIN_BOSS_CAPACITY_V1"
                : "FILECOIN_BOSS_FLAT_V1"
"""
text = replace_once(text, note, '            note: "FILECOIN_BOSS_STREAM_V1"\n')

anchor = """    function validatePayment(uint256 railId, uint256 proposedAmount, uint256 fromEpoch, uint256 toEpoch, uint256 rate)
"""
helper = """    function _settleCurrent(uint256 railId) private {
        uint256 currentEpoch = block.number;
        (,,,, uint256 finalSettledEpoch,) = IFilecoinPayV1(filecoinPay).settleRail(railId, currentEpoch);
        if (finalSettledEpoch != currentEpoch) revert RailNotCurrent(railId, currentEpoch, finalSettledEpoch);
    }

"""
text = replace_once(text, anchor, helper + anchor)
path.write_text(text)

integration = Path("test/integration/PDPCapacityLifecycle.t.sol")
text = integration.read_text()
text = text.replace('import {IFilecoinPayV1} from "../../src/interfaces/IFilecoinPayV1.sol";\n', "")
integration.write_text(text)
