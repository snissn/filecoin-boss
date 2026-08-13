# Filecoin Boss
## Sovereign service composition over PDP, FWSS, and Filecoin Pay

**Status:** Design and implementation draft v0.2  
**Date:** 2026-08-12  
**Scope:** Normative protocol specification with an implementation baseline  
**Source lock:** Live repository state inspected on 2026-08-12; exact commits are listed in §27.

---

### Changes in v0.2

This revision keeps the v0.1 architecture and makes the implementation boundary concrete.

- Locks the public MVP to FWSS-backed PDP datasets.
- Locks `owner == Filecoin Pay payer` for the first Boss account version.
- Splits resource validation from pricing adapters.
- Defines immutable EIP-712 offer fields, activation policy, dependency policy, and termination-billing policy.
- Defines prospective capacity synchronization with a bounded quote TTL rather than claiming exact historical billing.
- Defines the trusted-metering claim format and exact cap calculation.
- Replaces the high-level repository plan with file-level changes for `filecoin-boss`, Synapse, Filecoin Pin, and Explorer.
- Names the required Foundry, TypeScript, CLI, subgraph, and end-to-end test suites.
- Adds an ordered cross-repository pull-request plan and Calibration/mainnet gates.
- Updates all source locks to live 2026-08-12 heads.
- Moves exhaustive implementation and rollout detail into companion documents while keeping authority and economic rules normative here.


## 0. Executive decision

Filecoin Boss should be a **separate service-composition and user-control layer above Filecoin Pay and PDP/FWSS**, not another feature embedded inside the Filecoin Warm Storage Service contract.

The central design decisions are:

1. **The user owns the bundle.** A bundle is a user-authorized graph linking one or more PDP resources to independently provided services. A storage provider, add-on provider, or storefront owns its offer, but none of them acquires ownership of the user's bundle merely by participating in it.

2. **Each independently governed service gets an independent Filecoin Pay rail.** This gives each service its own beneficiary, rate or budget, lockup, lifecycle, and failure domain. Base storage remains on its existing FWSS rail and does not share lifecycle control with add-ons.

3. **A per-user `BossAccount` is the Filecoin Pay operator and validator for Boss add-on rails.** The user approves one account once. The account enforces per-subscription caps, signed terms, deterministic pricing adapters, and an unconditional user-requested termination path. The service provider never receives unrestricted operator authority over the payer.

4. **Price increases are opt-in.** An accepted subscription pins an offer version, beneficiary, pricing function, maximum rate, budget, expiry, and terms hash. A provider may publish a new offer, but may not silently migrate an existing subscription to it.

5. **Billing and data access are separate authorities.** Paying for a service does not implicitly transfer ownership, custody, encryption keys, or broad access to the data. A service requiring content access receives a separately scoped, revocable capability.

6. **Trust is explicit.** Boss supports:
   - deterministic on-chain pricing and validation;
   - cancellable services with no objective SLA;
   - capped trusted metering, as used by CDN-style systems today;
   - later, delayed and disputable metered invoices;
   - eventually, cryptographically or economically verified usage.

7. **No distributed-system fiction.** PDP, FWSS, Filecoin Pay, indexers, SDKs, storage providers, and add-on providers do not update atomically. Boss uses signed desired-state manifests, idempotency keys, event-sourced state, and a reconciler rather than pretending the system has a single transaction boundary.

This design solves the immediate Filone requirement without waiting for FWSSv2:

```text
Existing FWSS storage rail            -> storage provider
Boss capacity-priced service rail     -> Filone
Boss flat service rail                -> another provider
Boss capped metered rail              -> CDN / retrieval provider
```

The customer may see one branded product and one total quote, while the underlying recipients, caps, and independently terminable rails remain explicit.

---

## 1. Current-system findings

### 1.1 Filecoin Pay already supplies the payment primitives

Filecoin Pay V1 already separates:

- payer accounts and deposited token balances;
- point-to-point payment rails;
- streaming rates;
- fixed lockup for one-time payments;
- operators with aggregate rate, lockup, and lockup-period allowances;
- optional validators that can reduce settlement amounts or settlement ranges;
- optional service commissions;
- payer and operator termination;
- public settlement.

Boss therefore does **not** need to invent another payment ledger.

The missing abstraction is the semantic layer that answers:

- which service a rail pays for;
- which PDP resources it covers;
- what offer the user accepted;
- what caps apply;
- what evidence earns payment;
- whether a service is independent of or dependent on storage;
- how it can be paused, terminated, replaced, or disputed;
- how a branded bundle maps to multiple recipients and rails.

### 1.2 Important Filecoin Pay V1 constraints

Boss must design around these behaviors rather than hide them.

#### Account-wide runway

A Filecoin Pay account has one balance and one aggregate streaming rate per token. Its `fundedUntilEpoch` is therefore **account-wide**, not per rail. Several services funded by the same payer and token share the same financial runway.

This does not mean every service runtime automatically stops at the same moment. It means active rails cannot settle beyond the same funded horizon. Each service still has its own operational suspension policy.

There is no native priority such as “pay storage before CDN.” Strict priority or budget isolation requires a separately funded payer account.

#### Operator approval is aggregate

`rateAllowance`, `lockupAllowance`, and their usage are aggregated across all rails created by a given operator for a payer and token. Filecoin Pay does not provide per-rail operator caps.

Boss must enforce subscription-level caps internally and expose the aggregate approval required for all subscriptions.

#### Revoking an operator is not enough

Setting `approved = false` prevents an operator from creating new rails, but does not neutralize its powers over existing rails. Existing operators can still perform several modifications, spend existing one-time-payment lockup, and terminate their rails. Zeroing allowances removes increase headroom but still does not eliminate existing-rail authority.

A Boss service must therefore be controlled through an owner-governed operator, not by handing the provider direct operator authority.

#### Direct payer termination is funding-sensitive

A payer can call `terminateRail` only when its account is fully settled. The rail operator can terminate without that funding precondition.

A user-controlled Boss operator is consequently important: the user calls `BossAccount.terminate(subscriptionId)`, and the Boss account terminates as the rail operator even when the payer's shared Filecoin Pay account is underfunded.

#### Validators are powerful

A validator can:

- reduce payment;
- reduce the settlement range;
- return notes;
- receive a synchronous termination callback;
- revert and therefore block rail termination.

Boss validators must be designed to **never veto a user-requested termination**.

#### One-time payments are immediate

A Filecoin Pay one-time payment is processed immediately from `lockupFixed`; the rail validator is not a pre-payment dispute layer for that transfer.

A service that needs disputes must delay the call that converts an invoice into a one-time payment. Once the one-time payment is executed, the payment is final absent a separate refund mechanism.

#### Payer-only validation bypass

After a rail is terminated and its maximum settlement epoch has passed, Filecoin Pay V1 lets the payer settle the terminated rail without validator approval. This escape hatch pays the rail in full. It is useful for recovering from a broken validator, but it means Boss caps protect the payer from operators and providers—not from the payer's own explicit bypass transaction. Boss tooling must label this as a voluntary full-payment emergency action and must never invoke it automatically.

#### V1 versioning hazards

Filecoin Pay V1 is non-upgradeable. Its implementation specification records known V1 behaviors, including a terminated-rail operator `lockupUsage` leak in some rate-reduction paths and validator-note replacement across rate-change segments. Boss must version its Pay adapter, maintain migration tests, and avoid assuming future Pay deployments behave identically.

### 1.3 PDP supplies a stable resource anchor

A PDP resource can be referenced as:

```solidity
struct PDPResourceRef {
    uint64 chainId;
    address verifier;
    uint256 dataSetId;
}
```

The verifier exposes enough state for Boss to bind and price services:

- dataset liveness;
- listener address;
- storage provider and proposed provider;
- total leaf count;
- challenge range;
- last proven epoch;
- piece CIDs and sizes;
- scheduled removals.

A dataset's operational storage-provider role can migrate while the `(chainId, verifier, dataSetId)` identity remains stable. A Boss subscription should normally survive provider migration unless its accepted dependency policy says otherwise.

A deleted and recreated dataset has a new identity. Rebinding a service to the replacement must require a new user authorization.

### 1.4 FWSS currently combines too many product concerns

The current FWSS contract combines:

- PDP listener behavior;
- dataset registration;
- provider and payer identity;
- storage pricing;
- per-dataset proving fee;
- operation fees and reserve management;
- proof-linked settlement validation;
- storage-provider payment;
- optional CDN setup;
- CDN and cache-miss rails;
- service termination;
- metadata;
- upgrades and views.

The current CDN path is especially instructive. A `withCDN` creation-time flag causes FWSS to create:

1. the PDP/storage streaming rail;
2. a zero-rate CDN rail with fixed lockup;
3. a zero-rate cache-miss rail with fixed lockup.

An off-chain controller reports usage, and one-time payments consume the two fixed-lockup balances. This is a valid product implementation, but it is not a general service-composition protocol.

Boss should generalize that pattern while correcting its coupling:

- services attach after dataset creation;
- service state is not encoded as arbitrary dataset metadata;
- the user can terminate an add-on without deleting the storage dataset;
- each service declares its own pricing and trust model;
- one service can cover one dataset, several replicas, or a resource group;
- the graph is indexed directly rather than inferred from special flags.

### 1.5 The repositories already point in this direction

Existing Filecoin Services discussions identify the same architectural pressure:

- IPFS indexing was deferred until product features could be abstracted from the PDP core and deployed over PDP-backed CIDs;
- mutable CDN enablement exposed the fact that a service flag is not ordinary metadata;
- FWSS contract growth drove a decision to use ERC-8167 internally in FWSSv2;
- FWSSv2 is tracked as a breaking redesign.

ERC-8167 is suitable for **internal selector-based modularization of one contract's implementation and storage**. It does not define product offers, beneficiaries, user consent, independent rails, cross-provider governance, or service lifecycle. Boss should therefore use external service contracts and shared interfaces. FWSSv2 may separately use ERC-8167 for its own internal code organization.

### 1.6 Current client and explorer gaps

Synapse and Filecoin Pin currently understand the storage product:

- calculate storage funding;
- deposit USDFC;
- approve FWSS;
- select providers;
- create or reuse datasets;
- upload, pull, and commit pieces;
- inspect storage and payment state.

Filecoin Pay Explorer indexes generic accounts, approvals, rails, rates, one-time payments, and settlements. It does not know that a rail represents “Filone managed storage,” “indexing,” “repair,” or “CDN for these three datasets.”

Boss therefore requires both:

- a client-side service catalog, quote, funding, acceptance, and lifecycle API;
- an event index linking Boss offers, subscriptions, resources, and rail IDs.

---

## 2. Problem statement

A user with a PDP/FWSS-backed dataset should be able to attach independently provided services while retaining control of:

- the underlying data and content identifiers;
- which service has access;
- who is paid;
- the exact accepted price;
- the maximum rate and maximum usage budget;
- whether the service depends on the storage service;
- when the service stops;
- whether one service failure affects others;
- how to leave without moving or deleting the underlying data.

A service provider should be able to publish an offer that states:

