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

old_claim_start = """        _requireNotExpired(subscription);

        if (
            claim.claimId == bytes32(0) || claim.toEpoch <= claim.fromEpoch || claim.toEpoch > block.number
"""
new_claim_start = """        _requireNotExpired(subscription);

        bytes32 claimId = claim.claimId;
        uint256 claimNonce = claim.nonce;
        uint256 units = claim.units;
        if (
            claimId == bytes32(0) || claim.toEpoch <= claim.fromEpoch || claim.toEpoch > block.number
"""
if text.count(old_claim_start) != 1:
    raise SystemExit("claim local anchor mismatch")
text = text.replace(old_claim_start, new_claim_start)

old_replay = """        if (_consumedClaims[subscriptionId][claim.claimId]) {
            revert UsageClaimAlreadyConsumed(claim.claimId);
        }
        if (_consumedUsageNonces[subscriptionId][claim.nonce]) {
            revert UsageNonceAlreadyConsumed(claim.nonce);
        }
"""
new_replay = """        if (_consumedClaims[subscriptionId][claimId]) revert UsageClaimAlreadyConsumed(claimId);
        if (_consumedUsageNonces[subscriptionId][claimNonce]) revert UsageNonceAlreadyConsumed(claimNonce);
"""
if text.count(old_replay) != 1:
    raise SystemExit("claim replay anchor mismatch")
text = text.replace(old_replay, new_replay)

old_quote = """        uint256 rawGross = IBossPricingAdapter(subscription.pricingAdapter).quoteUsage(
            claim.units, _pricingDataBySubscription[subscriptionId]
        );
"""
new_quote = """        uint256 rawGross = IBossPricingAdapter(subscription.pricingAdapter).quoteUsage(
            units, _pricingDataBySubscription[subscriptionId]
        );
"""
if text.count(old_quote) != 1:
    raise SystemExit("claim units quote anchor mismatch")
text = text.replace(old_quote, new_quote)

old_consumption = """        _consumedClaims[subscriptionId][claim.claimId] = true;
        _consumedUsageNonces[subscriptionId][claim.nonce] = true;
"""
new_consumption = """        _consumedClaims[subscriptionId][claimId] = true;
        _consumedUsageNonces[subscriptionId][claimNonce] = true;
"""
if text.count(old_consumption) != 1:
    raise SystemExit("claim consumption anchor mismatch")
text = text.replace(old_consumption, new_consumption)

old_emit = """        emit UsageClaimCharged(
            subscriptionId, claim.claimId, claimHash, claim.units, rawGross, chargedGross, claim.evidenceHash
        );
"""
new_emit = """        emit UsageClaimCharged(
            subscriptionId, claimId, claimHash, units, rawGross, chargedGross, claim.evidenceHash
        );
"""
if text.count(old_emit) != 1:
    raise SystemExit("claim event local anchor mismatch")
text = text.replace(old_emit, new_emit)

path.write_text(text)
