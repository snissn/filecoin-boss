# Filecoin Boss
## Sovereign service composition over PDP, FWSS, and Filecoin Pay

**Status:** Design draft v0.1  
**Date:** 2026-08-09  
**Scope:** Protocol specification and implementation plan  
**Source lock:** Live repository state inspected on 2026-08-09; exact commits are listed in §27.

---

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

## 6. Core objects

### 6.1 Resource reference

```solidity
enum ResourceKind {
    PDP_DATASET,
    PDP_RESOURCE_SET,
    GENERIC_CONTENT_ROOT
}

struct ResourceRef {
    ResourceKind kind;
    uint64 chainId;
    address anchor;
    uint256 id;
    bytes32 version;
}
```

For `PDP_DATASET`:

- `anchor` is the PDP verifier;
- `id` is the dataset ID;
- `version` is normally zero.

For `PDP_RESOURCE_SET`:

- `anchor` is a Boss `ResourceSetRegistry`;
- `id` identifies a versioned set;
- `version` commits to membership.

A resource reference does not by itself prove that the payer is authorized to attach services. Boss resolves that separately through a versioned resource adapter:

- **FWSS-backed PDP:** require the dataset's listener to be an explicitly supported FWSS deployment and require its on-chain dataset record to name the accepted payer.
- **Bare PDP:** do not infer user ownership from the storage-provider role. Require an explicit resource-binding authorization from a supported listener/controller or a user-owned resource registry.
- **Generic content root:** require a domain-specific ownership or control proof defined by the adapter.

Bare PDP resource binding is outside the first MVP unless a concrete authorization interface is standardized. This avoids turning “knows a dataset ID” into authority to create a misleading commercial attachment.

### 6.2 Resource set

A resource set lets one service cover:

- two storage replicas;
- several datasets belonging to one application;
- a logical content collection;
- a multi-provider retrieval pool.

```solidity
struct ResourceSet {
    address owner;
    bytes32 membershipRoot;
    uint64 version;
    uint64 createdAt;
}
```

Membership changes produce a new version and require owner authorization. Existing subscriptions either:

- remain pinned to the old version;
- automatically follow versions under a bounded policy;
- require an explicit rebind.

### 6.3 Service definition

A service definition describes a service type independently of a commercial offer.

```solidity
struct ServiceDefinition {
    bytes32 serviceType;
    string name;
    string description;
    string metadataURI;
    bytes32 interfaceId;
    bytes32 accessScopeSchema;
}
```

Examples:

- `FLAT_DATASET_SERVICE`
- `CAPACITY_SERVICE`
- `CAPPED_EGRESS`
- `PDP_MONITORING`
- `IPFS_INDEXING`
- `REPAIR_COORDINATION`

### 6.4 Signed offer

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

struct ServiceOffer {
    bytes32 offerId;
    uint64 version;
    address issuer;
    address serviceProvider;
    address beneficiary;
    address adapter;
    address token;
    bytes32 serviceType;
    BillingKind billingKind;
    AssuranceKind assuranceKind;
    bytes32 pricingDataHash;
    bytes32 termsHash;
    uint64 validFrom;
    uint64 validUntil;
    uint64 defaultLockupPeriod;
    uint256 commissionBps;
    address commissionRecipient;
}
```

Offers are EIP-712 signed. The signature domain includes chain ID and the Boss protocol deployment.

An optional registry supports discovery, identity, and revocation. Registration is not itself an assurance claim.

### 6.5 Acceptance and cap policy

```solidity
struct CapPolicy {
    uint256 maxRatePerEpoch;
    uint256 maxFixedLockup;
    uint256 maxSingleCharge;
    uint256 maxChargePerWindow;
    uint64 chargeWindowEpochs;
    uint256 lifetimeCap;
    uint64 notAfter;
    uint64 maxLockupPeriod;
}

struct ServiceAcceptance {
    bytes32 offerId;
    uint64 offerVersion;
    bytes32 resourceId;
    address payer;
    CapPolicy caps;
    bytes32 accessGrantHash;
    bytes32 dependencyPolicyHash;
    uint256 nonce;
    uint64 deadline;
}
```

The effective cap is the minimum of:

- offer limits;
- user acceptance limits;
- Filecoin Pay operator approval headroom;
- current rail lockup;
- current account funding.

### 6.6 Subscription

```solidity
enum SubscriptionState {
    NONE,
    ACTIVE,
    PAUSED,
    TERMINATING,
    ENDED,
    DISPUTED
}

