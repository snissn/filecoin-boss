from pathlib import Path


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected one replacement anchor, found {count}: {old[:100]!r}")
    return text.replace(old, new)


path = Path("src/BossAccount.sol")
text = path.read_text()

text = replace_once(
    text,
    "    error InvalidSettlementRange(uint256 fromEpoch, uint256 toEpoch);\n",
    "    error InvalidSettlementRange(uint256 fromEpoch, uint256 toEpoch);\n"
    "    error InvalidReporter();\n"
    "    error InvalidUsageClaim();\n"
    "    error UsageClaimAlreadyConsumed(bytes32 claimId);\n"
    "    error UsageNonceAlreadyConsumed(uint256 nonce);\n"
    "    error UsageWindowMismatch(uint256 startWindow, uint256 endWindow);\n"
    "    error FixedBudgetOutOfSync(uint256 expected, uint256 observed);\n"
    "    error InvalidTopUp(uint256 currentBudget, uint256 requestedBudget);\n",
)

text = replace_once(
    text,
    "    event AccessGrantCommitted(bytes32 indexed subscriptionId, bytes32 accessGrantHash);\n",
    "    event AccessGrantCommitted(bytes32 indexed subscriptionId, bytes32 accessGrantHash);\n"
    "    event UsageClaimCharged(\n"
    "        bytes32 indexed subscriptionId,\n"
    "        bytes32 indexed claimId,\n"
    "        uint256 units,\n"
    "        uint256 rawGross,\n"
    "        uint256 chargedGross,\n"
    "        bytes32 evidenceHash\n"
    "    );\n"
    "    event FixedBudgetToppedUp(bytes32 indexed subscriptionId, uint256 oldBudget, uint256 newBudget);\n",
)

text = replace_once(
    text,
    "    mapping(bytes32 subscriptionId => bool acknowledged) private _activationAcknowledged;\n",
    "    mapping(bytes32 subscriptionId => bool acknowledged) private _activationAcknowledged;\n"
    "    mapping(bytes32 subscriptionId => bytes pricingData) private _pricingDataBySubscription;\n"
    "    mapping(bytes32 subscriptionId => mapping(bytes32 claimId => bool consumed)) private _consumedClaims;\n"
    "    mapping(bytes32 subscriptionId => mapping(uint256 nonce => bool consumed)) private _consumedUsageNonces;\n"
    "    mapping(bytes32 subscriptionId => mapping(uint256 window => uint256 gross)) private _usageGrossByWindow;\n",
)

text = replace_once(
    text,
    "        _offerSigningKey[subscriptionId] = offer.signingKey;\n",
    "        _offerSigningKey[subscriptionId] = offer.signingKey;\n"
    "        _pricingDataBySubscription[subscriptionId] = input.pricingData;\n",
)

