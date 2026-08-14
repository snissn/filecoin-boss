from pathlib import Path


path = Path("src/BossAccount.sol")
text = path.read_text()

old_mapping = (
    "    mapping(bytes32 subscriptionId => mapping(uint256 window => uint256 gross)) private _usageGrossByWindow;\n"
)
new_mapping = (
    "    mapping(bytes32 subscriptionId => mapping(uint256 window => uint256 gross)) public usageWindowGross;\n"
)
if text.count(old_mapping) != 1:
    raise SystemExit("usage window mapping anchor mismatch")
text = text.replace(old_mapping, new_mapping)

if text.count("_usageGrossByWindow[") != 3:
    raise SystemExit("usage window references anchor mismatch")
text = text.replace("_usageGrossByWindow[", "usageWindowGross[")

old_getter = """    function usageWindowGross(bytes32 subscriptionId, uint256 window) external view returns (uint256) {
        return usageWindowGross[subscriptionId][window];
    }

"""
if text.count(old_getter) != 1:
    raise SystemExit("usage window getter anchor mismatch")
text = text.replace(old_getter, "")

path.write_text(text)
