from pathlib import Path
import re

for name in ("src/BossFactory.sol", "src/BossAccount.sol"):
    path = Path(name)
    text = path.read_text()
    old = (
        "if (accountVersion == 0) revert InvalidAccountVersion();"
        if name.endswith("Factory.sol")
        else "if (accountVersion_ == 0) revert InvalidAccountVersion();"
    )
    new = (
        "if (accountVersion != 1) revert InvalidAccountVersion();"
        if name.endswith("Factory.sol")
        else "if (accountVersion_ != 1) revert InvalidAccountVersion();"
    )
    if text.count(old) != 1:
        raise SystemExit(f"unexpected version guard in {name}")
    path.write_text(text.replace(old, new))

path = Path("test/unit/BossFactory.t.sol")
text = path.read_text()
pattern = re.compile(
    r"\n    function testNonzeroAccountVersionChangesAddressAndIsPreserved\(\) public \{.*?\n    \}\n\n    function testAnyoneMayDeployButCannotAcquireOwnerAuthority",
    re.S,
)
replacement = '''
    function testUnsupportedAccountVersionsFailClosed() public {
        BossFactory factory = new BossFactory();
        FactoryActor caller = new FactoryActor();
        bytes memory creationCode = _creationCode();
        uint64 unsupportedVersion = VERSION + 1;

        _mustFail(
            caller,
            address(factory),
            abi.encodeCall(
                BossFactory.accountKey,
                (OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, unsupportedVersion)
            )
        );
        _mustFail(
            caller,
            address(factory),
            abi.encodeCall(
                BossFactory.predictAccount,
                (OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, unsupportedVersion, creationCode)
            )
        );
        _mustFail(
            caller,
            address(factory),
            abi.encodeCall(
                BossFactory.createAccount,
                (OWNER, FILECOIN_PAY, SERVICE_REGISTRY, ADAPTER_REGISTRY, unsupportedVersion, creationCode)
            )
        );

        try new BossAccount(
            OWNER,
            FILECOIN_PAY,
            SERVICE_REGISTRY,
            ADAPTER_REGISTRY,
            unsupportedVersion
        ) returns (BossAccount) {
            revert("unsupported account version deployed");
        } catch {}
    }

    function testAnyoneMayDeployButCannotAcquireOwnerAuthority'''
text, count = pattern.subn(replacement, text)
if count != 1:
    raise SystemExit("unexpected account-version test shape")
path.write_text(text)