- what it provides;
- which resource types it supports;
- how it is priced;
- which token it accepts;
- who receives payment;
- what evidence earns payment;
- what termination notice or lockup applies;
- what caps it supports;
- what operational endpoints or capabilities it needs;
- what trust and dispute model applies.

A storefront should be able to combine offers into one branded product without becoming the owner of the user's data or silently gaining authority over unrelated services.

---

## 3. Goals and non-goals

### 3.1 Goals

Boss v1 should:

1. attach services to existing PDP/FWSS resources without changing PDP or FWSS V1;
2. support independent service providers and beneficiaries;
3. create independently terminable Filecoin Pay rails;
4. support flat, capacity-based, and capped metered billing;
5. allow one service to cover a dataset or resource set;
6. expose exact total price and recipient breakdown before acceptance;
7. enforce user-selected caps on-chain;
8. prevent silent price increases;
9. preserve an always-available user exit through the Boss operator;
10. let indexers reconstruct all state from events;
11. integrate with Synapse, Filecoin Pin, and Filecoin Pay Explorer;
12. permit later dispute and verification modules without changing the base data model.

### 3.2 Non-goals for v1

Boss v1 will not:

- replace PDP, FWSS, or Filecoin Pay;
- custody or encrypt user data;
- claim cryptographic proof of network bandwidth;
- create atomic transactions across off-chain storage systems and every on-chain contract;
- guarantee that a third-party service is useful merely because its payment is bounded;
- support hidden price increases;
- force all services in a bundle to share one SLA or one lifecycle;
- require every offer to be registered by a central authority;
- extract the existing FWSS storage rail into Boss;
- migrate existing embedded FilBeam rails automatically.

---

## 4. Design principles

### P1. Composition, not ownership

A bundle is a graph of references and authorizations. Attaching a service does not transfer the underlying PDP dataset.

### P2. One independently governed obligation, one rail

Services with different beneficiaries, pricing, validation, caps, or termination rules should not share a rail.

Aggregation is allowed only when all included obligations intentionally share lifecycle and settlement semantics.

### P3. Direct payment by default

Each service rail pays the service beneficiary directly. A storefront is not inserted into custody of upstream funds unless the user explicitly chooses reseller mode.

### P4. User-authorized increases only

Any action that can raise:

- a streaming rate;
- fixed lockup;
- lifetime budget;
- period budget;
- expiry;
- lockup period;

must be bounded by the user's accepted intent. A provider may lower a price without renewed consent.

### P5. Failure isolation

An add-on failure does not terminate base storage. A storage fault does not automatically terminate every add-on. Dependencies are explicit per subscription.

### P6. Escape before SLA sophistication

A bounded service that the user can stop is useful even without perfect SLA verification. Boss should ship that before pretending bandwidth has a trustless proof.

### P7. Data access is a separate capability

A payment subscription and a data-access grant are distinct objects with distinct revocation.

### P8. Event-sourced reconciliation

Every state transition emits an event with stable identifiers. Off-chain agents reconcile desired state with observed state and retry idempotently.

---

## 5. Authority model

Boss distinguishes roles that are currently easy to conflate.

| Role | Authority |
|---|---|
| **Bundle owner** | Accepts and changes bundle composition; normally the user |
| **Payer** | Address whose Filecoin Pay account funds a rail |
| **Boss account owner** | Controls the Boss operator; normally equal to bundle owner |
| **Resource controller** | Authorizes a service to access or rebind data resources |
| **PDP storage provider** | Operationally controls PDP dataset mutations and proofs |
| **Service provider** | Performs an add-on service and signs the offer |
| **Beneficiary** | Receives Filecoin Pay settlement |
| **Storefront** | Publishes a branded bundle quote; may receive a disclosed fee |
| **Metering reporter** | Submits usage claims within an accepted policy |
| **Validator/arbitrator** | Reduces or approves payment according to a declared trust model |
| **Keeper/reconciler** | Permissionlessly invokes deterministic sync and settlement functions |

The same address may occupy several roles, but the protocol must not assume that it does.

### 5.1 Billing authority

A payer accepts financial terms. For an existing FWSS dataset, Boss should verify the dataset's FWSS-recorded payer when the service is advertised as a payer-owned add-on.

A different payer may fund the service only when the bundle owner explicitly authorizes it.

### 5.2 Data-access authority

Some services need no data access:

- proof monitoring;
- payment reporting;
- alerts;
- on-chain analytics.

Others need content or retrieval access:

- CDN;
- indexing;
- transformation;
- repair;
- compute.

Those services receive an `AccessGrant` separate from the payment subscription.

```solidity
struct AccessGrant {
    bytes32 resourceId;
    address grantee;
    bytes32 capabilityHash;
    uint64 notBefore;
    uint64 notAfter;
    bytes32 scopeHash;
    uint256 nonce;
}
```

The capability itself may be off-chain. Boss stores or emits only the commitment and revocation state. Encryption keys and bearer credentials must not be published on-chain.

---

## 6. Core objects and exact MVP data model

This section is normative for the first implementation. The separate implementation draft may refine internal packing, but it must preserve these authorities and economic fields.

### 6.1 Resource reference

```solidity
enum ResourceKind {
    FWSS_PDP_DATASET,
    BARE_PDP_DATASET,
    PDP_RESOURCE_SET,
    GENERIC_CONTENT_ROOT
}

struct ResourceRef {
    ResourceKind kind;
    uint64 chainId;
    address anchor;
    uint256 resourceId;
    bytes32 context;
}
```

For the public MVP:

- `kind` must be `FWSS_PDP_DATASET`;
- `anchor` is the exact PDP verifier address;
- `resourceId` is the PDP dataset ID;
- `context` is zero.

The canonical resource key is domain-separated:

```solidity
keccak256(
    abi.encode(
        "FILECOIN_BOSS_RESOURCE_V1",
        resource.kind,
        resource.chainId,
        resource.anchor,
        resource.resourceId,
        resource.context
    )
)
```

A resource ID is not authority by itself. The FWSS resource adapter must verify:

1. chain and PDP verifier;
2. dataset liveness;
3. the dataset's listener is the supported FWSS deployment;
4. the matching FWSS state view recognizes the dataset;
5. the FWSS dataset payer equals the Boss account payer.

The PDP storage-provider role alone is not accepted as user authority. Bare PDP attachment is disabled in the public MVP.

### 6.2 Resource sets

Resource sets support later services spanning replicas or several datasets:

```solidity
struct ResourceSet {
    address owner;
    bytes32 membershipRoot;
    uint64 version;
    uint64 createdAt;
}
```

Membership changes create a new version. Existing subscriptions stay pinned unless the user explicitly accepts a rebind policy. Resource sets are not required for the first Filone pilot.

### 6.3 Service offer

```solidity
enum BillingKind {
    STREAM_FLAT,
    STREAM_CAPACITY,
    METERED_FIXED_LOCKUP,
    ONE_TIME
}

enum AssuranceKind {
    CANCELLABLE_ONLY,
    ONCHAIN_DETERMINISTIC,
    TRUSTED_METERING,
    ATTESTED,
    DISPUTABLE
}

enum DependencyKind {
    NONE,
    SOFT,
    HARD
}

enum ActivationKind {
    IMMEDIATE,
    PROVIDER_ACK
}

enum TerminationBillingKind {
    PAY_THROUGH_FILECOIN_PAY_END,
    ZERO_AFTER_REQUEST,
    ADAPTER_DECIDES
}

struct ServiceOffer {
    bytes32 serviceId;
    uint64 offerVersion;
    address provider;
    address signingKey;
    address beneficiary;
    address reporter;
    address token;
    address resourceAdapter;
    address pricingAdapter;
    bytes32 serviceType;
    BillingKind billingKind;
    AssuranceKind assuranceKind;
    DependencyKind dependencyKind;
    ActivationKind activationKind;
    TerminationBillingKind terminationBillingKind;
    bytes32 pricingDataHash;
    bytes32 termsHash;
    bytes32 accessScopeHash;
    uint64 validAfterEpoch;
    uint64 validUntilEpoch;
    uint64 requiredLockupPeriod;
    uint64 quoteTtlEpochs;
    uint16 commissionBps;
    address commissionRecipient;
    bool pauseAllowed;
    uint256 providerMaxRatePerEpoch;
    uint256 providerMaxFixedLockup;
    uint256 nonce;
}
```

The provider signs this structure with EIP-712. The EIP-712 domain includes chain ID and the Boss account or protocol deployment. EOA and ERC-1271 signatures are supported.

Accepted offers are immutable. A price, beneficiary, token, adapter, commission, assurance class, dependency, or terms change creates a new offer version and a new subscription.

All quoted prices are **gross payer amounts** before Filecoin Pay's network fee and optional commission.

### 6.4 Cap policy

```solidity
struct CapPolicy {
    uint256 maxRatePerEpoch;
    uint256 maxFixedLockup;
    uint256 maxSingleCharge;
    uint256 maxChargePerWindow;
    uint256 lifetimeCapGross;
    uint64 chargeWindowEpochs;
    uint64 notAfterEpoch;
    uint64 maxLockupPeriod;
}
```

Only the Boss account owner can change caps. No call may implicitly increase them. A provider, reporter, storefront, registry, or reconciler cannot increase a cap.

Cap encoding is explicit:

- zero means zero for monetary maxima;
- `type(uint256).max` means no monetary maximum;
- `notAfterEpoch == 0` means no time expiry;
- `chargeWindowEpochs == 0` is valid only for non-metered billing.

A public metered offer must use finite fixed, single-charge, window, and lifetime caps.

Any cap or expiry expansion is **prospective**. Before applying it, Boss must settle the rail as far as the current epoch under the old terms. If Filecoin Pay cannot bring the rail current, the expansion fails rather than authorizing previously non-billable epochs retroactively.

The effective commitment is bounded by all of:

- accepted offer maxima;
- user caps;
- Filecoin Pay operator allowance;
- rail fixed and streaming lockup;
- payer account funds.

### 6.5 Subscription

```solidity
enum SubscriptionState {
    NONE,
    PENDING_ACTIVATION,
    ACTIVE,
    PAUSED,
    TERMINATING,
    ENDED,
    EXHAUSTED
}

struct Subscription {
    bytes32 offerHash;
    bytes32 resourceKey;
    bytes32 resourceDataHash;
    bytes32 pricingDataHash;
    bytes32 accessGrantHash;
    address provider;
    address beneficiary;
    address reporter;
    address token;
    address resourceAdapter;
    address pricingAdapter;
    uint256 railId;
    BillingKind billingKind;
    AssuranceKind assuranceKind;
    DependencyKind dependencyKind;
    ActivationKind activationKind;
    TerminationBillingKind terminationBillingKind;
    bool pauseAllowed;
    CapPolicy caps;
    uint256 acceptedRatePerEpoch;
    uint256 settledGross;
    uint256 oneTimeChargedGross;
    uint256 currentFixedBudget;
    uint64 acceptedEpoch;
    uint64 activatedEpoch;
    uint64 quoteValidThroughEpoch;
    uint64 pausedEpoch;
    uint64 terminationRequestedEpoch;
    uint64 payEndEpoch;
    uint64 lastUsageToEpoch;
    SubscriptionState state;
}
```

