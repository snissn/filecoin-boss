# Filecoin Boss
## Technical implementation draft

**Status:** Pre-implementation engineering draft  
**Version:** 0.1  
**Date:** 2026-08-12  
**Companion specification:** `FILECOIN_BOSS_SPEC_v0.2.md`

This document translates the protocol design into repository changes, concrete file paths, contract interfaces, transaction flows, testable acceptance criteria, and an ordered pull-request plan. Names and paths are proposed rather than merged facts. Every existing-repository path below was checked against the source-locked revisions in §2.

---

## 1. Implementation boundary

### 1.1 Required MVP repositories

| Repository | Change class | MVP role |
|---|---|---|
| **new** `FilOzone/filecoin-boss` | New repository | Contracts, deployments, ABI package, Boss subgraph, examples, protocol docs |
| `FilOzone/synapse-sdk` | Runtime library change | Low-level Boss primitives and high-level `synapse.services` manager |
| `filecoin-project/filecoin-pin` | CLI/library change | User-facing quote, funding, attach, inspect, sync, pause, stop, and top-up commands |
| `FilOzone/filecoin-pay-explorer` | Index/UI change | Resolve Boss semantics for otherwise generic Filecoin Pay rails |

### 1.2 Compatibility dependencies, not MVP runtime changes

| Repository | MVP treatment |
|---|---|
| `FilOzone/filecoin-pay` | Pin exact Filecoin Pay V1 behavior and run compatibility tests. No production contract change. |
| `FilOzone/pdp` | Read current dataset state through existing interfaces. No production contract change. |
| `FilOzone/filecoin-services` | Read FWSS dataset ownership and rail state through the existing state view. No production contract change. |
| `filecoin-project/curio` | No change for flat/capacity MVP. Later provider provisioning and status callbacks. |
| Filecoin Beam repositories | No change for generic capped-metering MVP. Later native reporter integration. |

This boundary is deliberate. The first release demonstrates that independently governed services can be composed without upgrading the storage or payment contracts.

---

## 2. Source lock

The implementation plan uses these live heads:

| Repository | Branch | Revision |
|---|---|---|
| `FilOzone/filecoin-pay` | `main` | `04ded6af6c15c4b5d98545f393dc656004d4aede` |
| `FilOzone/filecoin-services` | `main` | `54885b9ad04915888ba627ae6bae94df58d68c81` |
| `FilOzone/pdp` | `main` | `4d2a930194367477050302792de89e29275a6047` |
| `FilOzone/synapse-sdk` | `master` | `811163e609cab96b8e089dd972632b221a96e8a7` |
| `filecoin-project/filecoin-pin` | `master` | `27b65c4d7314fb8539d2d5fcee06a2ab03fa4d21` |
| `FilOzone/filecoin-pay-explorer` | `main` | `0e0a7683ec20415f53f4807151221673f1590faa` |

Contract compatibility tests must pin the Filecoin Pay revision rather than importing a floating branch. Deployment manifests must pin deployed addresses independently of repository revisions.

---

## 3. Cross-repository architecture

```text
Service provider
  └─ signs ServiceOffer (EIP-712)
             │
             ▼
Storefront / Synapse / Filecoin Pin
  ├─ resolves FWSS-backed PDP resource
  ├─ quotes adapter rate and Filecoin Pay requirements
  ├─ plans USDFC deposit and Boss operator approval
  └─ submits acceptance to user-owned BossAccount
             │
             ├─ Filecoin Pay operator for Boss rails
             ├─ Filecoin Pay validator for Boss rails
             ├─ enforces immutable accepted terms and caps
             ├─ calls allowlisted resource/pricing adapters
             └─ emits service-semantic events
                    │
                    ├─ flat streaming rail ───────> service beneficiary
                    ├─ capacity streaming rail ──> service beneficiary
                    └─ metered fixed rail ───────> service beneficiary

Existing FWSS:
  PDP dataset ── FWSS validator ── existing Filecoin Pay rail ──> storage provider

Indexing:
  Filecoin Pay subgraph ── generic financial rail state
  Boss subgraph         ── offer/resource/subscription/claim semantics
  Explorer              ── joins by chain + pay contract + railId
```

A Boss account never holds the user's service funds. Funds remain in the user's Filecoin Pay account. Boss only operates the bounded rails the user authorized.

---

## 4. Proposed new repository

### 4.1 Repository tree

```text
filecoin-boss/
├── README.md
├── SPEC.md
├── IMPLEMENTATION.md
├── SECURITY.md
├── CONTRIBUTING.md
├── LICENSE.md
├── docs/
│   ├── adr/
│   │   ├── 0001-user-owned-bundle.md
│   │   ├── 0002-one-service-one-rail.md
│   │   ├── 0003-boss-as-operator-and-validator.md
│   │   ├── 0004-resource-identity.md
│   │   ├── 0005-trust-classes.md
│   │   ├── 0006-capacity-quote-validity.md
│   │   └── 0007-no-upgrade-account-versions.md
│   ├── threat-model.md
│   ├── operations.md
│   └── filone-pilot.md
├── contracts/
│   ├── foundry.toml
│   ├── remappings.txt
│   ├── src/
│   │   ├── BossFactory.sol
│   │   ├── BossAccount.sol
│   │   ├── BossServiceRegistry.sol
│   │   ├── BossAdapterRegistry.sol
│   │   ├── BossStateView.sol
│   │   ├── interfaces/
│   │   │   ├── IBossAccount.sol
│   │   │   ├── IBossFactory.sol
│   │   │   ├── IBossPricingAdapter.sol
│   │   │   ├── IBossResourceAdapter.sol
│   │   │   ├── IBossServiceRegistry.sol
│   │   │   ├── IFilecoinPayV1.sol
│   │   │   ├── IPDPVerifierView.sol
│   │   │   └── IFWSSStateView.sol
│   │   ├── adapters/
│   │   │   ├── FWSSPDPResourceAdapter.sol
│   │   │   ├── FlatRateAdapter.sol
│   │   │   ├── PDPCapacityAdapter.sol
│   │   │   └── CappedMeteredAdapter.sol
│   │   └── libraries/
│   │       ├── BossTypes.sol
│   │       ├── BossErrors.sol
│   │       ├── BossEvents.sol
│   │       ├── OfferHashing.sol
│   │       ├── ResourceHashing.sol
│   │       ├── PricingMath.sol
│   │       └── FilecoinPayV1Compat.sol
│   ├── test/
│   │   ├── unit/
│   │   ├── integration/
│   │   ├── invariant/
│   │   ├── fork/
│   │   └── mocks/
│   └── script/
│       ├── DeployBoss.s.sol
│       ├── DeployAdapters.s.sol
│       ├── RegisterAdapter.s.sol
│       └── PublishExampleOffer.s.sol
├── packages/
│   ├── contracts/
│   │   ├── src/
│   │   ├── deployments/
│   │   └── package.json
│   └── subgraph/
│       ├── schema.graphql
│       ├── subgraph.template.yaml
│       ├── src/
│       └── tests/
├── examples/
│   ├── filone-storefront/
│   ├── flat-per-dataset/
│   └── capped-egress-reporter/
├── deployments/
│   ├── calibration.json
│   ├── mainnet.json
│   └── devnet.schema.json
└── .github/workflows/
    ├── contracts.yml
    ├── subgraph.yml
    ├── sdk-package.yml
    └── deployment-drift.yml
```

