from pathlib import Path


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"anchor mismatch ({count}): {old[:160]!r}")
    return text.replace(old, new)


path = Path("src/BossAccount.sol")
text = path.read_text()
if text.count("function _settleCurrent(uint256 railId) private") != 1:
    raise SystemExit("shared settlement helper missing")
note = """            note: subscription.billingKind == BossTypes.BillingKind.STREAM_CAPACITY
                ? "FILECOIN_BOSS_CAPACITY_V1"
                : "FILECOIN_BOSS_FLAT_V1"
"""
text = replace_once(text, note, '            note: "FILECOIN_BOSS_STREAM_V1"\n')
path.write_text(text)

integration = Path("test/integration/PDPCapacityLifecycle.t.sol")
text = integration.read_text()
text = text.replace('import {IFilecoinPayV1} from "../../src/interfaces/IFilecoinPayV1.sol";\n', "")
integration.write_text(text)