`settledGross + oneTimeChargedGross` is the cumulative gross amount charged against `lifetimeCapGross`.

### 6.6 Immutable attachment data

Rate synchronization and metered charging require the exact accepted resource and pricing parameters after acceptance. The account therefore stores, in separate mappings keyed by subscription ID:

```solidity
ResourceRef resourceBySubscription;
bytes resourceDataBySubscription;
bytes pricingDataBySubscription;
```

The logical subscription stores their hashes. The provider signature commits to `pricingDataHash`; the acceptance and subscription events commit to the resource and resource-data hashes.

Dynamic bytes are not silently fetched from a mutable URI during billing. An updated pricing payload creates a new offer and subscription.

### 6.7 Bundle

A bundle is an indexable user-owned manifest:

```solidity
struct Bundle {
    bytes32 bundleId;
    address owner;
    bytes32 resourceKey;
    bytes32 manifestHash;
    uint64 version;
}
```

The Boss account may accept a bounded batch of add-on components atomically. The base FWSS rail remains external and is never controlled by the Boss bundle.

### 6.8 Access grant commitment

Payment authority and data access remain separate.

The subscription stores only:

```solidity
bytes32 accessGrantHash;
bytes32 accessRevocationHash;
```

The actual capability, key, token, or credential remains off-chain and independently revocable. An empty access scope must be used when the service does not require content access.

---

## 7. Contract architecture and implementation constraints

```text
                          signed immutable offer
 Service provider  --------------------------------+
                                                    |
 Storefront / SDK --------------------------------+ |
                                                  | |
                                                  v v
 User wallet ---- owns ----> BossAccount <---- ServiceRegistry
      |                         |
      |                         +---- Filecoin Pay flat rail ------> provider A
      |                         +---- Filecoin Pay capacity rail --> provider B
      |                         +---- Filecoin Pay metered rail ----> CDN
      |
      +---- existing FWSS flow ---- Filecoin Pay storage rail -----> storage provider
                                      |
                                      +---- existing PDP/FWSS validation

 BossAccount ---- reads through allowlisted adapters ----> PDP + FWSS state
 Data-access capability -------------------------------> service runtime
```

### 7.1 New protocol repository

The implementation belongs in a new `FilOzone/filecoin-boss` repository. It owns:

- contracts and immutable implementation versions;
- deployment manifests and generated ABIs;
- resource and pricing adapters;
- a Boss-specific subgraph;
- examples and the Filone reference storefront;
- specification, ADRs, threat model, and audit artifacts.

Boss business logic must not be embedded into `FilecoinPayV1.sol`, PDP, or FWSS for the MVP.

### 7.2 `BossFactory`

The factory deploys deterministic ERC-1167 clones or an equivalent minimal account.

The account key includes:

```text
owner
Filecoin Pay contract
immutable Boss implementation version
```

For MVP, owner and Filecoin Pay payer are the same address. A delegated controller/payer split requires a later signed payer-authorization design.

Factory requirements:

- deterministic address prediction;
- idempotent deployment;
- implementation version and codehash cannot be overwritten;
- factory governance cannot control deployed accounts;
- accounts are not proxy-upgradeable;
- account version 1 has no ownership-transfer function; users needing recovery deploy a smart account as owner;
- anyone may deploy the deterministic account for an owner, but only that owner can operate it;
- migrations deploy a new account version and recreate subscriptions.

### 7.3 `BossAccount`

The Boss account is:

- owned by the user or user smart account;
- the Filecoin Pay operator for Boss rails;
- the Filecoin Pay validator for Boss rails;
- unable to `delegatecall` into provider code;
- pinned to one Filecoin Pay contract and one implementation version.

Core functions:

```solidity
function acceptOffer(
    ServiceOffer calldata offer,
    bytes calldata providerSignature,
    ResourceRef calldata resource,
    bytes calldata resourceData,
    bytes calldata pricingData,
    CapPolicy calldata caps,
    uint256 initialFixedBudget,
    bytes32 accessGrantHash
) external returns (bytes32 subscriptionId, uint256 railId);

function acknowledgeActivation(
    bytes32 subscriptionId,
    bytes32 provisioningHash,
    bytes calldata providerSignature
) external;

function activate(bytes32 subscriptionId) external;
function syncRate(bytes32 subscriptionId) external;
function pause(bytes32 subscriptionId) external;
function resume(bytes32 subscriptionId) external;
function terminate(bytes32 subscriptionId) external;
function topUpFixedBudget(bytes32 subscriptionId, uint256 newFixedBudget) external;
function reconcileSubscription(bytes32 subscriptionId) external;
function submitUsageClaim(
    bytes32 subscriptionId,
    UsageClaim calldata claim,
    bytes calldata reporterSignature
) external returns (uint256 grossCharged);
```

`syncRate`, settlement, and reconciliation may be permissionless. Offer acceptance, cap increases, budget top-up, pause, resume, and termination are owner-authorized.

### 7.4 Filecoin Pay rail creation

`acceptOffer` performs one atomic Boss/Filecoin Pay transaction:

1. verify provider signature, nonce, and offer validity;
2. verify pricing bytes and resource binding;
3. quote initial rate or fixed budget;
4. enforce user caps;
5. create a Filecoin Pay rail with:
   - `from = payer`;
   - `to = accepted beneficiary`;
   - `operator = BossAccount`;
   - `validator = BossAccount`;
   - accepted commission fields;
6. set lockup period and fixed lockup;
7. set initial streaming rate for immediate activation, or leave it zero for provider acknowledgment;
8. persist subscription and rail mapping;
9. emit complete semantic events.

Failure of any Pay operation reverts the complete acceptance and leaves no orphan subscription or rail.

### 7.5 Pricing adapters

Boss uses separate resource and pricing interfaces.

```solidity
struct ResourceStatus {
    bytes32 resourceKey;
    bool exists;
    bool attachable;
    bool billable;
    address payer;
    address storageProvider;
    uint256 sizeInBytes;
    bytes32 statusHash;
}

interface IBossResourceAdapter {
    function inspect(
        ResourceRef calldata resource,
        address expectedPayer,
        bytes calldata resourceData
    ) external view returns (ResourceStatus memory);
}

struct RateQuote {
    uint256 ratePerEpoch;
    uint64 validThroughEpoch;
    bool billable;
    bytes32 quoteHash;
    string note;
}

interface IBossPricingAdapter {
    function quoteRate(
        ResourceStatus calldata resource,
        bytes calldata pricingData
    ) external view returns (RateQuote memory);

    function quoteUsage(
        uint256 units,
        bytes calldata pricingData
    ) external view returns (uint256 grossCharge);
}
```

Adapter requirements:

- adapter address, interface version, and codehash are recorded in `BossAdapterRegistry`;
- disabled adapters cannot be used for new subscriptions;
- accepted subscriptions remain pinned to their exact address;
- Boss uses `staticcall` with a gas stipend;
- no adapter can veto termination;
- no adapter can choose beneficiary, token, caps, or commission.

Public MVP adapters:

- `FWSSPDPResourceAdapter`;
- `FlatRateAdapter`;
- `PDPCapacityAdapter`;
- `CappedMeteredAdapter`.

### 7.6 Service and adapter registries

`BossServiceRegistry` provides provider metadata, service definitions, signing-key rotation, and offer-nonce revocation. Registration is not an assurance endorsement.

For the public MVP, the service's signing key must be authorized by the named provider and the resource/pricing adapters must be active in the protocol adapter registry. A later custom-account mode may permit unregistered adapters with explicit warnings; it is not part of the audited default.

### 7.7 Prospective economic changes

A single `quoteValidThroughEpoch` is safe only when every economic expansion is applied prospectively.

Before Boss:

- extends a dynamic quote;
- resumes a paused subscription;
- increases a rate cap;
- increases a lifetime cap;
- extends `notAfterEpoch`;

it first calls Filecoin Pay settlement through the current epoch under the old terms and verifies the rail was brought current.

If account underfunding prevents current settlement, the expansion or resume fails. The old quote may expire and become zero-paying, but a later refresh cannot make that expired interval billable.

`syncRate` therefore follows:

```text
settle under old rate and validity
→ verify rail current
→ inspect current resource
→ compute new rate
→ modify Filecoin Pay rate prospectively
→ store new validity boundary
```

This avoids maintaining a second historical rate queue and prevents a later quote refresh from retroactively reviving an expired billing gap.

### 7.8 Validator behavior

`validatePayment` is called only by the pinned Filecoin Pay contract.

It must:

- never return more than `proposedAmount`;
- recognize exact activation, pause, expiry, quote-validity, termination, and lifetime-cap boundaries;
- accumulate gross settlement across multiple rate segments in one transaction;
- advance non-billable expired intervals with zero payment;
- roll back accounting when the outer settlement transaction reverts;
- never call a service runtime or unbounded provider code.

For dynamic capacity services, the validator uses the rate checkpoints created by `syncRate`; it does not use current capacity to retroactively rewrite historical rate segments.

### 7.9 Termination callback

`railTerminated` is synchronously called by Filecoin Pay and is a special non-reverting callback.

It must:

- not use a global reentrancy guard that rejects the callback;
- not call external contracts;
- ignore unauthorized callers without mutating state;
- record the Filecoin Pay end epoch;
- never revert.

The owner calls `BossAccount.terminate`. The Boss account then calls Filecoin Pay as rail operator, including while the payer account is underfunded.

### 7.10 Pause semantics

Pause changes Boss validation immediately. It then attempts to set the Filecoin Pay rate to zero.

Filecoin Pay V1 may reject an active rate change when the payer is underfunded. In that case:

- validator payment remains paused;
- the nominal Pay rate may remain in account-wide lockup accounting;
- Boss emits `PauseRateUpdateDeferred`;
- tooling recommends termination for a reliable release path.

Resume takes a fresh quote and must successfully update Filecoin Pay before returning the subscription to `ACTIVE`.

### 7.11 State view and events

A separate `BossStateView` supplies paginated and batch reads so the account implementation stays focused.

All semantic state required by indexers must be emitted, including:

- account creation;
- provider key and service publication;
- subscription acceptance and rail binding;
- bundle manifest;
- provider activation acknowledgment;
- rate synchronization and quote expiry;
- pause/resume;
- cap and fixed-budget change;
- usage claim and charged amount;
- access grant commitment/revocation;
- termination request, Pay callback, and finalization.

The Boss subgraph joins to the generic Filecoin Pay subgraph by:

```text
chain ID + Filecoin Pay address + rail ID
```

A rail ID alone is not globally unique.

---

## 8. Operator-topology decision

Four topologies were considered.

| Topology | Advantages | Problems | Decision |
|---|---|---|---|
| Global Boss singleton as operator | One deployment; simple indexing | Global upgrade and exploit blast radius; broad aggregate authority | Reject |
| Service provider or adapter as operator | Direct implementation | User must trust every provider with existing-rail operator powers; fragmented approvals | Reject as default |
| Per-subscription operator | Maximum isolation | One deployment and operator approval per subscription; poor UX | Optional high-assurance mode |
| **Per-user Boss account** | One approval; user-owned exit; internal per-service caps; base storage isolated | All Boss subscriptions for one user share one account implementation and aggregate allowance | **Recommended v1** |