### 4.2 Build and dependency decisions

- Solidity: `^0.8.27`, matching the inspected Filecoin Pay V1 source.
- Foundry for compilation, unit tests, fuzzing, invariants, deployment scripts, and gas snapshots.
- OpenZeppelin contracts for `Clones`, EIP-712, `SignatureChecker`, ownership, initialization, reentrancy primitives, and `Math.mulDiv`.
- A minimal local `IFilecoinPayV1` interface in production code.
- The exact Filecoin Pay repository revision imported only into integration tests.
- PDP and FWSS represented by minimal read interfaces in production code.
- Generated ABIs and deployment manifests published from `packages/contracts`.
- No proxy upgradeability for deployed Boss accounts. New behavior uses a new immutable implementation version and a new deterministic account.

---

## 5. Normative contract data model

### 5.1 Resource identity

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
    address anchor;      // PDPVerifier for PDP resources
    uint256 resourceId;  // dataSetId for MVP
    bytes32 context;     // zero for MVP; version/root for later resource sets
}
```

The canonical ID is:

```solidity
bytes32 resourceKey = keccak256(
    abi.encode(
        "FILECOIN_BOSS_RESOURCE_V1",
        resource.kind,
        resource.chainId,
        resource.anchor,
        resource.resourceId,
        resource.context
    )
);
```

For the MVP, only `FWSS_PDP_DATASET` is publicly supported. `BARE_PDP_DATASET` remains disabled until a payer-control interface exists.

### 5.2 Service offer

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

Rules:

- `beneficiary`, adapters, token, pricing hash, and commercial terms are immutable after acceptance.
- A changed price or beneficiary is a new offer version and a new subscription.
- The offer's quoted amounts are gross payer amounts before Filecoin Pay network fees and optional commission.
- `commissionRecipient` must be nonzero when `commissionBps > 0`.
- Provider signing keys are resolved through `BossServiceRegistry`.
- EOA and ERC-1271 signatures are supported through `SignatureChecker`.

### 5.3 User cap policy

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

No protocol call may increase a cap. Increasing a cap requires a new owner-authorized transaction. A provider cannot submit cap changes.

Encoding rules:

- zero means zero for monetary maxima;
- `type(uint256).max` means no monetary maximum;
- `notAfterEpoch == 0` means no time expiry;
- `chargeWindowEpochs == 0` is valid only for non-metered subscriptions.

A cap or expiry expansion is prospective. Boss settles the rail through the current epoch under the old terms before applying it. If the rail cannot become current because the payer is underfunded, the expansion fails rather than retroactively authorizing previously capped or expired epochs.

### 5.4 Subscription state

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

`settledGross + oneTimeChargedGross` is the cumulative gross amount counted against the lifetime cap.

The account additionally stores immutable dynamic inputs in separate mappings:

```solidity
mapping(bytes32 => ResourceRef) internal resourceBySubscription;
mapping(bytes32 => bytes) internal resourceDataBySubscription;
mapping(bytes32 => bytes) internal pricingDataBySubscription;
```

Their hashes are exposed in the logical subscription and events. Billing never fetches mutable pricing bytes from an off-chain URI.

### 5.5 Pricing quote

```solidity
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

The account calls adapters through `staticcall` with an explicit gas stipend. Adapter codehash and interface version are pinned in `BossAdapterRegistry`.

### 5.6 Resource validation

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
```

`FWSSPDPResourceAdapter` is deployed with immutable addresses for:

- one PDP verifier;
- one supported FWSS listener;
- its matching FWSS state view.

At acceptance it verifies:

1. `resource.chainId == block.chainid`;
2. `resource.anchor == configuredPDPVerifier`;
3. the PDP dataset is live;
4. `getDataSetListener(dataSetId) == configuredFWSS`;
5. the FWSS state view returns a registered dataset;
6. the FWSS dataset payer equals the Boss account payer.

The adapter does not infer user authority from the PDP storage-provider address.

---

## 6. Contract responsibilities

### 6.1 `BossFactory.sol`

#### Storage

```solidity
mapping(uint64 version => address implementation) public implementations;
mapping(bytes32 accountSalt => address account) public accounts;
uint64 public latestVersion;
```

#### Account key

For MVP, owner and Filecoin Pay payer are the same address:

```solidity
accountSalt = keccak256(
    abi.encode(
        "FILECOIN_BOSS_ACCOUNT_V1",
        owner,
        filecoinPay,
        implementationVersion
    )
);
```

#### Functions

```solidity
function predictAccount(
    address owner,
    address filecoinPay,
    uint64 implementationVersion
) external view returns (address);

function createAccount(
    address owner,
    address filecoinPay,
    uint64 implementationVersion
) external returns (address);

function publishImplementation(
    uint64 implementationVersion,
    address implementation,
    bytes32 expectedCodeHash
) external;
```

#### Requirements

- deterministic CREATE2 clone;
- idempotent creation;
- implementation version cannot be overwritten;
- factory governance cannot call or control deployed accounts;
- implementation codehash is emitted and stored;
- MVP rejects `owner == address(0)`;
- account version 1 has no ownership-transfer method;
- anyone may deploy the deterministic account for an owner, but only the owner can operate it.

A user needing recovery should use a smart account as owner. A later version may support distinct controller and payer through an EIP-712 payer authorization. The MVP does not.

### 6.2 `BossServiceRegistry.sol`

The service registry is a discovery and key-management registry, not a quality endorsement.

#### Functions

```solidity
function registerProvider(
    string calldata metadataURI,
    address initialSigningKey
) external;

function setSigningKey(address signingKey, bool active) external;

function publishService(
    bytes32 serviceId,
    bytes32 serviceType,
    string calldata metadataURI
) external;

function revokeOfferNonce(uint256 nonce) external;