struct Subscription {
    bytes32 subscriptionId;
    bytes32 offerId;
    uint64 offerVersion;
    bytes32 resourceId;
    address owner;
    address payer;
    address serviceProvider;
    address beneficiary;
    address adapter;
    address token;
    uint256 railId;
    BillingKind billingKind;
    AssuranceKind assuranceKind;
    CapPolicy caps;
    uint256 grossPaid;
    uint256 acceptedRate;
    uint64 startedAt;
    uint64 terminatedAt;
    SubscriptionState state;
}
```

`grossPaid` means payer spend before Filecoin Pay's network fee and commission deductions.

### 6.7 Bundle

```solidity
struct Bundle {
    bytes32 bundleId;
    address owner;
    bytes32 resourceSetId;
    bytes32 storefrontOfferId;
    uint64 version;
}
```

The bundle is an indexable ownership and presentation object. It does not custody data or funds.

---

## 7. Contract architecture

```text
                          signed offers
 Service provider  ------------------------------+
                                                   |
 Storefront ------------------------------------+ |
                                                | |
                                                v v
 User wallet ---- owns ----> BossAccount <---- ServiceRegistry
      |                         |
      | accepts offer           | operator + validator
      |                         |
      |                         +---- Filecoin Pay add-on rail A ---> Mike service
      |                         +---- Filecoin Pay add-on rail B ---> Jenni service
      |                         +---- Filecoin Pay metered rail  C ---> CDN
      |
      +---- existing FWSS flow ---- Filecoin Pay storage rail ------> Storage provider
                                      |
                                      +---- PDP/FWSS proof validation

 BossAccount subscriptions ---- reference ----> PDP dataset / resource set
 Access grants ----------------- separately ---> service runtime
```

### 7.1 `BossFactory`

Responsibilities:

- deploy versioned per-user Boss accounts;
- provide deterministic account addresses;
- publish implementation versions;
- never control deployed accounts.

Recommended deployment: immutable ERC-1167 clones or equivalent minimal accounts pinned to a non-upgradeable implementation version.

```solidity
interface IBossFactory {
    function createAccount(address owner, address payContract)
        external
        returns (address account);

    function accountOf(address owner, address payContract)
        external
        view
        returns (address);
}
```

### 7.2 `BossAccount`

The Boss account is the core sovereignty primitive.

It is:

- owned by one user or smart account;
- approved as a Filecoin Pay operator by the payer;
- the validator for the rails it creates;
- incapable of arbitrary delegatecall to service adapters;
- versioned and non-upgradeable after deployment.

Responsibilities:

- verify signed offers and user acceptance;
- verify resource binding and payer authority;
- create rails;
- set initial rate and lockup;
- enforce rate, time, per-charge, and lifetime caps;
- call deterministic pricing adapters;
- record usage claims;
- execute finalized metered charges;
- implement Filecoin Pay validation;
- terminate at the owner's request;
- emit graph events.

Important callback rule:

`railTerminated` must be callable during the nested Filecoin Pay termination call and must never revert. A global reentrancy guard must not accidentally veto this callback.

Core interface:

```solidity
interface IBossAccount {
    function acceptOffer(
        ServiceOffer calldata offer,
        bytes calldata offerSignature,
        ServiceAcceptance calldata acceptance,
        bytes calldata ownerSignature,
        ResourceRef calldata resource,
        bytes calldata pricingData
    ) external returns (bytes32 subscriptionId, uint256 railId);

    function sync(bytes32 subscriptionId, bytes calldata evidence) external;

    function pause(bytes32 subscriptionId) external;

    function terminate(bytes32 subscriptionId) external;

    function increaseBudget(
        bytes32 subscriptionId,
        CapPolicy calldata newCaps,
        bytes calldata ownerSignature
    ) external;