A future `IsolatedBossBudgetAccount` may also act as the payer for add-ons. The user funds that Filecoin Pay account separately, preventing add-ons from consuming base-storage runway.

---

## 9. Rail topology

### 9.1 Default rule

Boss v1 creates **one rail per subscription**.

This intentionally favors:

- independent termination;
- clear accounting;
- direct recipient mapping;
- simple cap enforcement;
- simple explorer UX;
- reduced cross-service coupling.

Gas optimization through aggregation should come only after actual usage data demonstrates a need.

### 9.2 Multi-beneficiary services

Filecoin Pay rails have one payee and one optional commission recipient.

Use:

- one rail with commission when the split is a proportional payee/commission split and its exact fee ordering is acceptable;
- multiple rails when recipients have independent obligations or lifecycle;
- a transparent splitter contract when more recipients must share one inseparable obligation.

A splitter must not hide the final recipients from the accepted offer.

### 9.3 Gross versus net pricing

Boss caps are stated in **gross payer spend**.

Filecoin Pay deducts its network fee and then any commission before crediting the net payee. An offer that promises a precise net provider receipt must gross up its quote.

### 9.4 Base storage remains external

Boss does not become the operator or validator of the existing FWSS storage rail.

A bundle links to that rail for display and dependency status, but add-on providers cannot modify or terminate it.

---

## 10. Bundle activation and distributed reconciliation

### 10.1 Existing dataset

For an existing dataset, activation can be one Boss transaction after funding and operator approval:

1. resolve and verify `ResourceRef` through a supported resource adapter;
2. read PDP liveness, listener, and storage-provider state;
3. for FWSS-backed resources, read the FWSS dataset record and require its payer to match the accepted payer;
4. verify offer and acceptance signatures;
5. calculate quote;
6. verify accepted caps cover the initial quote;
7. create add-on rail;
8. configure lockup and rate;
9. record subscription;
10. emit `OfferAccepted`.

### 10.2 New storage bundle

A new PDP dataset is normally created through a storage-provider-mediated PDP/FWSS flow. Boss should not pretend it can atomically create that external resource and every service.

Use a saga:

1. storefront produces a signed `BundleQuote`;
2. user signs a `BundleIntent` with:
   - client dataset nonce;
   - expected listener;
   - allowed provider constraints;
   - service components;
   - caps;
   - expiry;
   - `requireAll` policy;
3. SDK prepares Filecoin Pay funding and approvals;
4. storage provider creates the dataset;
5. reconciler observes `DataSetCreated`;
6. Boss binds the signed intent to the resulting resource;
7. Boss creates add-on subscriptions;
8. reconciler verifies all expected rail and resource links;
9. bundle becomes complete or explicitly partial.

Every operation uses an idempotency key derived from:

```text
hash(chainId, owner, clientDataSetId, offerId, offerVersion, componentIndex, nonce)
```

### 10.3 Partial activation

Default behavior is **base storage survives add-on failure**.

The bundle records:

- `COMPLETE`;
- `PARTIAL`;
- `FAILED_ADDONS`;
- `CANCELLED`.

A storefront may offer `requireAll`, but it can guarantee atomicity only for components created in one Boss transaction after the resource exists. Cross-system compensation remains explicit.

---

## 11. Billing model A: $1 per deal per month

Assume:

- token: USDFC with 18 decimals;
- Filecoin epoch: 30 seconds;
- Boss month: 30 days;
- epochs per month: `86,400`;
- “deal” means one accepted dataset subscription.

The streaming rate is:

```text
ratePerEpoch = floor(1e18 / 86,400)
             = 11,574,074,074,074 USDFC-wei/epoch
```

The resulting 30-day gross charge is:

```text
11,574,074,074,074 × 86,400
= 999,999,999,999,993,600 USDFC-wei
= 0.9999999999999936 USDFC
```

The truncation is 6,400 token wei per 30-day period and is user-favorable.

### 11.1 Offer

```json
{
  "serviceType": "FLAT_DATASET_SERVICE",
  "billingKind": "STREAM_FLAT",
  "pricePer30Days": "1000000000000000000",
  "ratePerEpoch": "11574074074074",
  "defaultLockupPeriod": "2880",
  "assuranceKind": "CANCELLABLE_ONLY"
}
```

The example uses a one-day termination lockup (`2,880` epochs). Zero or another value is also valid, but it must be shown before acceptance.

### 11.2 Subscription behavior

- One dataset creates one $1/month subscription.
- Adding or removing pieces does not change the rate.
- Storage provider migration does not change the service.
- Dataset deletion causes a hard-dependent service to become non-billable and terminable.
- The add-on can be terminated while the storage rail remains active.
- A twelve-month maximum spend can be expressed as:
  - `notAfter = start + 12 × 86,400`; and/or
  - `lifetimeCap = 12e18`.

### 11.3 If “per day” is desired

Use `2,880` epochs instead of `86,400` in the denominator. The protocol does not hard-code the human billing label; the offer pins the exact epoch rate.

---

## 12. Billing model B: $1 per TiB per month

Assume a deterministic capacity service priced at one USDFC per TiB per 30 days.

For PDP leaf count `L`, Boss mirrors the current canonical FWSS conversion from data-bearing Fr32 leaves to approximate raw bytes:

```text
billableBytes = floor(L × 32 × 127 / 128)
```

This matches `Cids.leafCountToRawSize`. It is an aggregate approximation and may overestimate by up to 31 bytes per piece. A service requiring exact per-piece raw capacity must use a distinct adapter that enumerates live PieceCIDv2 records and sums exact `rawPieceSize` values.

The per-epoch rate is:

```text
ratePerEpoch =
    floor(
      billableBytes × 1e18
      / (2^40 × 86,400)
    )
```

Examples:

| Capacity | Rate per epoch | 30-day gross |
|---:|---:|---:|
| 0.5 TiB | 5,787,037,037,037 | 0.4999999999999968 USDFC |
| 1 TiB | 11,574,074,074,074 | 0.9999999999999936 USDFC |
| 3.5 TiB | 40,509,259,259,259 | 3.4999999999999776 USDFC |
| 10 TiB | 115,740,740,740,740 | 9.999999999999936 USDFC |

### 12.1 Measurement policy

The offer must identify one audited pricing adapter and therefore one exact measurement rule.

The generic MVP adapter bills:

```text
committed approximate raw bytes
= floor(getDataSetLeafCount × 32 × 127 / 128)
```

This includes pieces committed to the PDP dataset according to current on-chain state. It does not claim to represent exact bytes served, exact unique content, or a historical average.

Services that need:

- challengeable-only capacity;
- exact per-piece raw size;
- service-confirmed indexed bytes;
- unique-content capacity;
- a resource-set aggregate;

must use separate adapter types and user-visible product labels.

### 12.2 Prospective synchronization

PDP and FWSS expose current state, not an on-chain historical time series that Boss can query inside settlement. Boss therefore does not make a false claim of exact historical capacity billing.

Anyone may call:

```solidity
syncRate(subscriptionId)
```

The Boss account:

1. settles the rail through the current epoch under the old rate, caps, and quote validity;
2. verifies Filecoin Pay brought the rail current;
3. verifies the FWSS/PDP resource remains valid for the payer;
4. reads current leaf count;
5. computes current capacity and rate through the accepted adapter;
6. rejects a rate above `maxRatePerEpoch`;
7. updates the Filecoin Pay rail prospectively;
8. stores the rate and quote-validity boundary;
9. emits `RateSynchronized`.

If the payer is too underfunded for the rail to become current, synchronization fails and does not extend the old quote.

The caller cannot choose the rate.

### 12.3 Quote time-to-live

Every dynamic capacity offer contains `quoteTtlEpochs`.

Proposed public-MVP default:

```text
2,880 epochs ≈ one day
```

A successful synchronization records:

```text
quoteValidThroughEpoch = currentEpoch + quoteTtlEpochs
```

Boss validation pays the synchronized rate only through that boundary.

If no reconciler refreshes the quote:

- the nominal Filecoin Pay rate may remain nonzero;
- Boss returns zero payment for epochs after quote expiry;
- settlement advances through those epochs;
- a later synchronization restores payment prospectively;
- the expired gap is not retroactively charged.

This makes stale overpayment bounded and makes quote freshness a disclosed provider/reconciler responsibility.

A flat-rate adapter may return the accepted service expiry as its validity boundary and requires no heartbeat.

### 12.4 Event-driven reconciler

The reference reconciler watches:

- PDP pieces added;
- pieces scheduled and removed;
- dataset deletion;
- provider migration;
- Boss quote-near-expiry events;
- Filecoin Pay account solvency.

It calls only permissionless functions and holds no user key.

The provider has an incentive to synchronize increases. The user has an incentive to synchronize decreases. The TTL bounds the maximum period during which either side can rely on a stale capacity quote.

### 12.5 Underfunded rate changes

Filecoin Pay V1 may reject active-rail rate changes when the payer is underfunded, including decreases.

Boss handles this without allowing unbounded liability:

- the validator still enforces quote expiry, service expiry, pause, and lifetime cap;
- a failed synchronization emits a reason and leaves the previous prospective rate checkpoint unchanged;
- if the quote expires, subsequent epochs pay zero;
- owner termination remains available through the Boss operator;
- a hard-dependency resource deletion may trigger permissionless termination when the accepted policy allows it.

A failed rate decrease can continue to affect Filecoin Pay account-wide lockup accounting until termination even when Boss validation is zero-paying. Tooling must show this distinction.

### 12.6 Removal timing

The generic adapter changes capacity when the canonical on-chain `getDataSetLeafCount` value changes and a synchronization succeeds.

It does not stop billing merely because a removal was requested off-chain or scheduled but not yet reflected in the selected measurement. A service that promises different removal timing must use a different adapter.

---

## 13. Billing model C: capped CDN-style bandwidth

### 13.1 Immediate practical model

The first bandwidth model is:

> Trusted or attested usage reporting, bounded by a user-prepaid Filecoin Pay fixed lockup and explicit on-chain caps.

It deliberately does not claim that every delivered byte is cryptographically proven.

The first trust boundary is economic:

- the reporter may determine usage within the accepted model;
- the user determines the maximum exposure;
- the reporter cannot top up or raise a cap;
- no uncharged remainder becomes hidden debt.

### 13.2 Example offer

```json
{
  "serviceType": "CAPPED_EGRESS",
  "billingKind": "METERED_FIXED_LOCKUP",
  "pricePerTiB": "7000000000000000000",
  "maxSingleCharge": "2000000000000000000",
  "defaultBudget": "10000000000000000000",
  "reportingWindowEpochs": "11520",
  "assuranceKind": "TRUSTED_METERING",
  "reporter": "0x...",
  "autoTopUp": false
}
```

This means:

- gross price: 7 USDFC/TiB;
- four-day reporting windows for illustration;
- maximum single charge: 2 USDFC;
- initial fixed-lockup budget: 10 USDFC;
- no automatic top-up;
- the runtime stops or degrades when quota is exhausted.

### 13.3 Rail representation

The metered service uses its own Filecoin Pay rail:

