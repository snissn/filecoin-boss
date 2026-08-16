# Filone Managed Storage reference

This directory contains the deterministic, unsigned reference package for the Filecoin Boss product `filone-managed-storage-v1`.

## Product boundary

- Price: **2.49 USDFC per TiB per 30-day period**.
- Billing: prospective `STREAM_CAPACITY` add-on pricing.
- Assurance: `CANCELLABLE_ONLY`; no objectively verified SLA is claimed.
- Payment: one separate Boss/Filecoin Pay rail to the disclosed beneficiary.
- Storage: the existing FWSS dataset and base rail remain unchanged.
- Data authority: no ownership, custody, encryption-key, or data-access grant.
- This is not an inclusive 4.99 USDFC product.

## Render an unsigned offer

Prepare a JSON configuration containing exactly:

```text
chainId
provider
signingKey
beneficiary
token
resourceAdapter
pricingAdapter
offerVersion
validAfterEpoch
validUntilEpoch
nonce
providerMaxRatePerEpoch
```

Then run:

```sh
python3 reference/filone/reference.py render \
  --config /path/to/config.json \
  --output /path/to/rendered-offer.json
```

The renderer signs and broadcasts nothing. It commits the raw `terms.md` bytes and the exact 64-byte capacity-pricing tuple using Ethereum Keccak-256 from the repository's existing Foundry `cast` tool.

## Validate evidence shape

```sh
python3 reference/filone/reference.py validate-evidence \
  --offer /path/to/rendered-offer.json \
  --evidence /path/to/evidence.json
```

A successful result means only that the bounded document is eligible for an independent verifier. It always returns:

```json
{
  "eligibleForIndependentVerification": true,
  "releaseClaimAuthorized": false,
  "requiresIndependentRpcVerification": true
}
```

The operator must independently verify chain identity, deployment manifest, transaction receipts, runtime code and constructor configuration, Boss state, Filecoin Pay rail state, unchanged base FWSS state, subgraph replay, Synapse SDK, Filecoin Pin, and Explorer observations. Do not insert provisional addresses or synthetic receipts.