    function subscription(bytes32 subscriptionId)
        external
        view
        returns (Subscription memory);
}
```

### 7.3 Boss as Filecoin Pay validator

For streaming rails, the Boss account supplies an immutable cap and expiry validator.

Simplified validation:

```solidity
function validatePayment(
    uint256 railId,
    uint256 proposedAmount,
    uint256 fromEpoch,
    uint256 toEpoch,
    uint256 rate
) external onlyFilecoinPay returns (ValidationResult memory result) {
    Subscription storage s = subscriptionByRail[railId];

    uint256 expiry =
        s.caps.notAfter == 0 ? type(uint64).max : s.caps.notAfter;
    uint256 eligibleTo = min(toEpoch, expiry);

    bool billableState =
        s.state == SubscriptionState.ACTIVE ||
        s.state == SubscriptionState.TERMINATING;

    uint256 billableRate = min(rate, s.caps.maxRatePerEpoch);
    uint256 timeAllowed =
        billableState && eligibleTo > fromEpoch
            ? (eligibleTo - fromEpoch) * billableRate
            : 0;

    uint256 remaining =
        s.caps.lifetimeCap == 0
            ? type(uint256).max
            : s.grossPaid >= s.caps.lifetimeCap
                ? 0
                : s.caps.lifetimeCap - s.grossPaid;

    uint256 modified = min(proposedAmount, min(timeAllowed, remaining));

    s.grossPaid += modified;

    return ValidationResult({
        modifiedAmount: modified,
        settleUpto: toEpoch,
        note: modified == proposedAmount ? "boss: accepted" : "boss: capped"
    });
}
```

The real implementation must additionally handle:

- fixed-window caps;
- rate-change segments;
- dependency policies;
- terminated subscriptions;
- zero-cap and unlimited-cap encodings;
- exact epoch boundary semantics;
- overflow and reentrancy;
- Pay V1's validator-note behavior.

The validator advances settlement through non-billable expired epochs with zero payment. A provider cannot continue accumulating debt after `notAfter`.

### 7.4 `IServicePricingAdapter`

Adapters are versioned contracts called through `staticcall` or a strictly bounded normal call. Boss never `delegatecall`s into a provider-selected adapter.

```solidity
struct PricingQuote {
    address token;
    uint256 initialRatePerEpoch;
    uint256 maxRatePerEpoch;
    uint256 initialFixedLockup;
    uint64 lockupPeriod;
    bytes32 quoteHash;
}

interface IServicePricingAdapter {
    function quote(
        ResourceRef calldata resource,
        bytes calldata pricingData
    ) external view returns (PricingQuote memory);

    function currentRate(
        ResourceRef calldata resource,
        bytes calldata pricingData
    ) external view returns (uint256);
}
```

V1 adapters:

- `FlatRateAdapter`
- `PDPCapacityAdapter`
- `CappedMeteredAdapter`

### 7.5 `BossServiceRegistry`

The registry is for discovery and provenance, not custody or mandatory permissioning.

It records:

- service definitions;
- provider identities;
- supported adapters;
- metadata URIs;
- optional audit and assurance claims;
- offer revocations.

A user may accept an unregistered offer, but the SDK must label it as such.

### 7.6 `BossStateView`

A dedicated view contract or library provides paginated reads:

- subscriptions by owner;
- subscriptions by resource;
- subscriptions by service provider;
- bundle components;
- cap remaining;
- accepted versus current rate;
- rail state;
- dependency state;
- metered claims;
- computed funding runway.

### 7.7 Events

At minimum:

```solidity
event BossAccountCreated(address indexed owner, address indexed account, uint64 version);

event OfferAccepted(
    bytes32 indexed subscriptionId,
    bytes32 indexed offerId,
    bytes32 indexed resourceId,
    address owner,
    address payer,
    address serviceProvider,
    address beneficiary,
    uint256 railId
);

event SubscriptionRateChanged(
    bytes32 indexed subscriptionId,
    uint256 oldRate,
    uint256 newRate
);

event SubscriptionBudgetChanged(
    bytes32 indexed subscriptionId,
    uint256 oldFixedLockup,
    uint256 newFixedLockup,
    uint256 oldLifetimeCap,
    uint256 newLifetimeCap
);

event UsageClaimed(
    bytes32 indexed subscriptionId,
    bytes32 indexed claimId,
    uint64 fromEpoch,
    uint64 toEpoch,
    uint256 units,
    uint256 grossAmount,
    bytes32 evidenceRoot
);

event UsageFinalized(bytes32 indexed claimId, uint256 grossAmount);
event UsageDisputed(bytes32 indexed claimId, address indexed challenger, bytes32 evidenceHash);