```text
streaming rate:       0
fixed lockup:         accepted prepaid budget
operator:             BossAccount
validator:            BossAccount
beneficiary:          accepted service beneficiary
```

Filecoin Pay one-time payments do not invoke the validator. Boss must enforce all metered caps before it calls `modifyRailPayment`.

### 13.4 Usage claim

```solidity
struct UsageClaim {
    bytes32 claimId;
    uint64 fromEpoch;       // exclusive
    uint64 toEpoch;         // inclusive
    uint256 units;          // bytes for egress MVP
    bytes32 evidenceHash;
    string evidenceURI;
    uint256 nonce;
}
```

The reporter signs a domain-separated claim containing:

- chain ID;
- Boss account;
- subscription ID;
- claim ID;
- interval;
- units;
- evidence commitment;
- nonce.

Boss, not the reporter, computes the gross amount:

```text
rawGross = floor(reportedBytes × pricePerTiB / 2^40)
```

The amount actually charged is:

```text
chargedGross = min(
    rawGross,
    maxSingleCharge,
    remainingWindowCap,
    remainingLifetimeCap,
    currentRailFixedLockup
)
```

Boss records both `rawGross` and `chargedGross`. The truncated portion creates no debt.

### 13.5 Claim ordering

For the trusted MVP:

- intervals are monotonic;
- `toEpoch > fromEpoch`;
- `fromEpoch >= lastUsageToEpoch`;
- a claim must fit within one fixed billing window;
- claim ID and nonce are single-use;
- a terminated or expired subscription accepts no new claim;
- claim and payment execute atomically.

Gaps are allowed. Overlaps and replay are not.

### 13.6 Filecoin Pay allowance behavior

Executing a one-time payment consumes:

- rail fixed lockup;
- payer funds;
- Boss operator one-time-payment allowance headroom under Filecoin Pay V1.

Top-up is therefore a coordinated user flow:

1. optional Filecoin Pay deposit;
2. payer increases Boss operator `lockupAllowance` when necessary;
3. owner calls `BossAccount.topUpFixedBudget`.

No reporter, provider, or reconciler can perform these owner commitments.

### 13.7 Multiple recipients

A CDN and a cache-miss origin may need distinct beneficiaries.

Boss represents them as separate subscriptions and rails grouped in one bundle:

```text
CDN delivered-byte rail        -> CDN beneficiary
cache-miss origin-byte rail    -> origin/provider beneficiary
```

Each rail has its own budget and caps. The storefront presents the aggregate product but cannot hide either recipient.

### 13.8 Why a cap is the correct first boundary

Bandwidth is difficult to validate perfectly because:

- the reporter can fabricate logs;
- a client can withhold receipts;
- participants may collude;
- packet-level proofs are expensive;
- bytes delivered do not prove useful service;
- direct retrieval can bypass the measured path.

A prepaid cap transforms this from unbounded liability into a bounded commercial trust decision. The assurance label must remain `TRUSTED_METERING` until a stronger mechanism exists.

---

## 14. Metering validation and dispute extension

Immediate one-time payments cannot be clawed back through the Filecoin Pay validator. A disputable design must delay the charge.

### 14.1 Claim lifecycle

```text
REPORTED
   |
   v
CHALLENGEABLE ---- user/provider challenge ----> DISPUTED
   |                                                |
 window expires                                    v
   v                                          RESOLVED
ACCEPTED ------------------------------------------+
   |
   v
CHARGED
```

### 14.2 Evidence root

A reporter posts:

```text
root = MerkleRoot(
  requestId,
  resourceId,
  byteRange,
  bytesDelivered,
  status,
  startedAt,
  completedAt,
  servingNode,
  clientReceiptHash
)
```

The chain stores only aggregate units and the root.

### 14.3 Evidence sources

Possible later evidence, in increasing strength:

1. reporter-signed logs;
2. storage-provider counter-signatures for cache misses;
3. client or application session-key receipts;
4. independent checker attestations;
5. sampled request transcripts;
6. threshold attestations from multiple measurement nodes;
7. cryptographic delivery receipts;
8. bonded claims with fraud proofs.

Boss does not require one universal mechanism. The offer pins the verifier and dispute policy.

### 14.4 Dispute policy

```solidity
struct DisputePolicy {
    uint64 challengeWindowEpochs;
    address resolver;
    uint256 reporterBond;
    uint256 challengerBond;
    uint16 maxReductionBps;
    bytes32 evidenceSchema;
}
```

A resolver may be:

- deterministic contract logic;
- a mutually selected arbitrator;
- a threshold committee;
- an optimistic oracle;
- a future cryptographic verifier.

### 14.5 Resolution outcomes

- accept full claim;
- reduce units or amount;
- reject claim;
- slash reporter bond;
- slash frivolous challenger bond;
- refund or credit future service through a separate refund rail.

### 14.6 Settlement rule

Only `ACCEPTED` or `RESOLVED` claims can trigger the Filecoin Pay one-time payment.

This is the critical separation:

```text
usage report != payment
finalized invoice -> bounded Filecoin Pay payment
```

---

## 15. SLA and degradation semantics

### 15.1 Assurance classes

Boss surfaces one of five classes.

| Class | Meaning |
|---|---|
| `CANCELLABLE_ONLY` | No objective service proof; user pays while subscribed and can leave |
| `ONCHAIN_DETERMINISTIC` | Payment derives from on-chain state such as PDP capacity or proof periods |
| `TRUSTED_METERING` | Designated reporter controls usage reports, bounded by caps |
| `ATTESTED` | Usage or service state has one or more signed attestations |
| `DISPUTABLE` | Claims wait through an on-chain challenge and resolution process |

The UI must not label the first three as “trustless.”

### 15.2 Dependency policy

```solidity
enum DependencyMode {
    NONE,
    SOFT,
    HARD
}

struct DependencyPolicy {
    DependencyMode mode;
    bytes32 resourceId;
    uint64 graceEpochs;
    bool requireLiveDataset;
    bool requireRecentProof;
    uint64 maxProofAgeEpochs;
}
```

#### `NONE`

The service is independent. Example: a historical analytics subscription may continue after storage termination.

#### `SOFT`

The service becomes degraded or may pause, but does not automatically terminate. Example: a CDN may continue serving cached content after the origin dataset faults.

#### `HARD`

The service becomes non-billable or terminates when the resource is deleted or its declared condition fails.

### 15.3 Add-on failure

If service A degrades:

- A can be paused or terminated;
- base PDP storage continues;
- services B and C continue unless they explicitly depend on A;
- the user does not lose the bundle or resource.

### 15.4 Base storage fault

The current FWSS storage rail already uses PDP proof history to reduce or withhold storage payment for faulted periods.

Boss does not duplicate that logic for unrelated services.

Each add-on chooses whether a proof fault means:

- continue;
- degrade;
- stop new work;
- stop billing;
- terminate after grace.

### 15.5 Validator failure

A Boss account's cap validator is local and immutable.

External assurance modules must not be able to trap the user's rail. Any external callback used during validation should be:

- pinned by version;
- gas bounded;
- fail-safe;
- incapable of vetoing `railTerminated`.

### 15.6 Service pause

For a streaming service:

- funded account: Boss may set rate to zero;
- underfunded Filecoin Pay V1 account: Boss may need to terminate because a rate decrease can fail;
- resumption after termination creates a new rail and subscription version.

For a metered service:

- Boss disables new claims or the service runtime refuses requests;
- unused fixed lockup remains refundable after rail finalization.

---

## 16. Funding, runway, and spending caps

### 16.1 Account runway

Boss SDK reads Filecoin Pay's account state and displays:

- current funds;
- account-wide aggregate streaming rate;
- funded-until epoch;
- days of runway;
- current total lockup;
- available funds.

### 16.2 Per-subscription exposure

For each subscription, display:

- current rate;
- maximum accepted rate;
- lockup tail;
- fixed lockup;
- remaining lifetime cap;
- remaining metered quota;
- expiry;
- recent charges;
- trust class;
- dependency state.

### 16.3 Worst-case streaming exposure

For a subscription with:

- `maxRatePerEpoch = R`;
- `notAfter = E`;
- current epoch `N`;
- lockup period `L`;
- remaining lifetime cap `C`;

the maximum additional gross exposure is:

```text
min(C, R × max(0, E - N) + R × L)
```

The exact implementation must avoid double-counting a lockup tail already included in `C`.

### 16.4 Shared funding limitation

When base storage and Boss add-ons use the same payer and token:

- they share account runway;
- no service has priority;
- one add-on's streaming rate shortens the runway for all.

Boss must state this plainly.

### 16.5 Optional isolated budget account

For stronger isolation, the user may fund a user-owned smart account as the payer for Boss services.

```text
User's Filecoin Pay account       -> base FWSS storage only
BossBudgetAccount Pay account     -> add-ons only
```

This creates a hard financial boundary between storage and add-ons. It is especially attractive for metered or lower-trust services, but adds token-transfer and wallet UX complexity.

### 16.6 Bundle stop-together policy

A storefront may offer a `stopTogether` policy, but it is not the default.

Because Filecoin Pay has no native rail group transaction, a keeper or Boss validator enforces the policy. The user must understand that operational service suspension and on-chain settlement are separate processes.

---

## 17. Storefront and branded products

### 17.1 Storefront is a quote and presentation layer

A storefront may publish:

```solidity
struct BundleOffer {
    bytes32 bundleOfferId;
    address issuer;
    bytes32[] componentOfferIds;
    bytes32 presentationHash;
    bytes32 totalPricePolicyHash;
    uint64 validUntil;
    bool requireAllAddons;
}
```

The storefront may:

- curate service providers;
- present one name and total;
- receive a disclosed commission or separate service fee;
- operate a support or management service.

It does not acquire the user's underlying PDP resource.

### 17.2 Transparent composition mode

Recommended:

```text
FWSS storage component       -> storage provider
Filone management component  -> Filone
Indexing component           -> indexing provider
CDN component                -> CDN provider
Storefront fee, if any       -> storefront
```

The UI may show:

```text
Filone Storage — total estimated recurring price: 4.99 USDFC/TiB/month
```

but must also expose component recipients and caps.

### 17.3 Reseller mode

A reseller may accept one payment from the user and pay upstream providers itself.

This can still preserve data control if the resource is user-controlled, but it changes counterparty and solvency risk:

- the user no longer pays each upstream provider directly;
- upstream nonpayment can interrupt service;
- price components may be less transparent;
- the reseller becomes economically central.

Reseller mode is not recommended for Boss v1.

---

## 18. Filone pilot

The pilot should not wait for a complete ecosystem migration.

### 18.1 Semantic decision

Filone must choose one of two truthful product descriptions.

#### A. Branded total-price product

“Filone Storage costs 4.99 USDFC/TiB/month.”

Boss composes the actual FWSS recurring quote and a Filone service component so the displayed total meets the declared price policy.

The quote must account for the current FWSS flat per-dataset proving fee and any other recurring components. A hard-coded `2.49` surcharge does not produce an exact `4.99` total in every dataset-size case.

#### B. Base storage plus a distinct Filone service

```text
FWSS storage and proving: current on-chain quote
Filone managed service:   2.49 USDFC/TiB/month
```

