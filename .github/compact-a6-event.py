from pathlib import Path


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"anchor mismatch ({count}): {old[:180]!r}")
    return text.replace(old, new)


account = Path("src/BossAccount.sol")
text = account.read_text()
text = replace_once(
    text,
    """    event RateSynchronized(
        bytes32 indexed subscriptionId,
        uint256 oldRate,
        uint256 newRate,
        uint64 quoteEpoch,
        uint64 validThroughEpoch,
        bytes32 resourceStatusHash,
        bytes32 quoteHash
    );
""",
    """    event RateSynchronized(
        bytes32 indexed subscriptionId,
        uint256 oldRate,
        uint256 newRate,
        uint64 quoteEpoch,
        uint64 validThroughEpoch,
        bytes32 resourceStatusHash
    );
""",
)
text = replace_once(
    text,
    """            emit RateSynchronized(
                subscriptionId,
                0,
                quote.ratePerEpoch,
                acceptedEpoch,
                quoteValidThrough,
                resource.statusHash,
                quote.quoteHash
            );
""",
    """            emit RateSynchronized(
                subscriptionId, 0, quote.ratePerEpoch, acceptedEpoch, quoteValidThrough, resource.statusHash
            );
""",
)
text = replace_once(
    text,
    """        emit RateSynchronized(
            subscriptionId, oldRate, quote.ratePerEpoch, quoteEpoch, validThrough, resource.statusHash, quote.quoteHash
        );
""",
    """        emit RateSynchronized(
            subscriptionId, oldRate, quote.ratePerEpoch, quoteEpoch, validThrough, resource.statusHash
        );
""",
)
account.write_text(text)

path = Path("test/integration/PDPCapacityLifecycle.t.sol")
text = path.read_text()
text = replace_once(
    text,
    """interface VmCapacityLifecycle {
    function prank(address sender) external;
    function roll(uint256 newHeight) external;
}
""",
    """interface VmCapacityLifecycle {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address sender) external;
    function roll(uint256 newHeight) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}
""",
)
anchor = """    function testExpiredQuoteAdvancesSettlementWithZeroUntilRefresh() public {
"""
test = """    function testRateSyncEventCarriesRequiredProvenance() public {
        (bytes32 subscriptionId,) = account.acceptOffer(_input(10, type(uint256).max));
        resourceAdapter.setSize(TIB * 2);
        BossTypes.ResourceStatus memory expected = resourceAdapter.inspect(
            BossTypes.ResourceRef({
                kind: BossTypes.ResourceKind.FWSS_PDP_DATASET,
                chainId: uint64(block.chainid),
                anchor: address(0xF00D),
                resourceId: 42,
                context: bytes32(0)
            }),
            address(this),
            bytes("")
        );

        vm.roll(105);
        vm.recordLogs();
        account.syncRate(subscriptionId);
        VmCapacityLifecycle.Log[] memory logs = vm.getRecordedLogs();
        bytes32 signature = keccak256("RateSynchronized(bytes32,uint256,uint256,uint64,uint64,bytes32)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(account) || logs[i].topics.length != 2 || logs[i].topics[0] != signature) {
                continue;
            }
            require(logs[i].topics[1] == subscriptionId, "event subscription");
            (uint256 oldRate, uint256 newRate, uint64 quoteEpoch, uint64 validThrough, bytes32 statusHash) =
                abi.decode(logs[i].data, (uint256, uint256, uint64, uint64, bytes32));
            require(oldRate == ONE_TIB_RATE, "event old rate");
            require(newRate == ONE_TIB_RATE * 2, "event new rate");
            require(quoteEpoch == 105, "event quote epoch");
            require(validThrough == 115, "event validity");
            require(statusHash == expected.statusHash, "event resource state");
            found = true;
        }
        require(found, "rate sync event missing");
    }

"""
text = replace_once(text, anchor, test + anchor)
path.write_text(text)
