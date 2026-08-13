# Filecoin Boss
## Test, security, deployment, and rollout plan

**Status:** Pre-implementation quality plan  
**Version:** 0.1  
**Date:** 2026-08-12  
**Companion documents:** `FILECOIN_BOSS_SPEC_v0.2.md`, `FILECOIN_BOSS_IMPLEMENTATION_DRAFT_v0.1.md`

---

## 1. Quality objective

Boss controls the creation and lifecycle of payment rails but does not custody funds. Its primary security obligation is therefore:

> No service, reporter, storefront, adapter, or stale state may cause the payer to spend more, pay longer, lock more, or pay a different beneficiary than the user explicitly accepted.

The secondary obligation is:

> A service failure must not make the user's storage resource or unrelated services unmanageable, and a Boss callback must never block the user's termination path.

The test program is organized around those two properties rather than ordinary line coverage alone.

---

## 2. Test layers

| Layer | Purpose | Primary tooling |
|---|---|---|
| Pure unit | Hashing, math, state transitions, adapter results | Foundry / TypeScript |
| Contract integration | Exact Filecoin Pay V1, PDP, and FWSS interactions | Foundry |
| Fuzz | Boundary amounts, epochs, rates, caps, signatures | Foundry fuzz |
| Stateful invariant | Long operation sequences and global safety properties | Foundry invariant |
| Fork/read compatibility | Deployed ABI and view behavior | Foundry fork / viem |
| SDK unit | Quote and funding calculations, error mapping | Playwright-test Node/browser |
| CLI unit/integration | User-visible plans and transaction sequencing | Existing Filecoin Pin tests |
| Subgraph | Deterministic event indexing | Matchstick |
| Explorer | Semantic joins and disclosure UI | Component tests / Playwright |
| Cross-repository devnet | Real end-to-end workflow | FOC devnet + scripts |
| Calibration | Deployment and operational rehearsal | Live Calibration |
| Security review | Manual and automated adversarial analysis | Slither, review, audit |

Coverage thresholds are useful regression signals, but release approval is based on required scenario and invariant completion.

---

## 3. Contract unit-test files

All paths below are proposed under `filecoin-boss/contracts/test/`.

### 3.1 Factory and account deployment

#### `unit/BossFactory.t.sol`

Tests:

- deterministic prediction equals deployed clone address;
- repeated `createAccount` is idempotent;
- different owner, Pay address, or implementation version yields a different address;
- zero owner or zero Pay address is rejected;
- implementation version cannot be overwritten;
- codehash mismatch is rejected;
- unpublished implementation version is rejected;
- factory owner cannot transfer ownership of an already deployed account;
- clone initialization cannot be replayed;
- account owner and payer are equal in MVP;
- account version 1 exposes no ownership-transfer path;
- anyone may deploy the predicted account, but only the owner can operate it;
- account stores exact registry and Filecoin Pay addresses.

Fuzz dimensions:

- owner address;
- Filecoin Pay address;
- version;
- salt collision attempts.

### 3.2 EIP-712 offers and registry

#### `unit/OfferHashing.t.sol`

Golden vectors:

- domain separator;
- offer struct hash;
- full EIP-712 digest;
- pricing-data hash;
- resource key;
- subscription ID;
- bundle manifest hash;
- usage-claim digest.

Cross-language vectors must be committed as JSON and consumed by Solidity and TypeScript tests.

#### `unit/BossServiceRegistry.t.sol`

Tests:

- provider self-registration;
- signing key activation and deactivation;
- ERC-1271 provider signer;
- offer nonce revocation;
- revocation affects new acceptance but not existing subscription;
- another address cannot modify provider records;
- service metadata updates emit versioned events;
- registry records are not interpreted as protocol endorsement.

#### `unit/OfferVerification.t.sol`

Tests:

- valid EOA signature;
- valid ERC-1271 signature;
- wrong chain;
- wrong Boss account;
- wrong provider;
- deactivated signer;
- revoked nonce;
- expired and not-yet-valid offer;
- changed beneficiary;
- changed pricing data;
- changed terms hash;
- cross-account replay;
- cross-chain replay;
- duplicate subscription acceptance.