This is simpler technically and more transparent if Filone is actually providing management, support, policy, repair coordination, access, or another distinct obligation.

### 18.2 Recommended first implementation

Use mode B unless Filone requires an exact inclusive total.

Create:

- `FiloneManagedStorage` service definition;
- `PDPCapacityAdapter` offer at the chosen per-TiB rate;
- one Boss subscription per dataset;
- no data-access capability unless Filone needs it;
- `CANCELLABLE_ONLY` assurance initially;
- explicit max rate and optional one-year cap;
- one-day or zero termination lockup;
- independent user termination.

### 18.3 Customer flow

```text
1. Filone publishes signed offer.
2. Synapse/Filecoin Pin quotes base FWSS + Filone.
3. User sees total, recipients, caps, and trust class.
4. User funds Filecoin Pay and approves their BossAccount.
5. PDP/FWSS dataset is created or selected.
6. BossAccount attaches Filone service and creates its rail.
7. Capacity sync tracks PDP leaf count.
8. User can terminate Filone without deleting or migrating storage.
```

### 18.4 What Filone does not need

Filone does not need:

- an FWSS fork;
- a global FWSS price change;
- ownership of the storage rail;
- control of the storage provider;
- a fake SLA before a service obligation is defined.

---

## 19. PDP verifier, proving, and SLA terminology

The current product already charges a flat per-dataset recurring proving component inside the FWSS storage rate.

Boss should distinguish:

1. **PDP verifier protocol:** on-chain proof verification primitive;
2. **storage provider proving obligation:** provider must submit valid possession proofs;
3. **proof-operation service:** an external actor monitors, relays, or manages proving;
4. **monitoring/SLA service:** alerts or remediates faults;
5. **repair service:** creates replacement replicas.

Only (3)-(5) are natural independent Boss add-ons.

A “PDP verifier as a service” offer must state what the provider actually does and what observable event earns payment. It should not charge merely for the existence of the public verifier contract unless that is transparently a protocol or storefront fee.

---

## 20. Downstream implementation map

The MVP introduces one new protocol repository and changes three existing product repositories. Existing Filecoin Pay, PDP, and FWSS production contracts remain source-pinned dependencies.

### 20.1 Required repository matrix

| Repository | Required MVP change | Explicit non-change |
|---|---|---|
| **new** `FilOzone/filecoin-boss` | Contracts, adapters, deployment package, Boss subgraph, examples, protocol docs | Does not replace Filecoin Pay or own storage |
| `FilOzone/synapse-sdk` | `@filoz/synapse-core/boss`, `synapse.services`, generated ABIs/addresses, funding and reconciliation | Does not duplicate storage upload implementation |
| `filecoin-project/filecoin-pin` | `services` command group and reference CLI flows | Does not implement contract rules locally |
| `FilOzone/filecoin-pay-explorer` | Boss semantic views and Pay/Boss rail join | Generic Pay subgraph remains generic |
| `FilOzone/filecoin-pay` | Compatibility tests and later docs only | No Boss fields or service semantics in V1 |
| `FilOzone/filecoin-services` | Optional stable view follow-up | No MVP storage-path or pricing change |
| `FilOzone/pdp` | None | No second listener or Boss-specific state |
| Curio / Beam | Later provider and reporter integration | Not an MVP blocker |

### 20.2 New `filecoin-boss` repository

Proposed top-level structure:

```text
filecoin-boss/
  SPEC.md
  IMPLEMENTATION.md
  SECURITY.md
  docs/adr/
  contracts/
    src/
      BossFactory.sol
      BossAccount.sol
      BossServiceRegistry.sol
      BossAdapterRegistry.sol
      BossStateView.sol
      interfaces/
      adapters/
      libraries/
    test/
      unit/
      integration/
      invariant/
      fork/
    script/
  packages/
    contracts/
    subgraph/
  examples/
    filone-storefront/
    flat-per-dataset/
    capped-egress-reporter/
  deployments/
```

Exact first contract files:

```text
contracts/src/BossFactory.sol
contracts/src/BossAccount.sol
contracts/src/BossServiceRegistry.sol
contracts/src/BossAdapterRegistry.sol
contracts/src/BossStateView.sol

contracts/src/interfaces/IBossAccount.sol
contracts/src/interfaces/IBossFactory.sol
contracts/src/interfaces/IBossPricingAdapter.sol
contracts/src/interfaces/IBossResourceAdapter.sol
contracts/src/interfaces/IFilecoinPayV1.sol
contracts/src/interfaces/IPDPVerifierView.sol
contracts/src/interfaces/IFWSSStateView.sol

contracts/src/adapters/FWSSPDPResourceAdapter.sol
contracts/src/adapters/FlatRateAdapter.sol
contracts/src/adapters/PDPCapacityAdapter.sol
contracts/src/adapters/CappedMeteredAdapter.sol

contracts/src/libraries/BossTypes.sol
contracts/src/libraries/BossErrors.sol
contracts/src/libraries/BossEvents.sol
contracts/src/libraries/OfferHashing.sol
contracts/src/libraries/ResourceHashing.sol
contracts/src/libraries/PricingMath.sol
contracts/src/libraries/FilecoinPayV1Compat.sol
```

Solidity target: `^0.8.27`.

Production code uses minimal interfaces. Integration tests import the exact source-locked Filecoin Pay V1 implementation.

### 20.3 `FilOzone/synapse-sdk`

The current repository contains `packages/synapse-core`, `packages/synapse-sdk`, and `packages/synapse-react`.

#### `synapse-core`

Add:

```text
packages/synapse-core/src/boss/
  index.ts
  types.ts
  offer.ts
  resource.ts
  pricing.ts
  account.ts
  funding.ts
  events.ts
  constants.ts
```

Modify:

```text
packages/synapse-core/src/abis/generated.ts
packages/synapse-core/src/abis/index.ts
packages/synapse-core/src/chains.ts
packages/synapse-core/src/errors/boss.ts
packages/synapse-core/src/errors/index.ts
packages/synapse-core/src/index.ts
packages/synapse-core/package.json
ABI generation configuration
```

`package.json` gains a `./boss` subpath export and matching `typesVersions` entry.

`chains.ts` gains:

```typescript
bossFactory
bossServiceRegistry
bossAdapterRegistry
bossStateView
```

#### high-level SDK

Add:

```text
packages/synapse-sdk/src/services/
  index.ts
  manager.ts
  quote.ts
  funding.ts
  execute.ts
  reconcile.ts
  subscriptions.ts
  types.ts
```

Modify:

```text
packages/synapse-sdk/src/synapse.ts
packages/synapse-sdk/src/types.ts
packages/synapse-sdk/src/index.ts
packages/synapse-sdk/src/errors/
packages/synapse-sdk/src/test/mocks/
```

The public API is:

```typescript
synapse.services.quote(...)
synapse.services.planFunding(...)
synapse.services.accept(...)
synapse.services.list(...)
synapse.services.sync(...)
synapse.services.pause(...)
synapse.services.resume(...)
synapse.services.terminate(...)
synapse.services.topUp(...)
```

The SDK returns every transaction stage separately. It must never imply that deposit, operator approval, and subscription acceptance are one atomic transaction.

#### React

After the core API stabilizes, add service hooks under:

```text
packages/synapse-react/src/services/
```

React is not required for the first CLI-only Calibration pilot.

### 20.4 `filecoin-project/filecoin-pin`

Add:

```text
src/commands/services.ts
src/core/services/
  index.ts
  catalog.ts
  quote.ts
  funding.ts
  execute.ts
  format.ts
  profiles.ts
```

Modify:

```text
src/commands/index.ts
src/cli.ts
src/config.ts
src/index-types.ts
src/core/payments/README.md
README.md
```

Command surface:

```text
filecoin-pin services catalog
filecoin-pin services quote
filecoin-pin services add
filecoin-pin services list
filecoin-pin services show
filecoin-pin services sync
filecoin-pin services pause
filecoin-pin services resume
filecoin-pin services stop
filecoin-pin services top-up
filecoin-pin services claims
```

Read-only commands should not require a private key when the underlying RPC reads do not.

Mutation commands show:

- every recipient;
- gross price;
- estimated provider net and fees;
- required deposit;
- operator approval delta;
- lockup and termination tail;
- rate, fixed, window, and lifetime caps;
- assurance and dependency;
- quote expiry;
- each transaction that will be signed.

`autoTopUp` defaults to false and is not implemented in the MVP.

### 20.5 `FilOzone/filecoin-pay-explorer`

The generic Filecoin Pay subgraph continues to index accounts, rails, rates, lockups, settlements, and one-time payments.

The new Boss subgraph lives in `filecoin-boss/packages/subgraph` and indexes commercial semantics.

Explorer adds a second GraphQL endpoint:

```text
NEXT_PUBLIC_BOSS_SUBGRAPH_URL_MAINNET
NEXT_PUBLIC_BOSS_SUBGRAPH_URL_CALIBRATION
```

Add:

```text
packages/types/src/boss.ts

apps/explorer/src/services/grapql/boss-client.ts
apps/explorer/src/services/grapql/boss-queries.ts
apps/explorer/src/services/grapql/boss-fragments.ts

apps/explorer/src/components/Services/
apps/explorer/src/components/Subscription/
apps/explorer/src/components/ResourceServices/
apps/explorer/src/components/shared/AssuranceBadge.tsx
apps/explorer/src/components/shared/DependencyBadge.tsx
apps/explorer/src/components/shared/SpendingCapSummary.tsx
```

Proposed routes:

```text
apps/explorer/src/app/[network]/services/page.tsx
apps/explorer/src/app/[network]/services/[subscriptionId]/page.tsx
apps/explorer/src/app/[network]/resources/pdp/[verifier]/[dataSetId]/services/page.tsx
apps/explorer/src/app/console/services/page.tsx
```

The existing rail page displays a Boss identity card when the rail resolves by chain, Pay contract, and rail ID.

### 20.6 Boss subgraph

Minimum entities:

- `BossAccount`;
- `ServiceProvider`;
- `ProviderSigningKey`;
- `ServiceDefinition`;
- `Resource`;
- `Bundle`;
- `Subscription`;
- `CapChange`;
- `RateSync`;
- `UsageClaim`;
- `AccessGrantEvent`.

The subgraph joins to Pay through:

```text
chainId + filecoinPay + railId
```

It does not duplicate generic Pay settlement accounting.

### 20.7 `FilOzone/filecoin-pay`

No production-contract change.

After the Boss contract surface stabilizes, add documentation for:

- user-owned composite operators;
- account-wide runway versus service-level presentation;
- Boss as validator and termination callback;
- one-time-payment allowance consumption.

Boss keeps an exact Filecoin Pay V1 integration suite in its own repository.

### 20.8 `FilOzone/filecoin-services`

No MVP change.

An optional later stable resource view may add:

```solidity
function getResourceBinding(uint256 dataSetId)
    external
    view
    returns (
        bool exists,
        address payer,
        address serviceProvider,
        address payee,
        uint256 pdpRailId,
        uint256 pdpEndEpoch
    );
```

Current `getDataSet` state-view behavior is sufficient for MVP and remains the compatibility source.