function isAuthorizedSigner(
    address provider,
    address signer
) external view returns (bool);

function isOfferNonceRevoked(
    address provider,
    uint256 nonce
) external view returns (bool);
```

Provider records are self-controlled. The UI separately displays protocol-supported adapter status and assurance class.

### 6.3 `BossAdapterRegistry.sol`

#### Registry record

```solidity
enum AdapterKind {
    RESOURCE,
    PRICING
}

struct AdapterRecord {
    AdapterKind kind;
    uint64 interfaceVersion;
    bytes32 codeHash;
    bool activeForNewSubscriptions;
    string metadataURI;
}
```

#### Rules

- disabling an adapter prevents new subscriptions;
- accepted subscriptions remain pinned to the exact adapter address;
- an emergency adapter disable does not silently reinterpret existing subscriptions;
- the account handles an unavailable adapter according to its accepted fail-safe behavior;
- registry governance cannot swap code at an existing address.

### 6.4 `BossAccount.sol`

#### Initialization

```solidity
function initialize(
    address owner,
    address filecoinPay,
    address serviceRegistry,
    address adapterRegistry,
    uint64 accountVersion
) external;
```

Stored immutables-in-clone-state:

- `owner`;
- `payer = owner`;
- `filecoinPay`;
- registry addresses;
- account version;
- EIP-712 domain version.

#### Owner-facing functions

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

function acceptBundle(
    bytes32 manifestHash,
    uint64 version,
    bytes[] calldata encodedAcceptances
) external returns (bytes32 bundleId);

```

The typed `BundleAcceptance` remains the SDK-level model. `BossFactory` deploys one canonical `BossBundles` registry and immutably binds every account it creates to that registry. The deployed account accepts **1 through 32** exact `abi.encodeCall(BossAccount.acceptOffer, (acceptance))` payloads, rejects every other selector, executes them by self-delegatecall so owner authority is preserved, and creates the immutable bundle before returning its `bundleId`. Any component or grouping failure reverts all subscriptions and Filecoin Pay rails atomically.


function activate(bytes32 subscriptionId) external;
function pause(bytes32 subscriptionId) external;
function resume(bytes32 subscriptionId) external;
function terminate(bytes32 subscriptionId) external;
function increaseCaps(bytes32 subscriptionId, CapPolicy calldata newCaps) external;
function topUpFixedBudget(bytes32 subscriptionId, uint256 newFixedBudget) external;
function revokeAccessGrant(bytes32 subscriptionId, bytes32 revocationHash) external;
```

`increaseCaps` is owner-only and may only change caps explicitly submitted by the owner. It cannot change the accepted offer, beneficiary, token, adapters, pricing hash, terms hash, assurance class, reporter, pause policy, or dependency policy. Any economic expansion first settles the rail current under the old terms.

#### Permissionless functions

```solidity
function syncRate(bytes32 subscriptionId) external;
function reconcileSubscription(bytes32 subscriptionId) external;
function reconcileResource(bytes32 subscriptionId) external;
function settle(bytes32 subscriptionId, uint256 untilEpoch) external;
```

`syncRate` is permissionless; owner tools call the same function.

#### Reporter function

```solidity
function submitUsageClaim(
    bytes32 subscriptionId,
    UsageClaim calldata claim,
    bytes calldata reporterSignature
) external returns (uint256 grossCharged);
```

#### Filecoin Pay validator functions

```solidity
function validatePayment(
    uint256 railId,
    uint256 proposedAmount,
    uint256 fromEpoch,
    uint256 toEpoch,
    uint256 rate
) external returns (
    IFilecoinPayV1.ValidationResult memory
);

function railTerminated(
    uint256 railId,
    address terminator,
    uint256 endEpoch
) external;
```

#### Prospective economic-change rule

Before extending a dynamic quote, resuming, increasing a rate/lifetime cap, or extending expiry, the account:

1. calls `settleRail(railId, block.number)` under the old terms;
2. re-reads the rail;
3. requires `settledUpTo == block.number` or another exact current-state condition defined by Filecoin Pay V1;
4. only then applies the new rate, quote validity, or cap.

If the payer is underfunded and the rail cannot become current, the expansion fails. This prevents a later quote refresh or cap increase from retroactively reviving intervals that were previously expired or capped.

#### Critical callback behavior

`railTerminated`:

- must not be protected by a reentrancy guard that blocks Filecoin Pay's synchronous callback;
- must not call any external contract;
- must not revert;
- must ignore unauthorized callers without mutating state;
- records `payEndEpoch` and transitions the mapped subscription to `TERMINATING`.

`validatePayment`:

- reverts unless called by the pinned Filecoin Pay contract;
- never returns more than `proposedAmount`;
- calculates billable overlap with accepted start, pause, expiry, quote validity, and termination policy;
- enforces remaining lifetime gross cap;
- updates cumulative settlement state before returning; a later transaction revert rolls the update back;
- returns zero while advancing the settlement cursor for non-billable expired intervals so the rail cannot be permanently stuck.

### 6.5 `BossStateView.sol`

A separate read contract keeps account bytecode smaller and provides batch views for SDKs.

Proposed methods:

```solidity
function getAccount(address bossAccount) external view returns (AccountView memory);
function getSubscription(address bossAccount, bytes32 id)
    external view returns (SubscriptionView memory);
function getSubscriptions(address bossAccount, uint256 offset, uint256 limit)
    external view returns (SubscriptionView[] memory);
function quoteAcceptance(AcceptanceInput calldata input)
    external view returns (AcceptanceQuote memory);
function quoteFunding(AcceptanceInput calldata input)
    external view returns (FundingQuote memory);
function getResourceStatus(ResourceInput calldata input)
    external view returns (ResourceStatus memory);
```

This contract is replaceable tooling. It does not control account state.

---

## 7. Filecoin Pay transaction flows

### 7.1 Prerequisite funding flow

Before `acceptOffer`, the SDK computes:

```text
requiredRateAllowance
  = existing Boss rateUsage + proposed max or initial rate

requiredLockupAllowance
  = existing Boss lockupUsage
  + initial fixed lockup
  + initial streaming rate × lockup period

requiredAvailableFunds
  = additional lockup required by the new rail

requiredDeposit
  = max(0, requiredAvailableFunds - current available funds)