### 3.3 Adapter registry

#### `unit/BossAdapterRegistry.t.sol`

Tests:

- register resource and pricing adapters;
- interface version and codehash stored exactly;
- inactive adapter rejected for new subscription;
- deactivation does not rewrite accepted subscription;
- adapter at a different address with identical code is still a different accepted adapter;
- codehash mismatch rejected;
- unauthorized governance action rejected;
- metadata change does not change code identity.

### 3.4 Resource adapter

#### `unit/FWSSPDPResourceAdapter.t.sol`

Tests:

- live dataset with supported FWSS listener and matching payer is attachable;
- wrong payer rejected;
- wrong PDP verifier rejected;
- wrong chain rejected;
- unsupported listener rejected;
- nonexistent or deleted dataset rejected;
- FWSS state-view read failure returns non-attachable;
- provider migration does not change payer authority;
- storage-provider address alone cannot authorize attachment;
- leaf-count conversion matches canonical formula;
- maximum practical leaf count does not overflow;
- exact status hash is stable.

Fuzz:

```text
leafCount in [0, type(uint128).max]
payer/provider/listener address combinations
dataset liveness transitions
```

### 3.5 Flat pricing

#### `unit/FlatRateAdapter.t.sol`

Tests:

- 1 USDFC / 86,400 epochs;
- zero period rejected;
- zero price produces zero rate;
- truncation remainder is deterministic;
- maximum price does not overflow;
- quote validity equals accepted expiry;
- quote remains stable across unrelated resource-size changes.

Property:

```text
rate × period <= price
price - rate × period < period
```

### 3.6 Capacity pricing

#### `unit/PDPCapacityAdapter.t.sol`

Known vectors:

| Raw capacity | Price | Expected behavior |
|---:|---:|---|
| 0 | 1 USDFC/TiB/month | zero rate / non-billable as offer policy dictates |
| 0.5 TiB | 1 USDFC/TiB/month | approximately 0.5 USDFC/month |
| 1 TiB | 1 USDFC/TiB/month | approximately 1 USDFC/month |
| 3.5 TiB | 1 USDFC/TiB/month | approximately 3.5 USDFC/month |
| 10 TiB | 1 USDFC/TiB/month | approximately 10 USDFC/month |

Tests:

- canonical `floor(leaves × 32 × 127 / 128)` conversion;
- `Math.mulDiv` result;
- quote TTL starts at current epoch;
- deleted resource is non-billable;
- rate above accepted cap causes account sync rejection;
- rate increase/decrease applies prospectively;
- quote expiry causes zero payment after validity boundary;
- refresh first settles through the current epoch under the old quote;
- refresh before expiry produces continuous billability;
- underfunded rail cannot extend quote validity;
- refresh after expiry does not retroactively charge zeroed gap;
- no historical-accuracy claim is encoded in behavior;
- provider migration leaves capacity quote valid when payer binding remains valid.

Fuzz properties:

```text
rate is monotonic in leafCount for fixed price
rate is monotonic in price for fixed leafCount
rate never exceeds mathematically exact rational value
no multiplication overflow over supported bounds
```

### 3.7 Boss account acceptance

#### `unit/BossAccountAccept.t.sol`

Tests:

- flat offer acceptance;
- capacity offer acceptance;
- metered offer acceptance;
- immediate activation;
- provider-ack activation creates zero-rate rail;
- beneficiary and commission fields match offer;
- fixed lockup and streaming lockup match quote;
- cap too low for initial rate rejected;
- lockup period above user cap rejected;
- fixed budget above user cap rejected;
- pricing-data mismatch rejected;
- unsupported resource or pricing adapter rejected;
- resource payer mismatch rejected;
- Filecoin Pay approval shortfall reverts atomically;
- insufficient Filecoin Pay funds reverts atomically;
- no orphan rail remains after revert;
- accepted offer fields cannot be changed.

### 3.8 Activation and acknowledgment

#### `unit/BossAccountActivation.t.sol`

Tests:

- valid provider acknowledgment;
- invalid provisioning signature;
- duplicate acknowledgment idempotency;
- activation before acknowledgment rejected;
- activation takes a fresh rate quote from stored immutable pricing bytes;
- activation failure leaves state pending;
- successful Pay rate modification precedes `ACTIVE` state;
- expired offer may still activate only if accepted terms permit; default is reject;
- deleted resource between acceptance and activation rejected.

### 3.9 Streaming validation

#### `unit/BossAccountValidation.t.sol`

Tests must call the account through a mock or real Filecoin Pay context.

Cases:

- unauthorized caller rejected;
- proposed amount passed through for fully billable range;
- amount never exceeds proposed;
- epochs before activation settle at zero;
- epochs after `notAfterEpoch` settle at zero;
- paused epochs settle at zero after pause boundary;
- flat service settles through accepted expiry;
- capacity service settles only through quote validity;
- termination `PAY_THROUGH_FILECOIN_PAY_END`;
- termination `ZERO_AFTER_REQUEST`;
- lifetime cap exactly exhausted;
- cap increase settles under old cap before applying;
- expiry extension settles under old expiry before applying;
- underfunded rail cannot receive prospective economic expansion;
- partial remaining cap;
- zero remaining cap;
- rate-change segment handling;
- multiple validation calls in one settlement transaction accumulate correctly;
- state rollback when outer Filecoin Pay settlement reverts;
- zero-payment intervals still advance the settlement cursor;
- malformed epoch ordering rejected without overflow.

Core properties:

```text
0 <= modifiedAmount <= proposedAmount
settleUpto <= toEpoch
settledGross + oneTimeChargedGross <= lifetimeCapGross
```

### 3.10 Pause, resume, and termination

#### `unit/BossAccountLifecycle.t.sol`

Tests:

- owner pause with funded account sets rate zero;
- pause changes validator behavior immediately;
- underfunded Pay rate change failure emits deferred event while validator pause remains effective;
- resume takes fresh quote;
- failed resume remains paused;
- pause rejected when offer disallows pause;
- owner termination as Boss operator succeeds while payer is underfunded;
- non-owner cannot terminate;
- termination idempotency;
- metered unused fixed budget best-effort reduction;
- callback records Pay end epoch;
- callback from wrong sender does nothing and does not revert;
- callback cannot reenter external code because it makes no external calls;
- adapter revert cannot block termination;
- base FWSS rail remains untouched;
- another Boss subscription remains active;
- finalization reconciliation marks `ENDED`.

A dedicated malicious callback test contract must attempt:

- recursive `terminate`;
- `syncRate`;
- registry mutation;
- ownership transfer;
- usage claim submission.

No path may change state beyond the intended callback writes.

### 3.11 Caps

#### `unit/BossCaps.t.sol`

Tests:

- provider cannot change caps;
- non-owner cannot change caps;
- exact owner increase;
- attempt to lower cap below spent amount;
- attempt to change immutable offer fields through cap call;
- not-after extension;
- rate-cap increase;
- fixed-budget cap increase;
- window-cap increase;
- lifetime-cap increase;
- zero-to-nonzero cap;
- no implicit operator-approval increase;
- SDK must still plan separate Pay approval transaction.

Whether cap reductions are supported should be explicit. Recommended MVP:

- owner may reduce unused caps if current rail state and accumulated spend remain valid;
- reduction never refunds already paid value;
- a rate reduction may be deferred by underfunded Filecoin Pay behavior;
- termination remains the reliable hard-stop path.

### 3.12 Metered usage

#### `unit/CappedMeteredAdapter.t.sol`

Tests:

- exact 1 TiB charge;
- fractional TiB;
- zero units;
- maximum units without overflow;
- pricing-data decode failures;
- minimum/maximum interval constraints.

#### `unit/BossUsageClaims.t.sol`

Tests:

