# Filecoin Boss
## Human-facing product and architecture summary

**Status:** Draft for product and engineering review  
**Version:** 0.2  
**Date:** 2026-08-12

---

## What Filecoin Boss is

Filecoin Boss is a proposed service-composition layer for Filecoin Onchain Cloud.

A user already has a PDP-backed storage resource and an associated Filecoin Pay storage rail. Boss lets that user attach independently priced services to the same resource without giving up control of the data and without forcing every service into the Filecoin Warm Storage Service contract.

Examples include:

- managed storage operations;
- indexing;
- repair coordination;
- monitoring;
- access control;
- content delivery or retrieval;
- other services that can be priced per resource, per unit of stored data, or per unit of usage.

The key product idea is simple:

> The storage resource remains the user's resource. Each service is a separately accepted commercial relationship, with a separately bounded payment rail.

Boss uses Filecoin Pay rather than replacing it. Filecoin Pay remains the payment ledger. PDP remains the source of verifiable storage state. FWSS remains the current storage product. Boss adds the missing layer that explains what an add-on rail is paying for, what resource it covers, who receives the money, what limits the user accepted, and how the user exits.

---

## Why it is needed

The present FWSS product combines a specific storage service, a specific pricing model, proof-linked payment validation, provider lifecycle behavior, and selected optional features.

That is appropriate for a standardized storage product, but it becomes restrictive when another organization wants to offer a differentiated product without forking FWSS.

The immediate example is Filone:

- current FWSS storage is quoted using the shared FWSS price schedule;
- Filone wants to sell a higher-priced managed product using the same PDP and Filecoin Pay infrastructure;
- Filone should not need an FWSS fork merely to choose its commercial price or add a distinct service obligation.

The same problem appears for indexing, CDN, repair, monitoring, and future services. Embedding each one into FWSS would make the storage contract the owner of every product and every pricing rule. Boss instead makes services composable around a neutral storage resource.

---

## The user experience

A storefront can show one coherent product:

```text
Filone Managed Storage
Storage and PDP verification             2.50 USDFC/TiB/month
Filone managed service                   2.49 USDFC/TiB/month
Estimated total                          4.99 USDFC/TiB/month
```

Before accepting, the user sees:

- the underlying PDP resource;
- every service component;
- every final payment recipient;
- the pricing rule;
- the maximum rate or prepaid budget;
- the lockup and termination tail;
- whether the service has objective on-chain verification;
- whether the service needs access to the data;
- whether the service depends on PDP remaining healthy.

The user accepts the components and caps. Boss then creates separate Filecoin Pay rails for the add-on services. The existing FWSS storage rail is unchanged.

A branded storefront can still provide a unified checkout and status page. The economic components remain visible and independently terminable.

---

## Who controls what

The authority model is intentionally explicit.

| Object or authority | Controller |
|---|---|
| PDP dataset operational role | Existing PDP/FWSS participants |
| Base storage rail | Existing FWSS contract |
| Boss bundle | User |
| Boss add-on rail | User-owned Boss account |
| Commercial offer | Service provider |
| Payment beneficiary | Fixed in the accepted offer |
| Spending cap | User |
| Service runtime | Service provider |
| Data-access capability | User, granted separately |
| Storefront presentation | Storefront operator |

A service provider does not gain ownership of the data or the bundle merely because the service is attached.

A storefront does not gain authority to change an accepted price, beneficiary, or spending cap.

Paying for a service does not itself grant plaintext access, encryption keys, deletion rights, or unrestricted retrieval credentials.

---

## Payment models

Boss supports three initial payment models.

### Flat charge per resource

Example:

```text
1 USDFC per PDP dataset per 30-day period
```

This is represented as a streaming Filecoin Pay rail at the corresponding per-epoch rate.

“Per deal” is defined precisely for the first release as “per accepted PDP dataset subscription.” A resource-set version can follow later.

### Charge per stored capacity

Example:

```text
1 USDFC per TiB per 30-day period
```

A deterministic adapter reads the current PDP dataset size and computes the rate. Anyone may call the synchronization method. This prevents the provider from being the sole source of the billed capacity.

The first version is prospective rather than historically perfect:

- a synchronization records the current size and updates the rate for future epochs;
- the quote has a bounded validity period, proposed as one day;
- a permissionless reconciler refreshes it;
- payment after an expired quote is zero until a fresh quote is applied.

This creates a bounded, explicit approximation instead of falsely claiming that a contract can reconstruct every historical capacity change from current state.

### Capped metered usage

Example:

```text
7 USDFC per TiB of egress
10 USDFC prepaid maximum
2 USDFC maximum single charge
4-day reporting windows
automatic top-up disabled
```

The first version does not claim trustless bandwidth measurement. A designated reporter submits usage. Boss calculates the charge and enforces the user's fixed-lockup budget, per-claim cap, window cap, expiry, and lifetime cap.

A malicious reporter may be able to consume the amount the user explicitly authorized. It cannot exceed that amount.

Later versions can add delayed claims, evidence commitments, bonds, attestors, and disputes before payment becomes final.

---

## Service assurance is disclosed, not implied

Every offer declares one assurance class.

| Class | User-facing meaning |
|---|---|
| `CANCELLABLE_ONLY` | No objective on-chain proof of service; exposure is bounded and the user can exit |
| `ONCHAIN_DETERMINISTIC` | Payment follows observable on-chain state |
| `TRUSTED_METERING` | A named reporter measures usage, subject to hard caps |
| `ATTESTED` | One or more recognized attestors sign service results |
| `DISPUTABLE` | Claims wait through a challenge period and may be reduced or rejected |

The UI must not label a service “verified” merely because its payment rail is on-chain.

---

## Failure behavior

### The Filecoin Pay account runs low