event SubscriptionPaused(bytes32 indexed subscriptionId);
event SubscriptionTerminated(bytes32 indexed subscriptionId, uint256 railId, uint256 endEpoch);
event SubscriptionEnded(bytes32 indexed subscriptionId);
event ResourceRebound(bytes32 indexed subscriptionId, bytes32 oldResourceId, bytes32 newResourceId);
```

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

For PDP leaf count `L`, Boss should mirror the current canonical FWSS conversion from data-bearing Fr32 leaves to approximate raw bytes:

```text
billableBytes = floor(L × 32 × 127 / 128)
```

This is the behavior of `Cids.leafCountToRawSize`. It approximates raw bytes from the aggregate leaf count and may overestimate by up to 31 bytes per piece. An adapter that requires exact per-piece raw capacity must enumerate the live PieceCIDv2 records, derive each piece's exact `rawPieceSize(padding, height)`, and sum them. The generic v1 adapter should use the canonical aggregate approximation so its capacity semantics match FWSS.

The per-epoch rate is calculated multiply-first:

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

The offer must specify which PDP measurement is billable.

Options:

1. **Committed approximate raw bytes:** `floor(getDataSetLeafCount × 32 × 127 / 128)`  
   Mirrors FWSS's current `Cids.leafCountToRawSize` conversion and includes pieces already added to the dataset, including additions not yet incorporated into the current challenge range. It is an aggregate approximation rather than an exact sum of per-piece raw sizes.

2. **Currently challengeable bytes:** derived from challenge range  
   Better when payment should begin only after the next proving-period transition.

3. **Service-indexed bytes:** service acknowledges successful ingestion and bills only its own indexed subset.

Boss v1's generic `PDPCapacityAdapter` should support committed approximate raw bytes using the canonical FWSS conversion. Services needing exact per-piece raw bytes or another billing definition should use a distinct, auditable adapter and service type.

### 12.2 Permissionless synchronization

Anyone may call:

```solidity
sync(subscriptionId)
```

The Boss account:

1. reads current PDP capacity;
2. computes the deterministic rate;
3. clamps it to the accepted maximum;
4. changes the rail rate if allowed;
5. emits `SubscriptionRateChanged`.

Keepers and providers can perform this call, but they cannot choose the rate.

### 12.3 Underfunded-rate-change behavior

Filecoin Pay V1 may reject active-rail rate changes when the payer account is underfunded, including decreases.

Boss handles this as follows:

- if the account is funded, update the rate;
- if a hard dependency has ended and the rate cannot be reduced, terminate the rail as operator;
- if the user requests pause while underfunded, terminate and require a new subscription to resume;
- never leave an expired subscription payable merely because a rate update failed—the Boss validator enforces expiry and lifetime caps during settlement.

### 12.4 Removal timing

An offer must define when deleted capacity stops billing:

- immediately when scheduled;
- after the PDP proving-period boundary;
- when the service itself confirms removal.

The generic adapter should follow the canonical on-chain billable measurement and document that rule exactly.

---

## 13. Billing model C: capped CDN-style bandwidth

### 13.1 Immediate practical model

The first bandwidth model should be explicitly described as:

> Trusted or attested usage reporting, bounded by a user-prepaid Filecoin Pay fixed lockup and explicit caps.

This mirrors the useful part of the existing FilBeam pattern:

- off-chain request handling and metering;
- on-chain usage rollups;
- fixed-lockup quota;
- one-time settlement;
- service stops when quota is exhausted.

Boss generalizes the pattern to arbitrary services and restores independent user termination.

### 13.2 Example

Offer:

```json
{
  "serviceType": "CAPPED_EGRESS",
  "billingKind": "METERED_FIXED_LOCKUP",
  "pricePerTiB": "7000000000000000000",
  "maxSingleCharge": "2000000000000000000",
  "defaultBudget": "10000000000000000000",
  "reportingWindowEpochs": "11520",
  "assuranceKind": "TRUSTED_METERING"
}
```

This example means:

- 7 USDFC per TiB;
- reports every four days (`11,520` epochs) for illustration;
- no claim may exceed 2 USDFC;
- user prepays at most 10 USDFC;
- gross quota is approximately `10 / 7 TiB`;
- the service returns an exhaustion response when remaining quota is insufficient;
- there is no automatic top-up.

### 13.3 Hard cap

The user increases `lockupFixed` only through an owner-authorized `increaseBudget`.

Under Filecoin Pay V1, executing a one-time payment consumes the corresponding operator `lockupAllowance` as well as reducing current lockup usage. A consumed allowance is not automatically reusable. Every Boss funding plan and explicit budget top-up must therefore calculate and, with owner authorization, replenish both the rail's fixed lockup and the Boss operator approval headroom.

The reporter may claim usage, but cannot increase:

- rail lockup;
- operator lockup allowance;
- per-window cap;
- lifetime cap.

A finalized claim amount is:

```text
rawAmount = floor(reportedBytes × pricePerTiB / 2^40)

