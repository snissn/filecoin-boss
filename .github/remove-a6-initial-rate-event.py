from pathlib import Path

path = Path("src/BossAccount.sol")
text = path.read_text()
old = '''        if (offer.billingKind == BossTypes.BillingKind.STREAM_CAPACITY) {
            emit RateSynchronized(
                subscriptionId, 0, quote.ratePerEpoch, acceptedEpoch, quoteValidThrough, resource.statusHash
            );
        }
'''
if text.count(old) != 1:
    raise SystemExit(f"initial rate event anchor count: {text.count(old)}")
path.write_text(text.replace(old, ""))
