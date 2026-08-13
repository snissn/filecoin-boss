from pathlib import Path
import re

for name in ("src/BossFactory.sol", "src/BossAccount.sol"):
    path = Path(name)
    text = path.read_text()
    old = (
        "if (accountVersion != 1) revert InvalidAccountVersion();"
        if name.endswith("Factory.sol")
        else "if (accountVersion_ != 1) revert InvalidAccountVersion();"
    )
    new = (
        "if (accountVersion == 0) revert InvalidAccountVersion();"
        if name.endswith("Factory.sol")
        else "if (accountVersion_ == 0) revert InvalidAccountVersion();"
    )
    if text.count(old) != 1:
        raise SystemExit(f"unexpected version guard in {name}")
    path.write_text(text.replace(old, new))

path = Path("test/unit/BossFactory.t.sol")
text = path.read_text()
pattern = re.compile(
    r"\n    function testUnsupportedAccountVersionsFailClosed\(\) public \{.*?\n    \}\n\n    function testAnyoneMayDeployButCannotAcquireOwnerAuthority",
    re.S,
)
replacement = '''
    function testNonzeroAccountVersionChangesAddressAndIsPreserved() public {
        BossFactory factory = new BossFactory();
        bytes memory creationCode = _creationCode();
        uint64 nextVersion = VERSION + 1;

        address versionOne = factory.predictAccount(
            OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, VERSION, creationCode
        );
        address versionTwo = factory.predictAccount(
            OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, nextVersion, creationCode
        );
        require(versionOne != versionTwo, "version affects address");

        address account = factory.createAccount(
            OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, nextVersion, creationCode
        );
        require(account == versionTwo, "version-two prediction parity");
        require(BossAccount(account).accountVersion() == nextVersion, "version preserved");
    }

    function testAnyoneMayDeployButCannotAcquireOwnerAuthority'''
text, count = pattern.subn(replacement, text)
if count != 1:
    raise SystemExit("unexpected account-version test shape")
path.write_text(text)