FWSSv2 may use ERC-8167 internally, but external Boss services remain separate contracts.

### 20.9 PDP, Curio, and Beam

PDP requires no change. Boss consumes current liveness, listener, leaf-count, storage-provider, and piece state.

Curio and Beam require no change for flat and capacity services. Later phases may add:

- provider provisioning acknowledgment;
- service status endpoint;
- usage-claim submission;
- reporter key rotation;
- quota exhaustion behavior.

### 20.10 Companion implementation documents

Detailed file ownership, signatures, transaction flows, PR dependencies, and acceptance criteria are in:

- `FILECOIN_BOSS_IMPLEMENTATION_DRAFT_v0.1.md`;
- `FILECOIN_BOSS_TEST_AND_ROLLOUT_PLAN_v0.1.md`.

Those documents may refine internal names, but cannot weaken this specification's authority, cap, recipient, termination, or resource-binding invariants.

---

## 21. Migration and compatibility

### 21.1 Existing FWSS datasets

Boss can attach to current datasets by verifying:

- PDP dataset is live;
- listener is the expected FWSS deployment;
- FWSS state view identifies the payer;
- resource has not been deleted;
- accepted service supports the network and contract versions.

No storage contract upgrade is required.

### 21.2 Existing embedded CDN

Treat current CDN rails as `LEGACY_EMBEDDED`:

- index and display them;
- do not attempt to take over operator authority;
- allow new Boss-native services alongside them;
- avoid double-enable warnings;
- offer migration only after unused lockup is returned and old rails are finalized.

### 21.3 Provider migration

Because PDP dataset ID remains stable:

- capacity-priced subscriptions continue;
- beneficiary does not change unless the add-on offer says it follows the storage provider;
- provider-specific cache-miss services may require a new beneficiary rail;
- the user signs any economically material rebind.

### 21.4 Dataset replacement

When data moves to a new dataset:

1. create new resource reference;
2. user signs `rebindResource`;
3. adapter verifies service compatibility;
4. old subscription rate goes to zero or rail terminates;
5. new subscription activates;
6. indexer links lineage.

### 21.5 Filecoin Pay version migration

Boss pins `payContract` per account and rail.

A new Pay version requires:

- a new Boss account or account version;
- explicit user approval;
- termination/finalization of old rails;
- recreated subscriptions;
- indexer lineage.

No contract should silently reinterpret V1 accounting under a new ABI.

---

## 22. Security invariants and required test suites

The complete matrix is maintained in `FILECOIN_BOSS_TEST_AND_ROLLOUT_PLAN_v0.1.md`. The following properties are normative release gates.

### 22.1 Authority invariants

1. Only the owner can increase any cap, budget, or expiry.
2. Only a valid provider-signed offer can set provider, beneficiary, token, adapters, pricing hash, commission, assurance, dependency, and terms.
3. Registry or adapter governance cannot mutate an accepted subscription.
4. The provider cannot change payer.
5. The storefront has no mutation authority after acceptance.
6. A reporter can submit only the accepted claim type and cannot top up.
7. Payment acceptance never implies data access.

### 22.2 Payment invariants

For every subscription:

```text
current rate <= maxRatePerEpoch
current fixed lockup <= maxFixedLockup
single usage charge <= maxSingleCharge
window spend <= maxChargePerWindow
settledGross + oneTimeChargedGross <= lifetimeCapGross
```

Additional requirements:

- Filecoin Pay beneficiary equals accepted beneficiary;
- token equals accepted token;
- commission fields equal accepted offer;
- validator never returns more than proposed;
- settlement after expiry or expired dynamic quote is zero;
- a price increase requires a new owner-authorized acceptance or cap transaction;
- retries cannot double-charge;
- gross means payer spend before Filecoin Pay fee and commission.

### 22.3 Exit invariants

1. Owner can request termination through Boss at any time.
2. Boss calls Filecoin Pay as operator, including while the payer is underfunded.
3. `railTerminated` never reverts.
4. `railTerminated` performs no external call.
5. Adapter, provider, reporter, storefront, or registry cannot veto termination.
6. Terminating an add-on never calls FWSS termination.
7. Pausing or terminating one add-on never changes another rail.
8. Dataset deletion cannot create new liability.

### 22.4 Resource invariants

1. Resource identity includes chain, verifier, kind, ID, and context.
2. Unsupported PDP or listener cannot masquerade as a supported FWSS resource.
3. FWSS payer must equal Boss payer.
4. Bare PDP storage-provider authority is not accepted as user authority.
5. Capacity math uses the exact documented aggregate conversion.
6. Deleted resources are non-billable.
7. Provider migration does not silently change an add-on beneficiary.
8. Resource-set membership is versioned.

### 22.5 Metering invariants

1. Claim IDs and nonces are single-use.
2. Usage intervals are monotonic and non-overlapping.
3. A claim fits within one billing window in MVP.
4. Boss computes price; reporter does not supply a trusted gross amount.
5. Charged amount is the minimum of raw amount and every remaining cap.
6. Truncated amount creates no debt.
7. A failed Filecoin Pay charge rolls back claim state.
8. Top-up requires owner and any necessary Filecoin Pay approval transaction.

### 22.6 Exact contract test files

Required Foundry unit suites:

```text
contracts/test/unit/BossFactory.t.sol
contracts/test/unit/OfferHashing.t.sol
contracts/test/unit/BossServiceRegistry.t.sol
contracts/test/unit/OfferVerification.t.sol
contracts/test/unit/BossAdapterRegistry.t.sol
contracts/test/unit/FWSSPDPResourceAdapter.t.sol
contracts/test/unit/FlatRateAdapter.t.sol
contracts/test/unit/PDPCapacityAdapter.t.sol
contracts/test/unit/CappedMeteredAdapter.t.sol
contracts/test/unit/BossAccountAccept.t.sol
contracts/test/unit/BossAccountActivation.t.sol
contracts/test/unit/BossAccountValidation.t.sol
contracts/test/unit/BossAccountLifecycle.t.sol
contracts/test/unit/BossCaps.t.sol
contracts/test/unit/BossUsageClaims.t.sol
contracts/test/unit/BossBundle.t.sol
```

Required integration suites:

```text
contracts/test/integration/FilecoinPayV1Acceptance.t.sol
contracts/test/integration/FilecoinPayV1Settlement.t.sol
contracts/test/integration/FilecoinPayV1Underfunded.t.sol
contracts/test/integration/FilecoinPayV1OneTimePayment.t.sol
contracts/test/integration/FilecoinPayV1TerminationCallback.t.sol
contracts/test/integration/FilecoinPayV1KnownBehavior.t.sol
contracts/test/integration/FWSSResourceBinding.t.sol
contracts/test/integration/PDPCapacityLifecycle.t.sol
contracts/test/integration/FWSSIndependence.t.sol
```

Required invariant suites:

```text
contracts/test/invariant/BossSpend.invariant.t.sol
contracts/test/invariant/BossAuthority.invariant.t.sol
contracts/test/invariant/BossLifecycle.invariant.t.sol
contracts/test/invariant/MeteredWindows.invariant.t.sol
```

### 22.7 Filecoin Pay V1 compatibility lock

Tests must explicitly preserve the behaviors Boss depends on:

- account-wide runway;
- aggregate operator allowance;
- active underfunded rate-change rejection;
- operator termination while underfunded;
- synchronous validator callback;
- payer-only full-payment terminated-rail escape;
- one-time-payment lockup and allowance consumption;
- rate-change queue validation;
- finalization;
- known lockup-usage leak behavior;
- validator-note behavior.

A Filecoin Pay version change requires a new compatibility suite, deployment manifest, and Boss account version.

### 22.8 TypeScript, CLI, indexer, and UI suites

Required Synapse tests:

```text
packages/synapse-core/test/boss/*.test.ts
packages/synapse-sdk/src/test/services-manager.test.ts
packages/synapse-sdk/src/test/services-quote.test.ts
packages/synapse-sdk/src/test/services-funding.test.ts
packages/synapse-sdk/src/test/services-execute.test.ts
packages/synapse-sdk/src/test/services-reconcile.test.ts
packages/synapse-sdk/src/test/services-metered.test.ts
```

Required Filecoin Pin tests:

```text
src/test/unit/services-catalog.test.ts
src/test/unit/services-quote.test.ts
src/test/unit/services-funding.test.ts
src/test/unit/services-add.test.ts
src/test/unit/services-actions.test.ts
src/test/unit/services-format.test.ts
src/test/integration/services-cli.test.ts
```

Required index/UI tests:

- Matchstick test for every Boss event;
- subgraph rebuild determinism;
- Pay/Boss join-key collision tests;
- assurance, dependency, recipient, and cap component tests;
- mixed Boss and non-Boss rail page;
- complete quote-to-termination browser flow.

### 22.9 End-to-end release scenario

The release harness must:

1. deploy exact Filecoin Pay, PDP, FWSS, and Boss stack;
2. create an FWSS-backed dataset;
3. attach flat, capacity, and metered services;
4. settle streaming rails;
5. change capacity and sync prospectively;
6. submit a capped usage claim;
7. underfund the payer;
8. pause one service and terminate another;
9. prove the FWSS rail remains active;
10. finalize Boss rails;
11. query both subgraphs;
12. run Filecoin Pin and render Explorer views.

### 22.10 Security gates

Before mainnet:

- Foundry unit, fuzz, and invariant suites;
- real Filecoin Pay V1 integration;
- PDP/FWSS integration;
- Node and browser SDK tests;
- CLI golden-output tests;
- Matchstick and Explorer tests;
- static analysis;
- internal independent review;
- external contract audit;
- deterministic deployment rehearsal;
- source verification;
- incident and migration drills.

Any path that can exceed a cap, redirect a beneficiary, replay a claim, or block termination is release-blocking.

---

## 23. Ordered implementation and pull-request plan

### Phase 0 — semantic lock

#### BOSS-000: source-locked document set

Artifacts:

```text
SPEC.md
IMPLEMENTATION.md
SECURITY.md
docs/adr/0001-user-owned-bundle.md
docs/adr/0002-one-service-one-rail.md
docs/adr/0003-boss-as-operator-and-validator.md
docs/adr/0004-resource-identity.md
docs/adr/0005-trust-classes.md
docs/adr/0006-capacity-quote-validity.md
docs/adr/0007-no-upgrade-account-versions.md
```

Acceptance:

- authority nouns are unambiguous;
- Filone product choices are isolated from protocol choices;
- exact source revisions are recorded;
- no production code precedes acceptance of cap and termination invariants.

### Phase 1 — protocol primitives

#### PR A1: types, hashing, and interfaces

Files:

```text
BossTypes.sol
OfferHashing.sol
ResourceHashing.sol
IBossAccount.sol
IBossPricingAdapter.sol
IBossResourceAdapter.sol
IFilecoinPayV1.sol
```

Acceptance:

- fixed Solidity/TypeScript EIP-712 vectors;
- fixed resource and subscription ID vectors;
- no implementation storage yet.

#### PR A2: service and adapter registries

Acceptance:

- provider key rotation;
- offer nonce revocation;
- adapter interface/codehash pinning;
- deactivation affects only new subscriptions.