- valid exact offer reporter claim;
- valid reporter EIP-712 signature;
- provider signer cannot substitute for a distinct reporter;
- wrong reporter;
- cross-subscription replay;
- duplicate claim;
- nonce replay;
- non-monotonic interval;
- overlapping interval;
- claim spanning two windows;
- claim submitted after maximum claim delay;
- gap between claims;
- raw charge below all caps;
- single-charge cap truncation;
- window-cap truncation;
- lifetime-cap truncation;
- fixed-lockup truncation;
- combination of all caps;
- zero charge when exhausted;
- Filecoin Pay one-time-payment failure rolls back claim state;
- exact gross/network-fee/provider-net accounting;
- top-up raises fixed budget but not lifetime cap;
- `initialFixedBudget` cannot exceed `maxFixedLockup`;
- claim after expiry rejected or charged zero according offer;
- terminated subscription rejects new claim;
- evidence hash and URI emitted exactly.

Core property:

```text
chargedGross =
  min(rawGross, remainingSingle, remainingWindow, remainingLifetime, railFixedLockup)
```

### 3.13 Bundles

#### `unit/BossBundle.t.sol`

Tests:

- two independent services on one resource;
- two providers and beneficiaries;
- atomic acceptance rollback if one component fails;
- maximum component count;
- duplicate offer/resource pair policy;
- bundle event manifest;
- one component pause does not affect another;
- one component termination does not affect another;
- base FWSS rail not included in Boss batch;
- provider-ack components remain independently pending.

---

## 4. Filecoin Pay V1 integration suite

Location:

```text
filecoin-boss/contracts/test/integration/
```

The suite deploys the exact source-locked Filecoin Pay V1, not a simplified mock.

### `FilecoinPayV1Acceptance.t.sol`

- Boss operator approval;
- rail creation;
- commission fields;
- lockup creation;
- initial rate;
- account-wide lockup and allowance usage.

### `FilecoinPayV1Settlement.t.sol`

- flat streaming settlement;
- multiple rate segments;
- validator amount reduction;
- zero-payment cursor advancement;
- network fee and commission;
- permissionless settlement.

### `FilecoinPayV1Underfunded.t.sol`

- account becomes underfunded;
- active rate decrease rejected;
- validator-level pause still zeroes payment;
- Boss operator termination succeeds;
- direct payer termination behavior remains distinct;
- settlement tail and finalization.

### `FilecoinPayV1OneTimePayment.t.sol`

- fixed lockup;
- one-time charge;
- lockup and allowance consumption;
- top-up prerequisites;
- repeated claims cannot recycle consumed allowance unexpectedly.

### `FilecoinPayV1TerminationCallback.t.sol`

- synchronous callback;
- callback never reverts;
- lifecycle state recorded;
- malicious adapter cannot enter callback path;
- final settlement and rail finalization.

### `FilecoinPayV1KnownBehavior.t.sol`

Regression-lock:

- aggregate operator approval;
- aggregate payer runway;
- operator approval revocation semantics;
- known lockup-usage leak behavior;
- validator note behavior;
- payer-only full-payment settlement escape after termination.

Boss documentation and SDK warnings must match these tests.

---

## 5. PDP and FWSS integration suite

Location:

```text
filecoin-boss/contracts/test/integration/
```

### `FWSSResourceBinding.t.sol`

Deploy real or source-pinned PDP/FWSS contracts and verify:

- dataset creation through FWSS;
- matching payer;
- listener resolution;
- state-view resolution;
- provider migration;
- resource deletion;
- terminated-but-not-deleted dataset policy;
- wrong FWSS deployment rejection.

### `PDPCapacityLifecycle.t.sol`

- create empty dataset;
- add pieces;
- sync Boss capacity rate;
- add more pieces and sync higher;
- schedule removal;
- retain old rate until PDP/FWSS state changes;
- finalize removal and sync lower;
- delete dataset;
- reconcile hard dependency and terminate/non-billable behavior.

### `FWSSIndependence.t.sol`

- attach Boss add-ons;
- pause/terminate add-ons;
- prove that no Boss call invokes FWSS termination;
- FWSS storage rail continues;
- PDP proofs and storage payment remain unaffected.

---

## 6. Stateful invariant suites

Location:

```text
filecoin-boss/contracts/test/invariant/
```

### 6.1 `BossSpend.invariant.t.sol`

Handler operations:

- accept;
- sync;
- settle;
- pause;
- resume;
- terminate;
- submit usage;
- top up;
- increase caps;
- change dataset size;
- advance epochs;
- underfund/refund account.