```

User transactions are planned in this order:

1. optional USDFC approval or permit;
2. optional Filecoin Pay deposit;
3. `setOperatorApproval` or `increaseOperatorApproval` for the Boss account;
4. `BossAccount.acceptOffer`.

A quote is invalidated if any relevant state changes before submission. The SDK re-reads account and approval state immediately before executing each step.

### 7.2 `acceptOffer` sequence

```text
1. Check caller is owner.
2. Validate offer time range, registry signer, nonce, and EIP-712 signature.
3. Verify pricingData hash and immutable offer fields.
4. Verify caps are no larger than provider maxima and no smaller than initial need.
5. Verify resource through the allowlisted resource adapter.
6. Obtain initial rate quote from pricing adapter.
7. Enforce rate <= user maxRatePerEpoch.
8. Derive subscriptionId and reject replay.
9. Create Filecoin Pay rail:
     payer      = BossAccount.payer
     payee      = offer.beneficiary
     validator  = BossAccount
     commission = accepted offer
10. Set rail lockup period and fixed lockup.
11. If IMMEDIATE, set initial streaming rate.
    If PROVIDER_ACK, leave rate zero.
12. Persist subscription and rail mappings.
13. Emit SubscriptionAccepted and RailBound.
```

All Filecoin Pay calls are in the same transaction. A failed lockup or rate update reverts rail creation and Boss state.

### 7.3 Provider acknowledgment

For services requiring provisioning:

```solidity
function acknowledgeActivation(
    bytes32 subscriptionId,
    bytes32 provisioningHash,
    bytes calldata providerSignature
) external;
```

After a valid acknowledgment, anyone may call `activate`. The account takes a fresh pricing quote and sets the rate. The activation transaction reverts rather than leaving an active Boss state with a zero or inconsistent Filecoin Pay rate.

### 7.4 Flat-rate synchronization

`FlatRateAdapter` returns a fixed rate and `validThroughEpoch = caps.notAfterEpoch`. No periodic sync is required.

For a gross price `P` per `N` epochs:

```solidity
ratePerEpoch = P / N;
```

Integer remainder is disclosed in the quote. The MVP does not add a periodic correction payment.

### 7.5 Capacity synchronization

The capacity model is prospective and quote-bounded.

```text
rawBytes = floor(leafCount × 32 × 127 / 128)

ratePerEpoch =
  floor(rawBytes × grossPricePerTiBPerPeriod
        / (2^40 × periodEpochs))
```

`PDPCapacityAdapter.quoteRate` returns:

```text
ratePerEpoch
validThroughEpoch = currentEpoch + offer.quoteTtlEpochs
billable = dataset is live and ownership still valid
```

`BossAccount.syncRate`:

1. settles the rail through the current epoch under the old quote;
2. verifies the rail was brought current;
3. obtains a new resource status;
4. obtains a new quote from the stored immutable pricing bytes;
5. rejects a rate above the accepted cap;
6. calls `modifyRailPayment(railId, newRate, 0)`;
7. stores `acceptedRatePerEpoch` and `quoteValidThroughEpoch`;
8. emits `RateSynchronized`.

If the rail cannot become current because the payer is underfunded, synchronization fails and does not extend the old quote.

The new rate applies prospectively according to Filecoin Pay's rate-change semantics. Boss does not claim to reconstruct historical capacity between syncs.

A permissionless reconciler watches PDP/FWSS events and refreshes before expiry. Proposed MVP TTL: 2,880 epochs, approximately one day.

If the quote expires:

- the Filecoin Pay rail may still carry a nonzero nominal rate;
- Boss validation returns zero for epochs after `quoteValidThroughEpoch`;
- settlement advances through those epochs with zero payment;
- a later sync restores payment prospectively.

This makes quote freshness a provider/reconciler responsibility and bounds stale overpayment.

### 7.6 Pause

```text
1. Owner sets state PAUSED and pausedEpoch = current block.
2. Validator becomes zero-paying after pausedEpoch.
3. Account attempts modifyRailPayment(railId, 0, 0).
4. If Filecoin Pay rejects the active rate change because the payer is underfunded:
     - pause remains effective at validation;
     - event PauseRateUpdateDeferred is emitted;
     - UI warns that account-wide lockupRate still includes the nominal rail rate;
     - owner can terminate for a reliable release path.
