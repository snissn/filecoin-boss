from pathlib import Path


def replace_once(path: str, old: str, new: str, label: str) -> None:
    file_path = Path(path)
    text = file_path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    file_path.write_text(text.replace(old, new))


def replace_count(path: str, old: str, new: str, expected: int, label: str) -> None:
    file_path = Path(path)
    text = file_path.read_text()
    count = text.count(old)
    if count != expected:
        raise SystemExit(f"{label}: expected {expected} anchors, found {count}")
    file_path.write_text(text.replace(old, new))


replace_once(
    "src/BossAccount.sol",
    """    event UsageClaimCharged(
        bytes32 indexed subscriptionId,
        bytes32 indexed claimId,
        bytes32 claimHash,
        uint256 rawGross,
        uint256 chargedGross
    );
""",
    """    event UsageClaimCharged(
        bytes32 indexed subscriptionId,
        bytes32 indexed claimId,
        bytes32 claimHash,
        uint256 units,
        uint256 rawGross,
        uint256 chargedGross,
        bytes32 evidenceHash
    );
""",
    "production claim event",
)
replace_once(
    "src/BossAccount.sol",
    """        emit UsageClaimCharged(subscriptionId, claim.claimId, claimHash, rawGross, chargedGross);
""",
    """        emit UsageClaimCharged(
            subscriptionId, claim.claimId, claimHash, claim.units, rawGross, chargedGross, claim.evidenceHash
        );
""",
    "production claim event emission",
)
replace_once(
    "src/BossAccount.sol",
    """    function usageClaimState(bytes32 subscriptionId, bytes32 claimId, uint256 window)
        external
        view
        returns (bool claimConsumed, uint256 windowGross)
    {
        return (_consumedClaims[subscriptionId][claimId], _usageGrossByWindow[subscriptionId][window]);
    }
""",
    """    function usageWindowGross(bytes32 subscriptionId, uint256 window) external view returns (uint256) {
        return _usageGrossByWindow[subscriptionId][window];
    }
""",
    "compact authoritative window getter",
)

replace_once(
    "src/BossStateView.sol",
    """    function usageClaimState(bytes32 subscriptionId, bytes32 claimId, uint256 window)
        external
        view
        returns (bool claimConsumed, uint256 windowGross);
""",
    """    function usageWindowGross(bytes32 subscriptionId, uint256 window) external view returns (uint256);
""",
    "state-view account interface",
)
replace_once(
    "src/BossStateView.sol",
    """        bool claimConsumed;
""",
    "",
    "remove duplicate claim-observation field",
)
replace_once(
    "src/BossStateView.sol",
    """        (snapshot.claimConsumed, snapshot.windowGross) =
            account_.usageClaimState(subscriptionId, usageClaim.claimId, startWindow);
""",
    """        snapshot.windowGross = account_.usageWindowGross(subscriptionId, startWindow);
""",
    "state-view window read",
)

replace_once(
    "test/unit/BossUsageClaims.t.sol",
    """        (bool claimConsumed, uint256 windowGross) = account.usageClaimState(subscriptionId, claim.claimId, 0);
        require(claimConsumed, "claim consumption not readable");
        require(windowGross == 0, "zero claim changed window gross");
""",
    """        require(account.usageWindowGross(subscriptionId, 0) == 0, "zero claim changed window gross");
""",
    "production window getter regression",
)