metered_functions = r'''    function submitUsageClaim(
        bytes32 subscriptionId,
        BossTypes.UsageClaim calldata claim,
        bytes calldata reporterSignature
    ) external returns (uint256 chargedGross) {
        BossTypes.Subscription storage subscription = _requireSubscription(subscriptionId);
        if (
            subscription.billingKind != BossTypes.BillingKind.METERED_FIXED_LOCKUP
                || subscription.state != BossTypes.SubscriptionState.ACTIVE
        ) revert InvalidState(subscriptionId, subscription.state);
        _requireNotExpired(subscription);

        if (
            claim.claimId == bytes32(0) || claim.toEpoch <= claim.fromEpoch || claim.toEpoch > block.number
                || claim.fromEpoch < subscription.acceptedEpoch || claim.fromEpoch < subscription.lastUsageToEpoch
        ) revert InvalidUsageClaim();
        if (_consumedClaims[subscriptionId][claim.claimId]) {
            revert UsageClaimAlreadyConsumed(claim.claimId);
        }
        if (_consumedUsageNonces[subscriptionId][claim.nonce]) {
            revert UsageNonceAlreadyConsumed(claim.nonce);
        }

        uint256 windowSize = subscription.caps.chargeWindowEpochs;
        uint256 startWindow = (uint256(claim.fromEpoch) - subscription.acceptedEpoch) / windowSize;
        uint256 endWindow = (uint256(claim.toEpoch) - 1 - subscription.acceptedEpoch) / windowSize;
        if (startWindow != endWindow) revert UsageWindowMismatch(startWindow, endWindow);

        bytes32 claimHash = BossHashes.hashUsageClaim(subscriptionId, claim);
        bytes32 digest = BossHashes.hashTypedData(BossHashes.domainSeparator(block.chainid, address(this)), claimHash);
        if (!_isValidSignature(subscription.reporter, digest, reporterSignature)) revert InvalidReporter();

        uint256 rawGross = IBossPricingAdapter(subscription.pricingAdapter).quoteUsage(
            claim.units, _pricingDataBySubscription[subscriptionId]
        );
        IFilecoinPayV1.RailView memory rail = IFilecoinPayV1(filecoinPay).getRail(subscription.railId);
        if (rail.lockupFixed != subscription.currentFixedBudget) {
            revert FixedBudgetOutOfSync(subscription.currentFixedBudget, rail.lockupFixed);
        }

        chargedGross = _min(rawGross, subscription.caps.maxSingleCharge);
        chargedGross = _min(
            chargedGross,
            BossTypes.remainingCap(
                subscription.caps.maxChargePerWindow, _usageGrossByWindow[subscriptionId][startWindow]
            )
        );
        chargedGross = _min(chargedGross, _remainingLifetime(subscription));
        chargedGross = _min(chargedGross, rail.lockupFixed);

        _consumedClaims[subscriptionId][claim.claimId] = true;
        _consumedUsageNonces[subscriptionId][claim.nonce] = true;
        _usageGrossByWindow[subscriptionId][startWindow] += chargedGross;
        subscription.oneTimeChargedGross += chargedGross;
        subscription.currentFixedBudget = rail.lockupFixed - chargedGross;
        subscription.lastUsageToEpoch = claim.toEpoch;

        if (subscription.currentFixedBudget == 0 || _remainingLifetime(subscription) == 0) {
            subscription.state = BossTypes.SubscriptionState.EXHAUSTED;
        }

        if (chargedGross != 0) {
            IFilecoinPayV1(filecoinPay).modifyRailPayment(subscription.railId, 0, chargedGross);
        }
        emit UsageClaimCharged(
            subscriptionId, claim.claimId, claim.units, rawGross, chargedGross, claim.evidenceHash
        );
    }

    function topUpFixedBudget(bytes32 subscriptionId, uint256 newFixedBudget) external onlyOwner {
        BossTypes.Subscription storage subscription = _requireSubscription(subscriptionId);
        if (
            subscription.billingKind != BossTypes.BillingKind.METERED_FIXED_LOCKUP
                || subscription.state == BossTypes.SubscriptionState.TERMINATING
                || subscription.state == BossTypes.SubscriptionState.ENDED
        ) revert InvalidState(subscriptionId, subscription.state);
        _requireNotExpired(subscription);

        uint256 oldBudget = subscription.currentFixedBudget;
        if (
            newFixedBudget <= oldBudget || newFixedBudget > subscription.caps.maxFixedLockup
                || _remainingLifetime(subscription) == 0
        ) revert InvalidTopUp(oldBudget, newFixedBudget);

        IFilecoinPayV1 pay = IFilecoinPayV1(filecoinPay);
        IFilecoinPayV1.RailView memory rail = pay.getRail(subscription.railId);
        if (rail.lockupFixed != oldBudget) revert FixedBudgetOutOfSync(oldBudget, rail.lockupFixed);

        pay.modifyRailLockup(subscription.railId, rail.lockupPeriod, newFixedBudget);
        subscription.currentFixedBudget = newFixedBudget;
        if (subscription.state == BossTypes.SubscriptionState.EXHAUSTED) {
            subscription.state = BossTypes.SubscriptionState.ACTIVE;
        }
        emit FixedBudgetToppedUp(subscriptionId, oldBudget, newFixedBudget);
    }

'''
text = replace_once(text, "    function getSubscription(bytes32 subscriptionId)\n", metered_functions + "    function getSubscription(bytes32 subscriptionId)\n")

text = replace_once(
    text,
    "        if (offer.billingKind != BossTypes.BillingKind.STREAM_FLAT) revert UnsupportedBillingKind();\n",
    "        bool isMetered = offer.billingKind == BossTypes.BillingKind.METERED_FIXED_LOCKUP;\n"
    "        if (offer.billingKind != BossTypes.BillingKind.STREAM_FLAT && !isMetered) {\n"
    "            revert UnsupportedBillingKind();\n"
    "        }\n"
    "        if (\n"
    "            isMetered\n"
    "                && (offer.reporter == address(0)\n"
    "                    || offer.assuranceKind != BossTypes.AssuranceKind.TRUSTED_METERING)\n"
    "        ) revert InvalidOffer();\n",
)