```

A pause is allowed only when `offer.pauseAllowed` is true. Resume first settles all paused zero-payment epochs under the old state, then takes a fresh quote and updates Filecoin Pay before state returns to `ACTIVE`. If the rail cannot become current, resume fails.

### 7.7 Termination

```text
1. Owner marks TERMINATING and records request epoch.
2. Best-effort reduce unused metered fixed lockup.
3. Call FilecoinPay.terminateRail as the rail operator.
4. Filecoin Pay synchronously calls railTerminated.
5. Callback records endEpoch without reverting.
6. Permissionless settlement continues to endEpoch.
7. reconcileSubscription observes finalization and marks ENDED.
```

The validator's post-request billing follows the accepted `TerminationBillingKind`:

- `PAY_THROUGH_FILECOIN_PAY_END`: bill through `endEpoch`, subject to quote validity and caps;
- `ZERO_AFTER_REQUEST`: zero after request epoch;
- `ADAPTER_DECIDES`: use an approved deterministic lifecycle adapter.

The reliable user sovereignty guarantee is termination authority, not unilateral cancellation of an explicitly accepted payment tail.

### 7.8 Metered usage charge

```solidity
struct UsageClaim {
    bytes32 claimId;
    uint64 fromEpoch;       // exclusive
    uint64 toEpoch;         // inclusive
    uint256 units;          // bytes for egress MVP
    bytes32 evidenceHash;
    bytes32 evidenceUriHash;
    uint256 nonce;
}
```

Validation:

1. subscription uses `METERED_FIXED_LOCKUP`;
2. reporter is the exact nonzero `offer.reporter` for trusted metering;
3. signature is domain-separated by chain, Boss account, subscription, and claim ID;
4. `fromEpoch >= lastUsageToEpoch`;
5. `toEpoch > fromEpoch`;
6. claim lies within one fixed billing window;
7. claim is submitted within the adapter's accepted maximum claim delay;
8. claim and nonce have not been used;
9. adapter computes raw gross charge;
10. charged gross is:
   ```text
   min(
     raw charge,
     maxSingleCharge,
     remaining window cap,
     remaining lifetime cap,
     current fixed lockup
   )
   ```
11. Boss calls `modifyRailPayment(railId, 0, chargedGross)`;
12. claim state and cumulative totals are recorded atomically.

No unpaid debt is created for the truncated portion. The service runtime decides whether to stop accepting traffic.

### 7.9 Top-up

Top-up is a coordinated two- or three-transaction flow:

1. optional Filecoin Pay deposit;
2. payer increases Boss operator `lockupAllowance` if required;
3. owner calls `BossAccount.topUpFixedBudget`.

Automatic top-up is disabled by default. A future session-key policy may authorize bounded top-up, but the MVP does not.

---

## 8. Adapter implementation details

### 8.1 `FWSSPDPResourceAdapter.sol`

Constructor immutables:

```solidity
IPDPVerifierView public immutable pdp;
address public immutable fwss;
IFWSSStateView public immutable fwssView;
uint64 public immutable supportedChainId;
```

Primary reads:

- `pdp.dataSetLive(id)`;
- `pdp.getDataSetListener(id)`;
- `pdp.getDataSetStorageProvider(id)`;
- `pdp.getDataSetLeafCount(id)`;
- `fwssView.getDataSet(id)`.

Failure policy:

- a reverted PDP/FWSS read returns `exists = false`, not attachable;
- acceptance reverts;
- later reconciliation marks the resource non-billable;
- no adapter exception may block account termination.

### 8.2 `FlatRateAdapter.sol`

Pricing data:

```solidity
struct FlatRateTerms {
    uint256 grossPricePerPeriod;
    uint64 periodEpochs;
}
```

Requirements:

- period nonzero;
- result uses integer floor;
- quote exposes remainder for UI disclosure;
- fixed rate cannot exceed provider/user cap.

### 8.3 `PDPCapacityAdapter.sol`

Pricing data:

```solidity
struct CapacityTerms {
    uint256 grossPricePerTiBPerPeriod;
    uint64 periodEpochs;
    uint64 quoteTtlEpochs;
}
```

Math must use `Math.mulDiv` to avoid overflow:

```solidity
uint256 denominator = (1 << 40) * uint256(periodEpochs);
rate = Math.mulDiv(sizeInBytes, grossPricePerTiBPerPeriod, denominator);
```

The adapter uses the resource adapter's canonical approximate raw size. Exact per-piece billing is a separate future adapter and must not be labeled equivalent.

### 8.4 `CappedMeteredAdapter.sol`

Pricing data:

```solidity
struct MeteredTerms {
    uint256 grossPricePerTiB;
    uint64 minimumClaimEpochs;
    uint64 maximumClaimEpochs;
    uint64 maximumClaimDelayEpochs;
}
```

Usage math:

```solidity
gross = Math.mulDiv(units, grossPricePerTiB, 1 << 40);
```

The adapter does not authenticate the reporter or mutate state. `BossAccount` owns claim authorization, ordering, maximum claim delay, and cap accounting.

---

## 9. Events and indexing contract

Every state transition needed by an indexer must be emitted. Events are treated as the semantic API.

```solidity
event BossAccountCreated(
    address indexed owner,
    address indexed account,
    address indexed filecoinPay,
    uint64 implementationVersion
);

event ProviderRegistered(address indexed provider, string metadataURI);
event ProviderSigningKeyUpdated(address indexed provider, address indexed signer, bool active);
event ServicePublished(address indexed provider, bytes32 indexed serviceId, bytes32 serviceType, string metadataURI);
event OfferNonceRevoked(address indexed provider, uint256 indexed nonce);

event SubscriptionAccepted(
    bytes32 indexed subscriptionId,
    address indexed account,
    bytes32 indexed offerHash,
    bytes32 resourceKey,
    uint256 railId,
    address beneficiary,
    address token,
    uint256 initialFixedBudget,
    address provider,
    address reporter,
    address resourceAdapter,
    address pricingAdapter,
    bytes32 resourceDataHash,
    bytes32 pricingDataHash,
    bytes32 accessGrantHash,
    uint256 policyWord,
    uint256 maxRatePerEpoch,
    uint256 maxFixedLockup,
    uint256 maxSingleCharge,
    uint256 maxChargePerWindow,
    uint256 lifetimeCapGross,
    uint256 capEpochs,
    uint256 acceptedRatePerEpoch,
    uint256 acceptanceEpochs
);

event BundleAccepted(bytes32 indexed bundleId, address indexed account, bytes32 manifestHash);
event ProviderActivationAcknowledged(bytes32 indexed subscriptionId, bytes32 provisioningHash);
event SubscriptionActivated(bytes32 indexed subscriptionId, uint64 activatedEpoch);
event RateSynchronized(bytes32 indexed subscriptionId, uint256 oldRate, uint256 newRate, uint64 validThroughEpoch);
event SubscriptionPaused(bytes32 indexed subscriptionId, uint64 pausedEpoch);
event PauseRateUpdateDeferred(bytes32 indexed subscriptionId, bytes reason);
event SubscriptionResumed(bytes32 indexed subscriptionId, uint64 resumedEpoch);
event SubscriptionTerminationRequested(bytes32 indexed subscriptionId, uint64 requestEpoch);
event SubscriptionPayTerminationObserved(bytes32 indexed subscriptionId, uint256 railId, uint256 endEpoch);
event SubscriptionEnded(bytes32 indexed subscriptionId, uint64 endedEpoch);
event CapsIncreased(bytes32 indexed subscriptionId, bytes32 oldCapsHash, bytes32 newCapsHash);
event FixedBudgetToppedUp(bytes32 indexed subscriptionId, uint256 oldBudget, uint256 newBudget);
event UsageClaimCharged(bytes32 indexed subscriptionId, bytes32 indexed claimId, uint256 units, uint256 rawGross, uint256 chargedGross, bytes32 evidenceHash);
event AccessGrantCommitted(bytes32 indexed subscriptionId, bytes32 accessGrantHash);
event AccessGrantRevoked(bytes32 indexed subscriptionId, bytes32 revocationHash);
```

The complete acceptance record is emitted once at acceptance. `policyWord` packs billing, assurance, dependency, activation, and termination kinds into successive 8-bit lanes from bit 0 and `pauseAllowed` at bit 40. `capEpochs` and `acceptanceEpochs` pack their three documented epoch values into successive 64-bit lanes, so indexers do not need a later mutable state read to recover accepted terms.

The Boss subgraph joins a subscription to generic Filecoin Pay data using:

```text
chainId
filecoinPay address
railId
```

A numeric `railId` alone is not globally unique.

---

## 10. `FilOzone/synapse-sdk` changes

The live repository is a monorepo with `synapse-core`, `synapse-sdk`, and `synapse-react`.

### 10.1 `packages/synapse-core`

Add:

```text
packages/synapse-core/src/boss/
├── index.ts
├── types.ts
├── offer.ts
├── resource.ts
├── pricing.ts
├── account.ts
├── funding.ts
├── events.ts
└── constants.ts
```

Modify:

| File | Change |
|---|---|
| `packages/synapse-core/src/abis/generated.ts` | Generated Boss contract ABIs and deployed addresses |
| `packages/synapse-core/src/abis/index.ts` | Export Boss ABIs |
| `packages/synapse-core/src/chains.ts` | Add optional/required Boss contract entries per chain |
| `packages/synapse-core/src/errors/boss.ts` | Typed quote, signature, funding, cap, and lifecycle errors |
| `packages/synapse-core/src/errors/index.ts` | Export Boss errors |
| `packages/synapse-core/src/index.ts` | Export stable Boss types if appropriate |
| `packages/synapse-core/package.json` | Add `./boss` export and `typesVersions` entry |
| ABI generation configuration | Include `@filoz/filecoin-boss-contracts` artifacts |

Proposed low-level API:

```typescript
import * as Boss from '@filoz/synapse-core/boss'