charge = min(
    rawAmount,
    remainingWindowBudget,
    remainingLifetimeBudget,
    maxSingleCharge,
    currentRailFixedLockup
)
```

### 13.4 Usage claim

```solidity
struct UsageClaim {
    bytes32 claimId;
    bytes32 subscriptionId;
    uint64 fromEpoch;
    uint64 toEpoch;
    uint256 units;
    uint256 grossAmount;
    bytes32 evidenceRoot;
    uint64 claimedAt;
    ClaimState state;
}
```

For the trusted MVP:

1. authorized reporter submits claim;
2. Boss checks monotonic epochs, no overlap, price formula, and caps;
3. claim may finalize immediately or after a short observation delay;
4. anyone calls `chargeFinalizedClaim`;
5. Boss executes a Filecoin Pay one-time payment;
6. fixed lockup and quota decrease;
7. service runtime reads remaining quota.

The on-chain record makes the report auditable but does not prove the bytes were delivered.

### 13.5 Multiple recipients

A cache service may need:

- one rail to the CDN for all delivered bytes;
- one rail to the successful origin provider for cache-miss bytes.

Boss represents these as two subscriptions in one bundle component group, or as one multi-rail service instance with independently capped rails.

The user sees both rates and budgets.

### 13.6 Why a cap is the correct first trust boundary

Bandwidth is difficult to prove perfectly because:

- the reporter can fabricate logs;
- client receipts may be withheld;
- client and provider may collude;
- packet-level proofs are expensive;
- bytes delivered do not alone prove usefulness or quality;
- direct retrieval can bypass the metered service.

A user-selected prepaid cap converts that uncertainty from an unbounded liability into a bounded commercial trust decision.

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

## 20. Downstream integration plan

### 20.1 New `filecoin-boss` repository

Recommended monorepo:

```text
filecoin-boss/
  SPEC.md
  ADR/
  contracts/
    BossFactory.sol
    BossAccount.sol
    BossServiceRegistry.sol
    BossStateView.sol
    ResourceSetRegistry.sol
    interfaces/
    adapters/
      FlatRateAdapter.sol
      PDPCapacityAdapter.sol
      CappedMeteredAdapter.sol
    test/
  packages/
    boss-core/
    boss-sdk/
    boss-react/
    boss-subgraph/
  examples/
    filone-storefront/
    capped-egress/
  deployments/
  audits/
```

### 20.2 `filecoin-pay`

No contract change is required for Boss MVP.

Add:

- integration tests against exact V1 behavior;
- documentation for Boss operator/validator use;
- future issue proposals for better native support.

Potential Pay vNext improvements:

- unconditional payer termination;
- validator-independent payer termination;
- native per-rail max gross spend;
- validator-controlled delayed one-time payments;
- rail metadata/tag;
- batch operator approvals;
- per-rail funding or priority;
- safer operator revocation;
- migration helper across Pay versions.

These are useful but not MVP blockers.

### 20.3 `filecoin-services`

MVP:

- no change to FWSS V1 storage path;
- rely on current state view and PDP reads;
- optionally add a stable interface exposing payer, rail ID, and resource status if current generated views are inconvenient.

FWSSv2:

- keep core storage and proof-linked payment focused;
- make service enable/disable dedicated operations, not metadata;
- stop embedding new unrelated product logic;
- expose stable hooks and views for external service composition;
- keep legacy embedded CDN rails supported through a compatibility adapter.

ERC-8167 may modularize FWSSv2 internally, but Boss services remain external contracts.

### 20.4 `synapse-sdk`

Add `synapse.services`:

```typescript
const quote = await synapse.services.quoteBundle({
  resource,
  offers
})

const plan = await synapse.services.planFunding({
  quote,
  runwayDays: 30
})

await synapse.services.acceptBundle({
  quote,
  caps,
  accessGrants
})

await synapse.services.list({ resource })
await synapse.services.pause(subscriptionId)
await synapse.services.terminate(subscriptionId)
await synapse.services.increaseBudget(subscriptionId, amount)
```

SDK responsibilities:

- resolve offers and signatures;
- calculate total gross and recipient breakdown;
- calculate operator approval delta;
- calculate deposits and runway;
- deploy or resolve Boss account;
- reconcile partial activation;
- display trust class;
- monitor caps and quota;
- normalize Pay V1 versus future Pay versions.

### 20.5 `filecoin-pin`

Add CLI and config:

```text
filecoin-pin services catalog
filecoin-pin services quote --dataset <id> --offer <uri-or-id>
filecoin-pin services add --dataset <id> --offer <...> --cap 10
filecoin-pin services list
filecoin-pin services pause <subscription>
filecoin-pin services stop <subscription>
filecoin-pin services top-up <subscription> --amount 5
filecoin-pin services claims <subscription>
```

Pin profiles may declare desired services:

```yaml
services:
  - offer: filone-managed-storage-v1
    max_rate_per_month: 10 USDFC
  - offer: example-cdn-v1
    budget: 20 USDFC
    auto_top_up: false