Invariants:

```text
totalGrossCharged(subscription) <= lifetimeCapGross
currentRate <= maxRatePerEpoch
currentFixedBudget <= maxFixedLockup
Pay rail beneficiary == accepted beneficiary
Pay rail token == accepted token
Pay rail operator == Boss account
Pay rail validator == Boss account
```

### 6.2 `BossAuthority.invariant.t.sol`

Adversarial actors:

- owner;
- provider;
- reporter;
- storefront;
- random attacker;
- adapter governance;
- service registry governance.

Invariants:

- only owner can increase caps or expiry;
- provider cannot change payer or accepted beneficiary;
- reporter can only submit permitted claims;
- storefront has no on-chain mutation authority;
- registry changes do not mutate accepted subscription fields;
- adapter-registry changes do not redirect accepted adapter.

### 6.3 `BossLifecycle.invariant.t.sol`

Invariants:

- `ENDED` never returns to active;
- `TERMINATING` has a termination request;
- every mapped rail belongs to exactly one subscription;
- every accepted subscription has exactly one rail;
- callback never blocks termination;
- no lifecycle operation touches a different rail;
- base FWSS rail is never called.

### 6.4 `MeteredWindows.invariant.t.sol`

Invariants:

- intervals do not overlap;
- `lastUsageToEpoch` is monotonic;
- window spend does not exceed window cap;
- claim ID charged at most once;
- fixed lockup never underflows;
- top-up never implicitly raises lifetime cap.

Foundry invariant runs should use at least:

```text
runs: 256
depth: 128
fail_on_revert: false
```

A longer nightly profile should increase runs and depth.

---

## 7. Static analysis and contract review

Required CI tools:

- `forge fmt --check`;
- `forge build --sizes`;
- `forge test`;
- `forge coverage`;
- `forge snapshot --check`;
- Slither;
- dependency/license scan;
- generated ABI drift check;
- deployment-bytecode reproducibility check.

Recommended additional analysis:

- Semgrep rules for unsafe external calls and missing access checks;
- Echidna or Medusa for the spend-cap properties if Foundry invariants do not provide sufficient path exploration;
- 4byte/function-selector collision check;
- storage-layout report for clone implementation versions;
- EIP-712 domain and typehash review.

No release should depend on a percentage-only coverage threshold. Required critical-function branch coverage should be reviewed manually for:

- `acceptOffer`;
- `validatePayment`;
- `railTerminated`;
- `syncRate`;
- `pause`;
- `terminate`;
- `submitUsageClaim`;
- `topUpFixedBudget`.

---

## 8. Synapse SDK tests

### 8.1 `synapse-core`

Tests execute under both Node and browser modes.

#### Offer and hashing

- Solidity/TypeScript golden vectors;
- checksummed and lowercase addresses;
- EOA and ERC-1271 signatures;
- chain/account domain separation;
- malformed pricing bytes;
- revoked/expired offers.

#### Resource helpers

- canonical resource key;
- FWSS dataset input validation;
- unsupported bare PDP input;
- bigint serialization;
- chain mismatch.

#### Quote

- flat rate;
- capacity rate;
- quote TTL;
- gross/net/fee breakdown;
- lockup requirement;
- cap shortfall diagnostics;
- quote stale after block/account change.

#### Funding planner

- no-op plan;
- deposit only;
- approval only;
- deposit plus approval;
- existing Boss allowance usage;
- several proposed subscriptions;
- fixed-budget top-up;
- no automatic top-up;
- Filecoin Pay V1 one-time allowance consumption.

### 8.2 High-level `ServicesManager`

Mocked RPC tests:

- resolve or deploy Boss account;
- quote;
- execute each transaction stage;
- user rejection at each stage;
- receipt failure at each stage;
- state change between quote and execution;
- partial plan completion and safe resume;
- list and reconcile;
- capacity sync;
- pause with deferred rate update;
- terminate while underfunded;
- top-up with insufficient approval;
- usage-claim display.

API tests must verify the manager never reports success before the relevant receipt is confirmed.