const resource = Boss.resource.fwssPdpDataset({
  chainId,
  pdpVerifier,
  dataSetId
})

const offerHash = Boss.offer.hash(offer)
const signatureValid = await Boss.offer.verify(client, offer, signature)

const quote = await Boss.quoteAcceptance(client, {
  account,
  offer,
  signature,
  resource,
  pricingData,
  caps
})

const plan = await Boss.planFunding(client, quote)
```

Unit tests:

```text
packages/synapse-core/test/boss/offer.test.ts
packages/synapse-core/test/boss/resource.test.ts
packages/synapse-core/test/boss/pricing.test.ts
packages/synapse-core/test/boss/funding.test.ts
packages/synapse-core/test/boss/events.test.ts
packages/synapse-core/test/boss/errors.test.ts
```

Tests run in both Node and browser modes under the repository's existing Playwright-test setup.

### 10.2 `packages/synapse-sdk`

Add:

```text
packages/synapse-sdk/src/services/
├── index.ts
├── manager.ts
├── quote.ts
├── funding.ts
├── execute.ts
├── reconcile.ts
├── subscriptions.ts
└── types.ts
```

Modify:

| File | Change |
|---|---|
| `packages/synapse-sdk/src/synapse.ts` | Instantiate `ServicesManager`; expose `get services()` |
| `packages/synapse-sdk/src/types.ts` | Public service, quote, funding, and execution types |
| `packages/synapse-sdk/src/index.ts` | Export service types |
| `packages/synapse-sdk/src/errors/` | Add service-specific error classes |
| `packages/synapse-sdk/src/test/mocks/` | Boss RPC, event, and transaction fixtures |

High-level API:

```typescript
const quote = await synapse.services.quote({
  offer,
  providerSignature,
  resource: { type: 'fwss-pdp-dataset', dataSetId },
  caps
})

const plan = await synapse.services.planFunding({
  quote,
  depositBufferDays: 7
})

const execution = await synapse.services.accept({
  quote,
  plan,
  accessGrantHash
})