Filecoin Pay calculates solvency across all active rails for the payer and token. Storage and add-on rails therefore share one financial runway unless the user deliberately uses separate payer accounts.

Boss shows both:

- account-wide runway;
- service-specific rate, cap, lockup, and exposure.

Metered services stop when their prepaid quota is exhausted. Streaming services follow their own suspension policy.

### One add-on degrades

That service can become degraded, paused, or terminated without terminating the PDP dataset or other services.

### PDP degrades

The existing FWSS validator continues to determine storage payment. Each add-on declares whether it:

- continues independently;
- stops new work but may continue cached work;
- becomes non-billable or terminates.

### The account is underfunded and the user wants to leave

The user calls the user-owned Boss account. The Boss account calls Filecoin Pay as the rail operator, avoiding the funding condition that applies to a direct payer termination in Filecoin Pay V1.

### A pause cannot update the Filecoin Pay rate

Filecoin Pay V1 may reject even a rate reduction on an underfunded active rail. Boss therefore makes pause effective in its validator immediately and attempts to set the rail rate to zero. If the rate update fails, the UI warns that the account-level lockup accounting still reflects the old rate and offers termination as the reliable release path.

---

## What changes in the software ecosystem

The proposed MVP changes four codebases and introduces one new one.

### New: `FilOzone/filecoin-boss`

This repository owns:

- Boss smart contracts;
- signed-offer and resource interfaces;
- pricing adapters;
- deployment manifests and generated ABIs;
- a Boss-specific subgraph;
- the Filone reference storefront;
- protocol specification, ADRs, threat model, and audit artifacts.

### `FilOzone/synapse-sdk`

Adds:

- low-level Boss contract helpers in `@filoz/synapse-core/boss`;
- high-level `synapse.services`;
- quoting, funding planning, acceptance, synchronization, termination, top-up, and reconciliation;
- generated Boss ABIs and deployment addresses.

### `filecoin-project/filecoin-pin`

Adds:

```text
filecoin-pin services catalog
filecoin-pin services quote
filecoin-pin services add
filecoin-pin services list
filecoin-pin services sync
filecoin-pin services pause
filecoin-pin services stop
filecoin-pin services top-up
filecoin-pin services claims
```

### `FilOzone/filecoin-pay-explorer`

Adds:

- Boss service identity alongside generic Filecoin Pay rails;
- resource, bundle, subscription, cap, usage-claim, and recipient views;
- a second Boss subgraph endpoint while preserving the generic Filecoin Pay subgraph.

### No MVP runtime changes

No runtime contract changes are required in:

- `FilOzone/filecoin-pay`;
- `FilOzone/pdp`;
- `FilOzone/filecoin-services`.

Boss integrates with their current public interfaces and pins exact compatible deployments. Optional documentation and stable-view follow-ups may be added later.

Curio and Filecoin Beam also do not block the flat-rate and capacity-priced MVP. Provider-side provisioning and Beam-native metering are later integration tracks.

---

## Filone pilot recommendation

The first pilot should use a distinct Filone service component unless the product team specifically requires an exact inclusive total.

Recommended pilot:

```text
Resource:               one FWSS-backed PDP dataset
Service:                Filone Managed Storage
Billing:                capacity-priced streaming add-on
Price:                  2.49 USDFC/TiB/30 days
Assurance:              CANCELLABLE_ONLY initially
Lockup:                 explicit, preferably 0 or 1 day
Data access:             none unless an operational feature actually needs it
Payment recipient:      Filone beneficiary
Base storage:            unchanged FWSS rail
```

An exact “4.99 total” product is also possible, but requires an adapter that continuously computes the difference between the target total and the current FWSS quote, including the FWSS per-dataset component. That is a more coupled product and should not be confused with a fixed 2.49 add-on.

---

## MVP definition

The first releasable version contains:

- a deterministic user-owned Boss account;
- EIP-712 signed, immutable offers;
- one Filecoin Pay rail per add-on subscription;
- FWSS-backed PDP resource verification;
- flat and capacity pricing;
- capped trusted metering;
- owner-defined rate, budget, expiry, lockup, window, and lifetime caps;
- an operator-based user termination path;
- a Boss subgraph;
- Synapse SDK and Filecoin Pin support;
- a Filone example storefront;
- Calibration deployment and end-to-end tests.

The following are intentionally later:

- trustless bandwidth proofs;
- general arbitration;
- arbitrary bare-PDP ownership;
- automatic data-access grants;
- service migration without fresh user acceptance;
- hidden cross-service payment priority;
- automatic top-up by default.

---

## Product decisions still needed

Engineering can proceed after these product choices are recorded:

1. Is Filone selling an exact 4.99 total product or a separately priced 2.49 managed-service component?
2. What concrete obligation does Filone perform beyond base storage?
3. Does the first Filone service require any data access?
4. What termination tail does Filone require: zero, one day, or another period?
5. Is the first metered reporter fully trusted up to the cap, or must claims wait through a dispute window?
6. Should the first public release expose only protocol-approved adapters, or also clearly labeled custom adapters?

None of these questions changes the core architecture. They determine the first offer and the user-facing risk language.

---

## Reading the document set

- `FILECOIN_BOSS_SPEC_v0.2.md` — normative protocol design.
- `FILECOIN_BOSS_IMPLEMENTATION_DRAFT_v0.1.md` — repository, file, API, and pull-request plan.
- `FILECOIN_BOSS_TEST_AND_ROLLOUT_PLAN_v0.1.md` — test matrix, CI, security review, deployments, and release gates.
- `FILECOIN_BOSS_HUMAN_SUMMARY_v0.1.md` — this product-facing summary.
- `FILECOIN_BOSS_DOCUMENT_SET_INDEX.md` — source locks and navigation.