old_caps = r'''    function _validateCaps(
        BossTypes.ServiceOffer calldata offer,
        BossTypes.CapPolicy calldata caps,
        uint256 ratePerEpoch,
        uint256 initialFixedBudget
    ) private view {
        if (
            caps.maxRatePerEpoch > offer.providerMaxRatePerEpoch || ratePerEpoch > caps.maxRatePerEpoch
                || ratePerEpoch > offer.providerMaxRatePerEpoch || caps.maxFixedLockup > offer.providerMaxFixedLockup
                || initialFixedBudget > caps.maxFixedLockup || initialFixedBudget > offer.providerMaxFixedLockup
                || offer.requiredLockupPeriod > caps.maxLockupPeriod || caps.chargeWindowEpochs != 0
        ) revert InvalidCaps();
        if (caps.notAfterEpoch != 0 && block.number >= caps.notAfterEpoch) revert InvalidCaps();
    }
'''
new_caps = r'''    function _validateCaps(
        BossTypes.ServiceOffer calldata offer,
        BossTypes.CapPolicy calldata caps,
        uint256 ratePerEpoch,
        uint256 initialFixedBudget
    ) private view {
        if (
            caps.maxRatePerEpoch > offer.providerMaxRatePerEpoch || ratePerEpoch > caps.maxRatePerEpoch
                || ratePerEpoch > offer.providerMaxRatePerEpoch || caps.maxFixedLockup > offer.providerMaxFixedLockup
                || initialFixedBudget > caps.maxFixedLockup || initialFixedBudget > offer.providerMaxFixedLockup
                || offer.requiredLockupPeriod > caps.maxLockupPeriod
        ) revert InvalidCaps();
        if (caps.notAfterEpoch != 0 && block.number >= caps.notAfterEpoch) revert InvalidCaps();

        if (offer.billingKind == BossTypes.BillingKind.STREAM_FLAT) {
            if (caps.chargeWindowEpochs != 0) revert InvalidCaps();
            return;
        }
        if (
            ratePerEpoch != 0 || caps.maxRatePerEpoch != 0 || offer.providerMaxRatePerEpoch != 0
                || initialFixedBudget == 0 || caps.maxSingleCharge == 0 || caps.maxChargePerWindow == 0
                || caps.lifetimeCapGross == 0 || caps.chargeWindowEpochs == 0
        ) revert InvalidCaps();
    }
'''
text = replace_once(text, old_caps, new_caps)

text = replace_once(
    text,
    "            uint256 remaining = BossTypes.remainingCap(subscription.caps.lifetimeCapGross, subscription.settledGross);\n",
    "            uint256 remaining = _remainingLifetime(subscription);\n",
)
text = replace_once(
    text,
    "                    && subscription.settledGross >= subscription.caps.lifetimeCapGross\n",
    "                    && _remainingLifetime(subscription) == 0\n",
)

helpers = r'''    function _remainingLifetime(BossTypes.Subscription storage subscription) private view returns (uint256) {
        return BossTypes.remainingCap(
            subscription.caps.lifetimeCapGross,
            subscription.settledGross + subscription.oneTimeChargedGross
        );
    }

    function _min(uint256 left, uint256 right) private pure returns (uint256) {
        return left < right ? left : right;
    }

'''
text = replace_once(
    text,
    "    function _quoteValidThrough(uint64 quoteValidThroughEpoch, uint64 notAfterEpoch) private pure returns (uint64) {\n",
    helpers + "    function _quoteValidThrough(uint64 quoteValidThroughEpoch, uint64 notAfterEpoch) private pure returns (uint64) {\n",
)

path.write_text(text)

adapter_test = Path("test/unit/CappedMeteredAdapter.t.sol")
text = adapter_test.read_text()
text = text.replace(
    "function testQuotesZeroStreamingRateAndExactUsageFloor() public view",
    "function testQuotesZeroStreamingRateAndExactUsageFloor() public",
)
text = text.replace(
    "function testFullPrecisionUsageDoesNotOverflowIntermediateProduct() public view",
    "function testFullPrecisionUsageDoesNotOverflowIntermediateProduct() public",
)
adapter_test.write_text(text)

claims = Path("test/unit/BossUsageClaims.t.sol")
text = claims.read_text()
rolls = {
    "    function testClaimsAreBoundedBySingleWindowLifetimeAndBudgetCaps() public {\n": "    function testClaimsAreBoundedBySingleWindowLifetimeAndBudgetCaps() public {\n        vm.roll(250);\n",
    "    function testReplayOverlapWrongReporterFutureAndCrossWindowClaimsFailClosed() public {\n": "    function testReplayOverlapWrongReporterFutureAndCrossWindowClaimsFailClosed() public {\n        vm.roll(250);\n",
    "    function testZeroByteClaimIsConsumedWithoutPayment() public {\n": "    function testZeroByteClaimIsConsumedWithoutPayment() public {\n        vm.roll(120);\n",
    "    function testOnlyOwnerCanTopUpAndTopUpCannotExceedAcceptedCap() public {\n": "    function testOnlyOwnerCanTopUpAndTopUpCannotExceedAcceptedCap() public {\n        vm.roll(120);\n",
}
for old, new in rolls.items():
    text = replace_once(text, old, new)
claims.write_text(text)

exact = Path("test/integration/FilecoinPayV1OneTimePayment.t.sol")
text = exact.read_text()
text = replace_once(
    text,
    "        BossTypes.UsageClaim memory claim = BossTypes.UsageClaim({\n",
    "        vm.roll(110);\n        BossTypes.UsageClaim memory claim = BossTypes.UsageClaim({\n",
)
exact.write_text(text)