```

`auto_top_up` must default to false.

### 20.6 `filecoin-pay-explorer`

Add a Boss data source and entities:

```graphql
type BossAccount
type ServiceDefinition
type ServiceOffer
type Bundle
type Resource
type ResourceSet
type Subscription
type SubscriptionRail
type CapPolicy
type UsageClaim
type Dispute
```

The UI should cross-link:

```text
Boss subscription -> Filecoin Pay rail -> settlements
Boss subscription -> PDP dataset -> proofs/pieces/provider
Boss bundle       -> all service components and recipients
```

Core views:

- services by user;
- services on dataset;
- total recurring rate;
- account-wide runway;
- cap remaining;
- current quota;
- component state;
- trust class;
- accepted offer version;
- provider and beneficiary;
- termination status.

### 20.7 Curio and storage providers

Flat and generic capacity add-ons do not require Curio changes.

A service requiring provider work needs an explicit provider-side protocol:

- discovery of subscribed resources;
- access capability;
- work queue;
- health reporting;
- usage or completion attestations;
- settlement monitoring.

Boss should not infer that a storage provider opted into an add-on merely because it serves the base PDP dataset.

### 20.8 Filecoin Beam

Beam can be integrated first as a compatibility service:

- map existing CDN and cache-miss rails into a Boss read model;
- expose current trusted-metering and quota semantics;
- add independent user termination in a new Boss-native deployment;
- later migrate usage rollups into generic `UsageClaim` events.

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

## 22. Security invariants and test requirements

### 22.1 Authority invariants

1. Only owner authorization can increase any cap or expiry.
2. Only an accepted provider offer can set beneficiary and adapter.
3. Service provider cannot change payer.
4. Storefront cannot mutate an accepted component.
5. Resource rebind requires owner and, when necessary, resource-controller authority.
6. Data-access grant is not implied by payment.

### 22.2 Payment invariants

1. Rail rate never exceeds accepted `maxRatePerEpoch`.
2. Lockup period never exceeds accepted `maxLockupPeriod`.
3. Fixed lockup never exceeds accepted budget.
4. One-time charge never exceeds:
   - claim amount;
   - per-charge cap;
   - window cap;
   - lifetime cap;
   - current fixed lockup.
5. Gross paid never exceeds lifetime cap.
6. Settlement after `notAfter` is zero.
7. Price changes cannot increase cost without new owner acceptance.
8. Retried calls cannot double-charge.

### 22.3 Exit invariants

1. Owner can always request Boss termination.
2. Boss calls Filecoin Pay as operator, including when payer account is underfunded.
3. `railTerminated` never reverts.
4. External service adapter cannot veto termination.
5. Terminating add-on never calls FWSS termination.
6. Base dataset deletion can never create new add-on liability.

### 22.4 Validation invariants

1. `validatePayment` only accepts calls from the pinned Pay contract.
2. Validator never pays more than proposed amount.
3. Validator correctly handles rate-change segments.
4. Validator advances expired zero-payment periods without overflow.
5. Cumulative accounting rolls back when a settlement transaction reverts.
6. External assurance failure is handled according to a declared fail-safe policy.

### 22.5 Resource invariants

1. PDP resource identity includes chain and verifier.
2. Unsupported listener or deployment cannot masquerade as FWSS.
3. A bare PDP dataset ID is not treated as proof of payer or user authority.
4. Generic capacity calculation uses the canonical `floor(leaves × 32 × 127 / 128)` raw-size conversion; exact per-piece billing uses `rawPieceSize` and is explicitly distinguished.
5. Provider migration does not silently change an unrelated beneficiary.
6. Deleted datasets cannot continue deterministic capacity billing.
7. Resource-set membership is versioned.

### 22.6 Metering invariants

1. Usage windows are monotonic and non-overlapping.
2. Claimed units are immutable after finalization.
3. Reporter cannot finalize a disputed claim.
4. Charge is executed at most once.
5. Top-up requires owner authority.
6. Quota exhaustion blocks new service according to offer policy.
7. Evidence commitments are domain separated by subscription and chain.

### 22.7 Filecoin Pay V1 regression suite

The test suite must include exact V1 behavior for:

- aggregate account runway;
- aggregate operator allowance;
- underfunded rate-change rejection;
- operator termination while underfunded;
- validator termination callback;
- payer-only `settleTerminatedRailWithoutValidation` full-payment bypass;
- one-time-payment allowance consumption;
- rate-change queue validation;
- finalized rail cleanup;
- known `lockupUsage` leak scenarios;
- validator note behavior.

### 22.8 Adversarial scenarios

- malicious provider submits maximum rate;
- malicious reporter exhausts full allowed cap;
- malicious storefront substitutes beneficiary;
- stale offer replay;
- cross-chain replay;
- dataset deleted between quote and activation;
- provider migrates during claim window;
- user account becomes underfunded during pause;
- validator callback reentrancy;
- service adapter reverts or consumes excessive gas;
- indexer misses events and reconstructs from chain;
- two reconcilers race the same intent;
- claim finalization and dispute race;
- commission recipient is zero or unexpected;
- token decimals differ from pricing assumptions.

---

## 23. Implementation plan

### Phase 0 — semantic lock

#### BOSS-000: Authority and ownership ADR

Lock:

- bundle owner;
- payer;
- resource controller;
- storage provider;
- service provider;
- beneficiary;
- storefront.

Acceptance: no document uses “owns the deal” without naming the exact authority.

#### BOSS-001: Rail topology ADR

Lock:

- one rail per subscription;
- base FWSS rail excluded;
- direct beneficiary default;
- commission versus separate rail rules.

#### BOSS-002: Trust taxonomy ADR

Lock the five assurance classes and required UI language.

#### BOSS-003: Filone product decision

Choose:

- exact inclusive total; or
- distinct Filone service component.

Specify recipient, obligation, lockup, and termination.

### Phase 1 — core contracts

#### BOSS-010: Repository and build

- Foundry;
- formatting, lint, coverage;
- deployment manifests;
- generated ABIs;
- exact Filecoin Pay and PDP dependencies;
- reproducible contract builds.

#### BOSS-011: `BossFactory`

- deterministic per-user account;
- version events;
- no upgrade authority over deployed accounts.

#### BOSS-012: `BossAccount`

- offer verification;
- resource binding;
- subscription state;
- rail creation;
- owner-controlled termination;
- safe Pay callbacks.

#### BOSS-013: Cap validator

- max rate;
- expiry;
- lifetime cap;
- rate-change segment tests;
- never-revert termination callback.

#### BOSS-014: Service registry and signed offers

- EIP-712 domain;
- revocation;
- metadata;
- provider keys;
- replay protection.

#### BOSS-015: State view and event schema

- pagination;
- resource and rail lookups;
- cap remaining;
- stable ABI.

**Phase 1 exit criterion:** A user can attach and independently terminate a fixed-rate service on Calibration without modifying the storage dataset.

### Phase 2 — pricing adapters

#### BOSS-020: `FlatRateAdapter`

- exact per-epoch rate;
- month definition;
- rounding vectors;
- fixed and bounded term.

#### BOSS-021: `PDPCapacityAdapter`

- verify PDP resource;
- committed-byte measurement;
- permissionless sync;
- add/remove/provider-migration tests;
- deletion handling.

#### BOSS-022: Resource sets

- ownership;
- versioned membership;
- one service over several datasets;
- explicit follow/rebind policy.

**Phase 2 exit criterion:** Both requested `$1/deal/month` and `$1/TiB/month` services work end-to-end with exact on-chain caps.

### Phase 3 — capped metering

#### BOSS-030: `CappedMeteredAdapter`

- fixed-lockup budget;
- report windows;
- per-claim/window/lifetime caps;
- explicit top-up;
- Filecoin Pay V1 one-time-payment allowance consumption and approval replenishment;
- idempotent charge.

#### BOSS-031: Usage events and quota view

- remaining units;
- remaining gross budget;
- last reported epoch;
- exhaustion state.

#### BOSS-032: Trusted reporter policy

- authorized reporter rotation only with user-compatible terms;
- evidence roots;
- trust labels;
- failure behavior.

**Phase 3 exit criterion:** A CDN-like service can charge reported usage but can never exceed the user's prepaid cap.

### Phase 4 — SDK and CLI

#### BOSS-040: `@filoz/boss-core`

- ABIs;
- offer encoding;
- signatures;
- formulas;
- event decoding.

#### BOSS-041: Synapse service manager

- catalog;
- quote;
- funding plan;
- approval plan;
- acceptance;
- list;
- pause;
- terminate;
- top-up;
- reconciliation.

#### BOSS-042: Filecoin Pin integration

- commands;
- config profiles;
- machine-readable output;
- no automatic top-up by default.

#### BOSS-043: React hooks

- quote;
- cap editor;
- trust disclosure;
- lifecycle controls.

**Phase 4 exit criterion:** A user can perform the full flow without direct contract calls.

### Phase 5 — indexing and explorer

#### BOSS-050: Boss subgraph

- account;
- offer;
- resource;
- bundle;
- subscription;
- rail;
- claim;
- dispute.

#### BOSS-051: Filecoin Pay Explorer integration

- service identity on rail pages;
- resource links;
- recipient breakdown;
- caps and quota;
- account-wide runway versus per-service exposure.

#### BOSS-052: Reconciliation diagnostics

- desired versus observed state;
- partial activation;
- failed sync;
- stale claim;
- rail mismatch.

**Phase 5 exit criterion:** Every accepted service and charge is independently auditable from public events.

### Phase 6 — Filone pilot

#### BOSS-060: Filone offer

- signed service definition;
- chosen pricing semantics;
- exact total quote;
- terms hash;
- beneficiary;
- Calibration deployment.

#### BOSS-061: Filone storefront example

- one branded product;
- component price disclosure;
- one acceptance flow;
- leave Filone while retaining storage.

#### BOSS-062: Pilot review

Measure:

- activation success;
- approval and funding friction;
- rate synchronization;
- cancellation;
- indexer consistency;
- user understanding of total versus components.

**Phase 6 exit criterion:** Filone can charge its intended price without an FWSS fork.

### Phase 7 — disputes

#### BOSS-070: Delayed usage claims

- challenge window;
- evidence roots;
- claim state machine;
- finalization.

#### BOSS-071: Resolver interface

- reductions;
- rejection;
- bonds;
- resolution events.

#### BOSS-072: Beam-compatible evidence adapter

- CDN bytes;
- cache-miss bytes;
- provider logs;
- client receipts where available.

**Phase 7 exit criterion:** A metered charge can be challenged before Filecoin Pay executes it.

### Phase 8 — FWSSv2 and legacy migration

#### BOSS-080: Stable FWSSv2 service interface

- payer;
- base rail;
- dataset status;
- proof status;
- lifecycle events.

#### BOSS-081: Legacy CDN read adapter

- index existing rails;
- prevent double enablement;
- migration guidance.

#### BOSS-082: Dedicated enable/disable service integration

- no service flags in generic metadata;
- Boss-native attachment after creation.

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

The design was grounded in the following live repository revisions:

| Repository | Revision inspected |
|---|---|
| `FilOzone/filecoin-pay` | `04ded6af6c15c4b5d98545f393dc656004d4aede` |
| `FilOzone/filecoin-services` | `a16aea49d53781669711fa7deb72e820b5e56ff9` |
| `FilOzone/pdp` | `8f5821a76f4d6eb1ea80fab919771cfa628c4bc4` |
| `FilOzone/synapse-sdk` | `1247c3d716006693117e3cacb298a661d52040da` |
| `filecoin-project/filecoin-pin` | `0cc20bfd7bde05f1bd1ee71533482e6b7a48bdde` |
| `FilOzone/filecoin-pay-explorer` | `77cbb96c9d9de933c98a11f39567b09c62bdeec4` |

Primary references:

- Filecoin Pay README, concepts, monitoring guide, integration guide, implementation specification, and `FilecoinPayV1.sol`
- Filecoin Services `SPEC.md`, `FilecoinWarmStorageService.sol`, `Rails.sol`, `PriceListUSDFC.sol`, and state view
- Filecoin Services issues 98, 213, 529, and 534
- PDP design, verifier interface, and verifier implementation
- Synapse SDK storage and payment helpers
- Filecoin Pin payment helpers and CLI documentation
- Filecoin Pay Explorer subgraph schema
- Filecoin Onchain Cloud and Filecoin Beam current documentation
- ERC-8167 specification

---

## 28. Recommended next repository artifact

The first repository change should be a source-locked design PR containing:

```text
SPEC.md
ADR/000-authority-model.md
ADR/001-rail-topology.md
ADR/002-operator-and-validator.md
ADR/003-trust-and-disputes.md
ADR/004-resource-identity.md
examples/flat-1-per-deal.md
examples/capacity-1-per-tib.md
examples/capped-egress.md
IMPLEMENTATION.md
```

That PR should contain no production Solidity until the Filone product semantics and the authority/termination invariants are accepted.