#### PR A3: factory and immutable accounts

Acceptance:

- deterministic CREATE2 clone;
- implementation version cannot be overwritten;
- factory has no control of account;
- account initialization replay impossible.

### Phase 2 — first working payment service

#### PR A4: flat streaming Boss account

Implements:

- offer acceptance;
- Filecoin Pay rail creation;
- caps and expiry;
- validation;
- pause;
- operator termination;
- reconciliation.

Acceptance:

- 1 USDFC/dataset/30-day example works end to end;
- owner terminates while underfunded;
- FWSS rail untouched;
- all Filecoin Pay V1 integration tests pass.

#### PR A5: FWSS-backed PDP resource adapter

Acceptance:

- correct payer attaches;
- wrong payer, chain, verifier, listener, or deleted dataset rejected;
- provider migration does not rewrite payer or add-on beneficiary.

### Phase 3 — deterministic dynamic pricing

#### PR A6: capacity adapter and quote TTL

Acceptance:

- canonical raw-byte conversion;
- permissionless prospective sync;
- one-day default quote validity;
- expired quote zeroes future payment;
- refresh restores payment prospectively;
- no historical billing claim.

### Phase 4 — capped metering

#### PR A7: metered fixed-lockup subscription

Acceptance:

- trusted reporter claims;
- Boss computes price;
- replay and overlap rejected;
- every cap enforced;
- no hidden debt;
- explicit owner top-up and Pay allowance plan.

### Phase 5 — batch, views, deployment, indexing

#### PR A8: bundle and state view

Acceptance:

- bounded atomic batch;
- independent component lifecycle;
- complete semantic events;
- paginated views.

#### PR A9: Calibration deployment and ABI package

Acceptance:

- source-verified contracts;
- deterministic manifest;
- published `@filoz/filecoin-boss-contracts` package;
- start blocks recorded.

#### PR A10: Boss subgraph

Acceptance:

- full event mapping;
- Matchstick suite;
- deterministic rebuild;
- stable rail join key.

### Phase 6 — Synapse

#### PR B0: `synapse-core/boss`

- types;
- hashes;
- ABIs and addresses;
- resource constructors;
- low-level reads;
- quote and funding math.

#### PR B1: `synapse.services`

- quote;
- plan;
- execute;
- lifecycle;
- reconciliation;
- typed partial-failure recovery.

Acceptance:

- Node and browser tests;
- each transaction stage visible;
- no unsupported chain silently falls back.

#### PR B2: React hooks

Optional for initial CLI pilot.

### Phase 7 — Filecoin Pin

#### PR C0: read-only commands

```text
catalog
quote
list
show
```

#### PR C1: acceptance and funding

```text
add
```

Acceptance:

- complete economic disclosure;
- confirm each transaction plan;
- safe resume after partial completion.

#### PR C2: lifecycle commands

```text
sync
pause
resume
stop
top-up
claims
```

### Phase 8 — Explorer

#### PR D0: Boss GraphQL client and types

#### PR D1: service and resource pages

#### PR D2: Boss identity on generic Pay rail pages

#### PR D3: console mutation actions

Mutation UI waits for stable SDK lifecycle APIs.

### Phase 9 — Filone pilot

#### PR E0: Filone offer and storefront example

Required decisions:

- exact 4.99 total versus 2.49 independent component;
- beneficiary and commission;
- actual service obligation;
- access scope;
- quote TTL;
- lockup and termination billing;
- provider acknowledgment.

Recommended first offer:

```text
2.49 USDFC/TiB/30 days
separate Filone beneficiary rail
CANCELLABLE_ONLY
no data access
one-day capacity quote TTL
zero- or one-day termination tail
```

#### PR E1: Calibration pilot runbook and monitoring

Acceptance:

- repeated quote refresh;
- accounting reconciliation;
- underfunded termination drill;
- provider signing-key rotation;
- subgraph rebuild.

### Phase 10 — mainnet gates

Mainnet limited release requires:

- external audit closure;
- multisig and adapter-governance procedure;
- monitoring and permissionless reconciler;
- source verification;
- fixed maximum pilot exposure;
- no automatic top-up;
- account-version migration rehearsal.

The detailed rollout gates are in `FILECOIN_BOSS_TEST_AND_ROLLOUT_PLAN_v0.1.md`.

---

## 24. MVP release definition

The smallest coherent release contains:

1. `BossFactory`;
2. per-user `BossAccount`;
3. signed offers;
4. one rail per subscription;
5. immutable cap/expiry validation;
6. unconditional owner-requested operator termination;
7. `FlatRateAdapter`;
8. `PDPCapacityAdapter`;
9. `CappedMeteredAdapter` with trusted reporting and fixed-lockup cap;
10. Boss state view and event schema;
11. Synapse SDK service manager;
12. Filecoin Pin commands;
13. Boss subgraph;
14. Filone example storefront.

It explicitly excludes disputes from the release gate, provided the UI labels metered services as trusted and the cap is hard.

---

## 25. Decisions still requiring product input

Only a small number of choices remain product-specific.

### 25.1 Filone semantics

Is `4.99`:

- the exact inclusive total recurring price;
- `4.99/TiB/month` plus the FWSS per-dataset proving fee;
- base FWSS plus a separately stated Filone fee?

### 25.2 Filone obligation

What does Filone deliver beyond access to the same base storage mechanism?

Possible truthful definitions:

- managed storage account;
- support and monitoring;
- provider curation;
- repair coordination;
- application gateway;
- SLA response;
- billing/storefront service.

### 25.3 Default termination tail

Should low-assurance add-ons have:

- zero lockup;
- one day;
- another disclosed notice period?

### 25.4 Capacity measurement

Should the generic service bill:

- committed bytes;
- challengeable bytes;
- service-confirmed bytes?

### 25.5 Funding isolation

Should the default use:

- the user's existing Filecoin Pay account;
- a separately funded Boss budget account for all add-ons;
- optional selection per bundle?

### 25.6 Registry policy

Should the official UI:

- show any signed offer;
- show unregistered offers with warning;
- require an endorsed-provider list by default?

These do not block the protocol architecture.

---

## 26. Recommended final answers to the raw design questions

### “What happens if payment runs low?”

All streaming rails using the same payer/token share an account-wide funded horizon. Boss shows that runway globally. Each service has an independent suspension policy and cap. Metered services stop when prepaid quota is exhausted. Strict storage-versus-add-on priority requires a separate Boss budget account.

### “Do all services stop at the same time?”

Not by default. Their financial settlement horizon is shared, but their runtimes and dependencies are independent. A bundle may opt into a coordinated stop policy.

### “What happens if service A degrades?”

A becomes `DEGRADED`, `PAUSED`, or `TERMINATING` according to its policy. PDP storage and unrelated services continue.

### “What happens if PDP degrades?”

The FWSS proof-linked storage payment follows its existing validator. Each add-on follows its declared dependency policy. Cached retrieval may continue; indexing may pause; monitoring may remain active.

### “Does Mike or Jenni own the deal?”

Neither add-on provider owns the bundle or PDP resource merely by being attached. The PDP storage provider retains its protocol-defined operational role. The user owns the Boss bundle and billing choices. Mike and Jenni each own their commercial offer and receive only the authority explicitly accepted for their service.

### “Who owns bundling?”

The user. A storefront publishes a bundle offer; the accepted bundle is user-authorized and cannot be changed unilaterally.

### “Can one service span multiple deals?”

Yes. Attach it to a versioned resource set and define whether pricing is per dataset, aggregate capacity, unique content, or metered usage.

### “How should SLA work?”

Start with explicit trust classes and independent exit. Use deterministic PDP state where available. For bandwidth, use capped trusted reporting first, then delayed claims, evidence roots, bonds, and dispute resolution.

### “Should this be an ERC-8167 FWSS module?”

No. ERC-8167 is useful for FWSSv2's internal implementation modularity. Independently governed services should be separate contracts with shared Boss interfaces and separate Filecoin Pay rails.

---

## 27. Source lock

This revision was reconciled against live repository heads on 2026-08-12.

| Repository | Branch | Revision inspected |
|---|---|---|
| `FilOzone/filecoin-pay` | `main` | `04ded6af6c15c4b5d98545f393dc656004d4aede` |
| `FilOzone/filecoin-services` | `main` | `54885b9ad04915888ba627ae6bae94df58d68c81` |
| `FilOzone/pdp` | `main` | `4d2a930194367477050302792de89e29275a6047` |
| `FilOzone/synapse-sdk` | `master` | `811163e609cab96b8e089dd972632b221a96e8a7` |
| `filecoin-project/filecoin-pin` | `master` | `27b65c4d7314fb8539d2d5fcee06a2ab03fa4d21` |
| `FilOzone/filecoin-pay-explorer` | `main` | `0e0a7683ec20415f53f4807151221673f1590faa` |

Path-level implementation planning was checked against:

- `filecoin-pay`: `src/`, `test/`, `docs/`, `SPEC.md`;
- `filecoin-services`: FWSS contract, rails library, price list, and state view;
- `pdp`: verifier interfaces and dataset state views;
- `synapse-sdk`: `packages/synapse-core`, `packages/synapse-sdk`, `packages/synapse-react`, explicit package exports, chain contract map, and tests;
- `filecoin-pin`: `src/commands`, `src/core`, and unit/integration test layout;
- `filecoin-pay-explorer`: App Router structure, current GraphQL service layout, shared types, generic Pay subgraph, and Matchstick tests.

Primary semantic references:

- Filecoin Pay concepts, integration guide, monitoring guide, implementation specification, and `FilecoinPayV1.sol`;
- FWSS specification, state view, pricing constants, and current PDP/CDN rail behavior;
- PDP verifier design and public read interfaces;
- Synapse payment, storage, chain, and ABI-generation architecture;
- Filecoin Pin payment and command architecture;
- Filecoin Pay Explorer generic rail schema;
- Filecoin Services issues concerning contract modularity, service enablement, IPFS indexing, and FWSSv2;
- ERC-8167 as an FWSSv2 internal modularity decision rather than the external service-composition protocol.

A later implementation PR must update this table if any dependency head or deployed contract changes before coding begins.

---

## 28. Document and repository artifact set

This v0.2 design is delivered as a source-locked document set:

```text
FILECOIN_BOSS_SPEC_v0.2.md
FILECOIN_BOSS_IMPLEMENTATION_DRAFT_v0.1.md
FILECOIN_BOSS_TEST_AND_ROLLOUT_PLAN_v0.1.md
FILECOIN_BOSS_HUMAN_SUMMARY_v0.1.md
FILECOIN_BOSS_DOCUMENT_SET_INDEX.md
```

The first repository PR should import the accepted versions as:

```text
SPEC.md
IMPLEMENTATION.md
SECURITY.md
README.md
docs/adr/
```

Production Solidity should begin only after:

- authority and recipient invariants are accepted;
- quote-TTL semantics are accepted;
- Filecoin Pay V1 termination and pause behavior are accepted;
- the Filone offer is clearly separated from the generic protocol;
- the test plan is reviewed by an independent Filecoin Pay accounting owner.

The technical implementation draft is deliberately close to a code skeleton, but it is not represented as audited or compiling production code.