replace_once(
    "test/integration/A8LifecycleReconstruction.t.sol",
    """    mapping(bytes32 subscriptionId => mapping(bytes32 claimId => bool consumed)) private _claimConsumed;
""",
    "",
    "remove fixture claim ledger",
)
replace_once(
    "test/integration/A8LifecycleReconstruction.t.sol",
    """    event UsageClaimCharged(
        bytes32 indexed subscriptionId,
        bytes32 indexed claimId,
        bytes32 claimHash,
        uint256 rawGross,
        uint256 chargedGross
    );
""",
    """    event UsageClaimCharged(
        bytes32 indexed subscriptionId,
        bytes32 indexed claimId,
        bytes32 claimHash,
        uint256 units,
        uint256 rawGross,
        uint256 chargedGross,
        bytes32 evidenceHash
    );
""",
    "fixture claim event",
)
replace_once(
    "test/integration/A8LifecycleReconstruction.t.sol",
    """    function setUsageClaimState(bytes32 subscriptionId, bytes32 claimId, uint256 window, uint256 gross) external {
        _claimConsumed[subscriptionId][claimId] = true;
        _windowGross[subscriptionId][window] = gross;
    }
""",
    """    function setUsageWindowGross(bytes32 subscriptionId, uint256 window, uint256 gross) external {
        _windowGross[subscriptionId][window] = gross;
    }
""",
    "fixture window setter",
)
replace_once(
    "test/integration/A8LifecycleReconstruction.t.sol",
    """    function usageClaimState(bytes32 subscriptionId, bytes32 claimId, uint256 window)
        external
        view
        returns (bool claimConsumed, uint256 windowGross)
    {
        return (_claimConsumed[subscriptionId][claimId], _windowGross[subscriptionId][window]);
    }
""",
    """    function usageWindowGross(bytes32 subscriptionId, uint256 window) external view returns (uint256) {
        return _windowGross[subscriptionId][window];
    }
""",
    "fixture window getter",
)
replace_once(
    "test/integration/A8LifecycleReconstruction.t.sol",
    """        emit UsageClaimCharged(
            subscriptionId, usageClaim.claimId, BossHashes.hashUsageClaim(subscriptionId, usageClaim), 7 ether, 5 ether
        );
""",
    """        emit UsageClaimCharged(
            subscriptionId,
            usageClaim.claimId,
            BossHashes.hashUsageClaim(subscriptionId, usageClaim),
            usageClaim.units,
            7 ether,
            5 ether,
            usageClaim.evidenceHash
        );
""",
    "fixture claim event emission",
)
replace_once(
    "test/integration/A8LifecycleReconstruction.t.sol",
    """        account.setUsageClaimState(METERED_ID, CLAIM_ID, 0, 5 ether);
""",
    """        account.setUsageWindowGross(METERED_ID, 0, 5 ether);
""",
    "fixture window setup",
)
replace_once(
    "test/integration/A8LifecycleReconstruction.t.sol",
    """        bytes32 usageSignature = keccak256("UsageClaimCharged(bytes32,bytes32,bytes32,uint256,uint256)");
""",
    """        bytes32 usageSignature =
            keccak256("UsageClaimCharged(bytes32,bytes32,bytes32,uint256,uint256,uint256,bytes32)");
""",
    "claim event signature",
)
replace_once(
    "test/integration/A8LifecycleReconstruction.t.sol",
    """                (bytes32 claimHash, uint256 rawGross, uint256 chargedGross) =
                    abi.decode(logs[i].data, (bytes32, uint256, uint256));
                require(claimHash == BossHashes.hashUsageClaim(METERED_ID, usageClaim), "usage claim hash");
                require(rawGross == 7 ether && chargedGross == 5 ether, "usage gross");
""",
    """                (
                    bytes32 claimHash,
                    uint256 units,
                    uint256 rawGross,
                    uint256 chargedGross,
                    bytes32 evidenceHash
                ) = abi.decode(logs[i].data, (bytes32, uint256, uint256, uint256, bytes32));
                require(claimHash == BossHashes.hashUsageClaim(METERED_ID, usageClaim), "usage claim hash");
                require(units == usageClaim.units, "usage units");
                require(rawGross == 7 ether && chargedGross == 5 ether, "usage gross");
                require(evidenceHash == usageClaim.evidenceHash, "usage evidence");
""",
    "claim event reconstruction",
)
replace_once(
    "test/integration/A8LifecycleReconstruction.t.sol",
    """        require(claimSnapshot.claimConsumed, "claim consumption");
""",
    "",
    "claim snapshot assertion",
)

replace_count(
    ".github/workflows/contract-artifacts.yml",
    """      - src/**
      - scripts/generate-contract-artifacts.sh
""",
    """      - src/**
      - foundry.toml
      - scripts/generate-contract-artifacts.sh
""",
    2,
    "Foundry artifact-drift trigger",
)