### 8.3 Type and bundle compatibility

- ESM import;
- browser bundle;
- tree-shaking;
- generated declaration files;
- `@filoz/synapse-core/boss` subpath export;
- public API snapshot;
- chain without Boss deployment produces typed unsupported-chain error.

---

## 9. Filecoin Pin tests

### 9.1 Unit behavior

`services quote`:

- displays all recipients;
- displays gross rate and provider net estimate;
- displays lockup and tail;
- displays assurance and dependency;
- displays cap and quote expiry;
- requires no private key for read-only quote when possible.

`services add`:

- renders transaction plan;
- interactive confirmation;
- `--yes`;
- user rejection;
- partial transaction completion;
- rerun safely continues from observed state;
- output contains subscription and rail IDs.

Lifecycle commands:

- sync;
- pause warning when rate update deferred;
- resume;
- stop;
- top-up;
- list/show/claims.

### 9.2 Golden-output policy

Store normalized golden outputs for:

- flat quote;
- capacity quote;
- trusted metering quote;
- exact Filone example;
- underfunded warning;
- mixed-recipient bundle;
- terminated subscription.

Addresses and transaction hashes are normalized; economic and risk disclosures are not.

### 9.3 Integration

Use the local devnet fixture to run the real CLI through:

```text
payments setup
add data
services quote
services add
services list
services sync
services pause
services stop
```

Assert on-chain state rather than only stdout.

---

## 10. Subgraph tests

### 10.1 Matchstick unit tests

For each Boss event:

- entity created/updated;
- fields exact;
- transaction and block metadata;
- duplicate log handling;
- out-of-order impossible transition defense where applicable.

### 10.2 Join-key tests

Derive exactly:

```text
railKey = chainId + ":" + lowercase(filecoinPay) + ":" + railId
```

Test collisions across:

- same rail ID on different chains;
- same rail ID on different Pay deployments;
- different Boss accounts.

### 10.3 Rebuild test

On a release candidate:

1. index from configured start block;
2. record entity counts and selected hashes;
3. wipe database;
4. reindex;
5. require identical result.

---

## 11. Explorer tests

### 11.1 Component tests

- assurance badges and explanatory copy;
- dependency badges;
- recipient breakdown;
- cap summary;
- quote validity;
- active/paused/terminating/ended states;
- usage-claim table;
- access-grant commitment display.

### 11.2 Data tests

- Boss subgraph unavailable while Pay subgraph works;
- Pay subgraph unavailable while Boss semantics load;
- stale Boss index;
- rail finalized in Pay but not yet reconciled in Boss;
- unknown generic rail;
- Boss rail with missing offer metadata;
- multiple Boss services on one PDP resource.

### 11.3 End-to-end

User journey:

1. open account;
2. view PDP resource;
3. inspect two available services;
4. quote;
5. accept;
6. see generic Pay rail and Boss identity;
7. pause one;
8. terminate another;
9. inspect settlement history.

No mutation UI ships before the SDK lifecycle APIs are stable.

---

## 12. Cross-repository devnet test

Create a versioned test harness, preferably in `filecoin-boss/examples/devnet-e2e/`.

### Required scenario

1. Start FOC devnet.
2. Deploy source-pinned Filecoin Pay, PDP, FWSS, and USDFC.
3. Deploy Boss contracts and adapters.
4. Register one storage provider and two add-on providers.
5. Fund one user.
6. Create an FWSS-backed dataset and add data.
7. Accept:
   - 1 USDFC/dataset/month flat service;
   - 1 USDFC/TiB/month capacity service;
   - capped egress service.
8. Advance epochs and settle flat/capacity rails.
9. Add data, sync capacity, and verify prospective rate change.
10. Submit egress claim.
11. Underfund payer.
12. Pause flat service and observe deferred nominal-rate update.
13. Terminate capacity service as Boss operator.
14. Verify FWSS rail and PDP dataset remain active.
15. Finalize Boss rail.
16. Query both subgraphs.
17. Run Filecoin Pin list/show.
18. Render Explorer pages.

Artifacts retained from CI:

