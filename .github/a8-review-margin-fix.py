from pathlib import Path


path = Path("src/BossAccount.sol")
text = path.read_text()

constant_anchor = """    bytes32 private constant ACTIVATION_ACK_TYPEHASH =
        keccak256("ActivationAcknowledgement(bytes32 subscriptionId,bytes32 provisioningHash)");
"""
constant_replacement = constant_anchor + """    bytes32 private constant USAGE_CLAIM_CHARGED_EVENT_SIGNATURE =
        keccak256("UsageClaimCharged(bytes32,bytes32,bytes32,uint256,uint256,uint256,bytes32)");
"""
if text.count(constant_anchor) != 1:
    raise SystemExit("usage event signature anchor mismatch")
text = text.replace(constant_anchor, constant_replacement)

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
new_emit = """        bytes32 evidenceHash = claim.evidenceHash;
        bytes32 eventSignature = USAGE_CLAIM_CHARGED_EVENT_SIGNATURE;
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, claimHash)
            mstore(add(pointer, 0x20), units)
            mstore(add(pointer, 0x40), rawGross)
            mstore(add(pointer, 0x60), chargedGross)
            mstore(add(pointer, 0x80), evidenceHash)
            log3(pointer, 0xa0, eventSignature, subscriptionId, claimId)
            mstore(0x40, add(pointer, 0xa0))
        }
"""
if text.count(old_emit) != 1:
    raise SystemExit("claim event assembly anchor mismatch")
text = text.replace(old_emit, new_emit)

path.write_text(text)