const subscriptions = await synapse.services.list()
await synapse.services.sync(subscriptionId)
await synapse.services.pause(subscriptionId)
await synapse.services.resume(subscriptionId)
await synapse.services.terminate(subscriptionId)
await synapse.services.topUp(subscriptionId, amount)
```

The execution API returns every transaction separately:

```typescript
interface BossAcceptanceExecution {
  bossAccount: Address
  depositTxHash?: Hex
  approvalTxHash?: Hex
  acceptanceTxHash: Hex
  subscriptionId: Hex
  railId: bigint
}
```

No helper may describe a multi-transaction plan as atomic.

Tests:

```text
packages/synapse-sdk/src/test/services-manager.test.ts
packages/synapse-sdk/src/test/services-quote.test.ts
packages/synapse-sdk/src/test/services-funding.test.ts
packages/synapse-sdk/src/test/services-execute.test.ts
packages/synapse-sdk/src/test/services-reconcile.test.ts
packages/synapse-sdk/src/test/services-metered.test.ts
packages/synapse-sdk/src/test/services-errors.test.ts
```

### 10.3 `packages/synapse-react`

Phase after the core SDK is stable:

```text
packages/synapse-react/src/services/
├── use-service-catalog.ts
├── use-service-quote.ts
├── use-service-subscriptions.ts
├── use-accept-service.ts
├── use-service-actions.ts
└── index.ts
```

Hooks must expose transaction-stage state rather than a single misleading loading boolean.

### 10.4 Chain configuration

`packages/synapse-core/src/chains.ts` currently defines Filecoin Pay, FWSS, FWSS view, PDP, registry, and other contracts. Add:

```typescript
bossFactory: ChainContract
bossServiceRegistry: ChainContract
bossAdapterRegistry: ChainContract
bossStateView: ChainContract
```

Calibration entries are required before SDK release. Mainnet entries may remain absent or explicitly unsupported until deployment. `asChain` must fail clearly when a requested Boss operation is attempted on a chain without Boss deployments.

---

## 11. `filecoin-project/filecoin-pin` changes

### 11.1 Command registration

Add:

```text
src/commands/services.ts
src/core/services/
├── index.ts
├── catalog.ts
├── quote.ts
├── funding.ts
├── execute.ts
├── format.ts
└── profiles.ts
```

Modify:

| File | Change |
|---|---|
| `src/commands/index.ts` | Register `services` command group |
| `src/cli.ts` | Include command group and help text |
| `src/config.ts` | Optional Boss endpoint/profile settings |
| `src/index-types.ts` | Export service profile types if part of public library |
| `src/core/payments/README.md` | Cross-link Boss funding behavior |
| root `README.md` | Document service commands and trust labels |

### 11.2 CLI surface

```text
filecoin-pin services catalog
filecoin-pin services quote --dataset <id> --offer <id-or-uri>
filecoin-pin services add --dataset <id> --offer <id-or-uri> [caps]
filecoin-pin services list [--dataset <id>]
filecoin-pin services show <subscription-id>
filecoin-pin services sync <subscription-id>
filecoin-pin services pause <subscription-id>
filecoin-pin services resume <subscription-id>
filecoin-pin services stop <subscription-id>
filecoin-pin services top-up <subscription-id> --amount <USDFC>
filecoin-pin services claims <subscription-id>
```

`quote` output must show:

- gross recurring or usage price;
- estimated Filecoin Pay network fee and provider net;
- beneficiary and commission recipient;
- required deposit and operator-approval deltas;
- lockup and termination tail;
- cap values;
- assurance and dependency classes;
- whether data access is required;
- quote expiry.

`add` must print and confirm the complete transaction plan unless `--yes` is supplied.

### 11.3 Profile support

Proposed JSON-compatible configuration:

```json
{
  "services": [
    {
      "offer": "filone-managed-storage-v1",
      "resource": { "dataSetId": "123" },
      "caps": {
        "maxMonthlyGross": "10",
        "notAfter": "2027-08-01"
      }
    },
    {
      "offer": "example-cdn-v1",
      "caps": {
        "fixedBudget": "20",
        "maxSingleCharge": "2",
        "maxWindowCharge": "5"
      },
      "autoTopUp": false
    }
  ]
}
```

The existing CLI configuration format should be reused; a new YAML dependency should not be introduced only for Boss.

### 11.4 CLI tests

Add:

```text
src/test/unit/services-catalog.test.ts
src/test/unit/services-quote.test.ts
src/test/unit/services-funding.test.ts
src/test/unit/services-add.test.ts
src/test/unit/services-actions.test.ts
src/test/unit/services-format.test.ts
src/test/integration/services-cli.test.ts
src/test/mocks/boss.ts
```

Golden-output tests must prevent loss of beneficiary, cap, lockup, or trust disclosures.

---

## 12. `FilOzone/filecoin-pay-explorer` changes

### 12.1 Indexing decision

Do not add Boss commercial semantics to the generic Filecoin Pay subgraph schema.

The existing Pay subgraph remains authoritative for:

- rail parties;
- operator;
- validator;
- rates;
- lockups;
- settlements;
- one-time payments;
- generic account state.

The new Boss subgraph is authoritative for:

- provider and service identity;
- accepted offer version;
- resource;
- bundle;
- subscription;
- caps;
- trust and dependency classes;
- rate synchronization;
- usage claims;
- access-grant commitments.

The Explorer joins the two data sources.

### 12.2 Environment and configuration

Add:

```text
NEXT_PUBLIC_BOSS_SUBGRAPH_URL_MAINNET
NEXT_PUBLIC_BOSS_SUBGRAPH_URL_CALIBRATION
NEXT_PUBLIC_BOSS_FACTORY_MAINNET
NEXT_PUBLIC_BOSS_FACTORY_CALIBRATION
```

Prefer generated deployment config over manually duplicated addresses when the monorepo's current deployment process permits it.

### 12.3 GraphQL and type files

The live repository currently uses `apps/explorer/src/services/grapql/`; avoid an unrelated directory rename in the Boss PR.

Add:

```text
apps/explorer/src/services/grapql/boss-client.ts
apps/explorer/src/services/grapql/boss-queries.ts
apps/explorer/src/services/grapql/boss-fragments.ts
packages/types/src/boss.ts
```

Modify:

```text
packages/types/src/index.ts
apps/explorer/src/services/grapql/index.ts
```

### 12.4 Routes and components

Add proposed routes:

```text
apps/explorer/src/app/[network]/services/page.tsx
apps/explorer/src/app/[network]/services/[subscriptionId]/page.tsx
apps/explorer/src/app/[network]/resources/pdp/[verifier]/[dataSetId]/services/page.tsx
apps/explorer/src/app/console/services/page.tsx
```

Add components:

```text
apps/explorer/src/components/Services/
apps/explorer/src/components/Subscription/
apps/explorer/src/components/ResourceServices/
apps/explorer/src/components/shared/AssuranceBadge.tsx
apps/explorer/src/components/shared/DependencyBadge.tsx
apps/explorer/src/components/shared/SpendingCapSummary.tsx
```

Modify the existing rail detail page to display a Boss identity panel when `(chain, payContract, railId)` resolves to a Boss subscription.

### 12.5 Explorer tests

- GraphQL query and response parsing tests;
- route loading/error/empty-state tests;
- component tests for each assurance class;
- cap and recipient disclosure snapshots;
- a rail-to-subscription join test;
- an account with mixed Boss and non-Boss rails;
- a resource with multiple independent services;
- Playwright end-to-end test against mocked Pay and Boss subgraphs.

---

## 13. Boss subgraph implementation

Location:

```text
filecoin-boss/packages/subgraph/
```

### 13.1 Entities

```graphql
type BossAccount @entity {
  id: Bytes!
  owner: Bytes!
  filecoinPay: Bytes!
  implementationVersion: BigInt!
  createdAt: BigInt!
  subscriptions: [Subscription!]! @derivedFrom(field: "account")
}

type ServiceProvider @entity {
  id: Bytes!
  metadataURI: String!
  signingKeys: [ProviderSigningKey!]! @derivedFrom(field: "provider")
  services: [ServiceDefinition!]! @derivedFrom(field: "provider")
}

type ServiceDefinition @entity {
  id: Bytes!
  provider: ServiceProvider!
  serviceType: Bytes!
  metadataURI: String!
}

type Resource @entity {
  id: Bytes!
  kind: String!
  chainId: BigInt!
  anchor: Bytes!
  resourceId: BigInt!
  context: Bytes!
  subscriptions: [Subscription!]! @derivedFrom(field: "resource")
}

type Subscription @entity {
  id: Bytes!
  account: BossAccount!
  resource: Resource!
  offerHash: Bytes!
  railId: BigInt!
  filecoinPay: Bytes!
  provider: ServiceProvider!
  beneficiary: Bytes!
  token: Bytes!
  billingKind: String!
  assuranceKind: String!
  dependencyKind: String!
  state: String!
  currentRate: BigInt!
  quoteValidThroughEpoch: BigInt!
  maxRate: BigInt!
  maxFixedLockup: BigInt!
  lifetimeCapGross: BigInt!
  settledGross: BigInt!
  oneTimeChargedGross: BigInt!
  acceptedAt: BigInt!
  usageClaims: [UsageClaim!]! @derivedFrom(field: "subscription")
}