- deployment manifest;
- transaction trace;
- event log;
- account/rail snapshots;
- subgraph query results;
- CLI transcript;
- Explorer screenshots;
- gas report.

---

## 13. Calibration rollout

### 13.1 Stage C0 — deployment rehearsal

- deploy to ephemeral local chain twice from clean state;
- compare bytecode and addresses;
- verify source;
- validate manifest schema;
- run all deployment checks.

### 13.2 Stage C1 — private Calibration alpha

Participants:

- protocol team wallets;
- one service provider;
- one synthetic reporter;
- no external funds of value.

Required exercises:

- account deployment;
- flat and capacity acceptance;
- metered claim;
- pause under both funded and underfunded state;
- termination;
- provider signing-key rotation;
- offer revocation;
- adapter deactivation;
- indexer rebuild.

Minimum observation period: enough to cross several capacity quote TTLs and Filecoin Pay settlement periods; use concrete epochs rather than relying only on wall-clock scripts.

### 13.3 Stage C2 — Filone pilot

- publish one immutable Filone offer;
- use explicit gross price and beneficiary;
- cap dataset count and payer exposure;
- manual user onboarding;
- daily reconciliation dashboard;
- manual incident runbook;
- no automatic top-up;
- no unbounded reporter authority.

Exit criteria:

- zero cap violations;
- all quote expiries reconciled or correctly zero-paying;
- no stuck termination;
- accounting reconciles across Boss, Filecoin Pay, subgraphs, and provider records;
- Filone obligation and support path are documented.

### 13.4 Stage C3 — public Calibration

- SDK and CLI release candidates;
- public offer catalog limited to protocol-supported adapters;
- bug bounty scope published;
- rate limits and spam handling for off-chain metadata endpoints;
- upgrade/migration rehearsal using a new account implementation version.

---

## 14. Mainnet rollout

### 14.1 Gate M0 — read-only support

Before contracts accept mainnet funds:

- SDK can parse deployment manifest;
- Explorer can display known test deployments;
- documentation labels mainnet unsupported;
- no write API selects absent addresses.

### 14.2 Gate M1 — limited deployment

Requirements:

- external contract audit closed;
- critical/high findings resolved;
- source verification complete;
- multisig and adapter-registry governance established;
- monitoring and alerting live;
- emergency communications runbook;
- caps on number of users, services, and aggregate gross exposure;
- one supported payment token;
- one supported FWSS/PDP deployment pair;
- only flat and capacity services if metering review is not complete.

### 14.3 Gate M2 — metered services

Additional requirements:

- reporter operational controls;
- claim audit log;
- fixed-lockup monitoring;
- explicit trusted-metering disclosure;
- top-up UX audited;
- dispute-extension design reviewed even if not yet implemented;
- incident drill where reporter key is compromised.

### 14.4 Gate M3 — general availability

- at least one full account-version migration completed;
- subgraph rebuild proven;
- service-provider onboarding docs;
- public adapter review process;
- SLOs for indexer, SDK, and reconciler;
- ongoing audit/bounty program;
- no unresolved critical accounting drift.

---

## 15. Security review plan

### 15.1 Internal review roles

Require independent reviewers for:

- Filecoin Pay accounting and lockup behavior;
- EIP-712 and authority model;
- adapter/math layer;
- callback/reentrancy;
- SDK funding planner;
- subgraph/Explorer semantic disclosure.

The author of `BossAccount.validatePayment` must not be the sole reviewer of its lifetime-cap accounting.

### 15.2 External audit scope

In scope:

- all contracts;
- production interfaces;
- deployment scripts;
- Filecoin Pay V1 integration;
- resource and pricing adapters;
- EIP-712 formats;
- invariants and known assumptions.

Out of scope but documented:

- provider runtime honesty under `CANCELLABLE_ONLY`;
- reporter honesty beyond accepted caps under `TRUSTED_METERING`;
- availability of third-party metadata URIs;
- underlying Filecoin Pay/PDP/FWSS code except integration assumptions.

### 15.3 Required threat scenarios

