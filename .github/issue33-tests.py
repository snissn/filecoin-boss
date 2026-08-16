from pathlib import Path

path = Path("test/integration/PDPCapacityLifecycle.t.sol")
text = path.read_text()
anchor = """    function testCapacityRejectsNonEmptyResourceData() public {
"""
insert = """    function testCapacityAcceptsCancellableOnlyAssurance() public {
        BossTypes.AcceptanceInput memory input = _input(11, type(uint256).max);
        input.offer.assuranceKind = BossTypes.AssuranceKind.CANCELLABLE_ONLY;
        input.providerSignature = _signOffer(input.offer);

        (bytes32 subscriptionId,) = account.acceptOffer(input);
        require(
            account.getSubscription(subscriptionId).assuranceKind == BossTypes.AssuranceKind.CANCELLABLE_ONLY,
            "assurance not retained"
        );
    }

    function testCapacityStillRejectsZeroQuoteTtl() public {
        BossTypes.AcceptanceInput memory input = _input(12, type(uint256).max);
        input.offer.quoteTtlEpochs = 0;
        input.providerSignature = _signOffer(input.offer);
        _mustFail(abi.encodeCall(BossAccount.acceptOffer, (input)));
    }

""" + anchor
if text.count(anchor) != 1:
    raise SystemExit(f"expected one insertion anchor, found {text.count(anchor)}")
path.write_text(text.replace(anchor, insert))