type UsageClaim @entity {
  id: Bytes!
  subscription: Subscription!
  fromEpoch: BigInt!
  toEpoch: BigInt!
  units: BigInt!
  rawGross: BigInt!
  chargedGross: BigInt!
  evidenceHash: Bytes!
  transactionHash: Bytes!
}
```

Additional entities: bundles, cap history, rate syncs, access-grant events, provider activation acknowledgments.

### 13.2 Mapping tests

Matchstick tests for every event handler, duplicate event replay, state transition ordering, and rail-key derivation.

A deployment is not promoted unless the subgraph can rebuild from genesis/start block and produce the same entity counts as the release candidate.

---

## 14. Existing upstream repository follow-ups

### 14.1 `FilOzone/filecoin-pay`

MVP required changes: none.

Recommended documentation-only PR after Boss contracts are stable:

- `docs/integration.md`: add a “user-owned composite service operator” example;
- `docs/monitoring.md`: explain Boss service breakdown remains external to account-wide runway;
- README related-project link.

Recommended compatibility fixture either in Boss or Pay:

```text
test/integrations/BossOperatorValidator.t.sol
```

Do not add Boss-specific semantics to `FilecoinPayV1.sol`.

### 14.2 `FilOzone/filecoin-services`

MVP required changes: none.

Optional stable view follow-up:

```text
service_contracts/src/interfaces/IFilecoinServiceResourceView.sol
service_contracts/src/FilecoinWarmStorageServiceStateView.sol
service_contracts/src/lib/FilecoinWarmStorageServiceStateInternalLibrary.sol
service_contracts/test/FilecoinWarmStorageServiceResourceView.t.sol
```

Proposed stable method:

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

Boss must not block on this because current `getDataSet` is sufficient.

### 14.3 `FilOzone/pdp`

No change. Boss reads existing liveness, listener, leaf-count, provider, and piece state.

A future generic listener-authority interface could enable bare PDP attachments, but that is outside MVP.

### 14.4 Curio and Beam

No MVP change.

Later provider runtime protocol:

```text
GET  /.well-known/filecoin-boss/services
POST /boss/v1/subscriptions/{id}/provision
GET  /boss/v1/subscriptions/{id}/status
POST /boss/v1/usage-claims
```

Authentication and schemas should be specified only after the on-chain subscription model is stable.

---

## 15. Ordered pull-request plan

The PRs below are intentionally small enough to review independently.

### Track A — protocol repository

| PR | Scope | Depends on | Merge criterion |
|---|---|---|---|
| A0 | Repository scaffold, source lock, ADRs, CI | none | Reproducible empty Foundry build and accepted authority/rail ADRs |
| A1 | `BossTypes`, hashing, interfaces, mocks | A0 | EIP-712 vectors and resource-key vectors fixed |
| A2 | Service and adapter registries | A1 | Key rotation, revocation, codehash pinning tests |
| A3 | Factory and immutable account deployment | A1 | Deterministic address and no-upgrade invariants |
| A4 | Flat streaming subscription in `BossAccount` | A2, A3 | End-to-end Pay V1 rail creation/settlement/termination |
| A5 | FWSS resource adapter | A4 | Valid payer attaches; wrong payer/listener/deleted set rejected |
| A6 | Capacity adapter and quote TTL | A5 | Prospective rate sync and expired-quote zero-payment behavior |
| A7 | Metered fixed-lockup service | A4 | Reporter can consume caps but never exceed them |
| A8 | Bundle/event/view surface | A4-A7 | Batch acceptance and complete indexable events |
| A9 | Calibration deployment package | A8 | Deployment verification and address manifest |
| A10 | Boss subgraph | A8, A9 | Matchstick suite and Calibration indexing |
| A11 | FilOne example storefront | A6, A9 | Quote/accept/terminate pilot flow |

### Track B — SDK

| PR | Scope | Depends on |
|---|---|---|
| B0 | `synapse-core/boss` types, hashes, ABI/address plumbing | A1, A9 |
| B1 | Low-level reads, quote, funding planner | B0, A4-A7 |
| B2 | `ServicesManager` and `synapse.services` | B1 |
| B3 | Lifecycle and reconciliation APIs | B2 |
| B4 | React hooks | B2, optional for first CLI pilot |

### Track C — Filecoin Pin

| PR | Scope | Depends on |
|---|---|---|
| C0 | Read-only catalog/quote/list/show | B2 |
| C1 | Funding plan and `services add` | C0 |
| C2 | sync/pause/resume/stop/top-up/claims | B3 |
| C3 | Documentation and profile support | C1-C2 |

### Track D — Explorer

| PR | Scope | Depends on |
|---|---|---|
| D0 | Boss GraphQL client and types | A10 |
| D1 | Subscription/resource pages | D0 |
| D2 | Join Boss semantics onto Pay rails | D0 |
| D3 | Console service actions | B3, D1 |

### Track E — optional upstream documentation

Pay and FWSS documentation PRs follow the Calibration pilot. They are not dependencies of the pilot.

---

## 16. Local implementation workflow

A reproducible development environment should deploy:

1. mock or real USDFC;
2. exact Filecoin Pay V1;
3. PDP verifier;
4. FWSS and state view;
5. one registered provider;
6. Boss registries, implementation, factory, adapters, and state view;
7. one user Boss account;
8. Boss and Pay subgraphs.

`devnet-info.json` or the existing FOC devnet deployment metadata should be extended with Boss addresses. Synapse's devnet schema must accept them.

The reference script must execute:

```text
fund payer
approve/deposit USDFC into Filecoin Pay
approve Boss operator
create FWSS-backed PDP dataset
publish provider offer
quote flat service
accept flat service
settle
sync capacity service after adding data
submit capped usage claim
pause one service
terminate another while payer is underfunded
finalize rails
verify subgraph and explorer state
```

---

## 17. Definition of done

The MVP implementation is complete when all of the following are true:

1. A user can attach a flat add-on to an existing FWSS-backed PDP dataset without changing FWSS.
2. A user can attach a capacity-priced add-on whose rate is computed from on-chain PDP size and refreshed permissionlessly.
3. A trusted reporter can charge a prepaid metered rail but cannot exceed any accepted cap.
4. A provider cannot change beneficiary, token, adapter, price data, terms, expiry, or cap after acceptance.
5. The user can terminate a Boss rail through the Boss operator while the Filecoin Pay account is underfunded.
6. A failing adapter or callback cannot veto termination.
7. The existing FWSS rail and dataset remain active when an add-on is paused or terminated.
8. Synapse and Filecoin Pin display all recipients, caps, lockups, trust classes, and transaction stages before signing.
9. The Explorer joins Boss semantics to generic Filecoin Pay rail history.
10. The entire flow passes local devnet and Calibration end-to-end tests.
11. Contract invariants, fuzzing, static analysis, internal review, and external audit gates are complete.
12. Deployment manifests, ABIs, subgraph start blocks, and source verification are reproducible.

---

## 18. Product decisions that block only the FilOne offer

The platform can be implemented while these remain open, but the pilot offer cannot be finalized without them:

- exact inclusive 4.99 total versus 2.49 independent component;
- FilOne's operational obligation;
- FilOne beneficiary and any storefront commission;
- required data-access scope;
- lockup and termination-billing policy;
- quote TTL and reconciler owner;
- whether provider acknowledgment is required before billing starts.

The safest initial offer is a separate 2.49 USDFC/TiB/30-day managed-service component with no data access, a one-day quote TTL, a zero- or one-day termination tail, and explicit `CANCELLABLE_ONLY` assurance.