- compromised provider signing key;
- compromised reporter key;
- malicious adapter;
- registry-governance compromise;
- storefront substitution;
- chain reorganization around acceptance or claim;
- stale indexer;
- account underfunding;
- token with unexpected behavior;
- Filecoin Pay validator callback interaction;
- griefing through permissionless sync/settle;
- gas exhaustion from large bundles or evidence strings;
- denial of termination;
- false resource binding;
- lifetime-cap bypass across streaming and one-time paths;
- account-version migration confusion.

### 15.4 Audit remediations

Every audit finding receives:

- issue;
- severity;
- affected invariant;
- patch commit;
- regression test;
- reviewer sign-off;
- release-note entry.

No “acknowledged risk” is acceptable for a path that can exceed user caps or block termination.

---

## 16. Monitoring and operations

### 16.1 On-chain alerts

- account implementation created;
- adapter activated/deactivated;
- provider key changed;
- offer nonce revoked;
- subscription accepted;
- quote within 25% of expiry;
- quote expired while nominal Pay rate nonzero;
- attempted quote extension blocked because rail is not current;
- fixed budget below threshold;
- account-wide runway below service lockup;
- pause rate update deferred;
- termination callback not observed in expected transaction;
- rail not finalized after end epoch;
- subgraph lag.

### 16.2 Reconciler

The reconciler is permissionless and stateless where possible.

Jobs:

- refresh capacity quotes;
- settle rails;
- reconcile termination/finalization;
- compare Boss subscription to Pay rail;
- verify resource still attachable;
- emit metrics and alerts.

It must not hold user keys. It calls public Boss/Pay functions only.

### 16.3 Accounting reconciliation

Daily report by:

```text
subscription
accepted gross cap
streaming gross settled
one-time gross charged
remaining lifetime cap
current Pay rate
current fixed lockup
Pay settledUpTo/endEpoch
provider net credited
network fee
commission
```

Any mismatch between Boss cumulative gross and Filecoin Pay settlement events is a release-blocking incident until explained.

---

## 17. Release checklist

### Contracts

- [ ] source lock updated;
- [ ] all unit suites pass;
- [ ] fuzz and invariant profiles pass;
- [ ] real Filecoin Pay V1 integration passes;
- [ ] PDP/FWSS integration passes;
- [ ] Slither clean or reviewed;
- [ ] gas snapshots reviewed;
- [ ] bytecode sizes within limits;
- [ ] deployment deterministic;
- [ ] source verified;
- [ ] audit findings closed.

### SDK

- [ ] Node and browser tests;
- [ ] ABI/address generation reproducible;
- [ ] public API snapshot approved;
- [ ] funding planner vectors match Solidity;
- [ ] unsupported-chain behavior tested;
- [ ] multi-transaction failures recover safely.

### Filecoin Pin

- [ ] golden disclosures approved;
- [ ] read-only commands work without signer;
- [ ] mutation confirmation flow;
- [ ] partial execution recovery;
- [ ] integration on devnet and Calibration.

### Subgraph and Explorer

- [ ] Matchstick tests;
- [ ] rebuild test;
- [ ] Pay/Boss join-key test;
- [ ] index lag alert;
- [ ] component and end-to-end tests;
- [ ] assurance and cap language reviewed.

### Operations

- [ ] multisig established;
- [ ] monitoring dashboards;
- [ ] reconciler deployed redundantly;
- [ ] incident runbook;
- [ ] reporter-key compromise drill;
- [ ] termination drill;
- [ ] rollback means “stop new accounts/offers,” not mutate existing accounts;
- [ ] account-version migration procedure tested.

---

## 18. Non-negotiable release properties

A release candidate fails if any test or review shows that:

1. gross spend can exceed a user lifetime, window, single-charge, rate, or fixed-budget cap;
2. a provider or storefront can replace an accepted beneficiary;
3. a reporter can charge a replayed or overlapping claim;
4. an adapter can block termination;
5. `railTerminated` can revert;
6. a Boss operation can terminate or mutate the base FWSS rail;
7. a deleted or unauthorized resource remains deterministically billable;
8. the SDK hides a required transaction or recipient;
9. the UI calls trusted metering “verified” without qualification;
10. a contract deployment can be silently upgraded under the same account version.
