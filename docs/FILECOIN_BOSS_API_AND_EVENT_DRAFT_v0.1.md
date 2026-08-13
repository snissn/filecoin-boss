# Filecoin Boss
## Contract, event, and SDK API draft

**Status:** Interface sketch for implementation PR A1/B0  
**Version:** 0.1  
**Date:** 2026-08-12

This document is intentionally close to source code so contract and SDK work can begin from one shared shape. It is not asserted to compile unchanged, and it is not audited. Storage packing, error names, NatSpec, and imports will change during implementation. Authority, recipient, cap, resource, and lifecycle semantics must remain consistent with `FILECOIN_BOSS_SPEC_v0.2.md`.

---

## 1. Proposed `BossTypes.sol`

```solidity
// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

enum ResourceKind {
    FWSS_PDP_DATASET,
    BARE_PDP_DATASET,
    PDP_RESOURCE_SET,
    GENERIC_CONTENT_ROOT
}

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

enum SubscriptionState {
    NONE,
    PENDING_ACTIVATION,
    ACTIVE,
    PAUSED,
    TERMINATING,
    ENDED,
    EXHAUSTED
}

enum AdapterKind {
    RESOURCE,
    PRICING
}

struct ResourceRef {
    ResourceKind kind;
    uint64 chainId;
    address anchor;
    uint256 resourceId;
    bytes32 context;
}

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

struct RateQuote {
    uint256 ratePerEpoch;
    uint64 validThroughEpoch;
    bool billable;
    bytes32 quoteHash;
    bytes32 noteHash;
}

struct UsageClaim {
    bytes32 claimId;
    uint64 fromEpoch;
    uint64 toEpoch;
    uint256 units;
    bytes32 evidenceHash;
    bytes32 evidenceUriHash;
    uint256 nonce;
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

struct AcceptanceInput {
    ServiceOffer offer;
    bytes providerSignature;
    ResourceRef resource;
    bytes resourceData;
    bytes pricingData;
    CapPolicy caps;
    uint256 initialFixedBudget;
    bytes32 accessGrantHash;
}

struct BundleComponent {
    AcceptanceInput acceptance;
}

struct BundleAcceptance {
    bytes32 manifestHash;
    BundleComponent[] components;
}

struct AdapterRecord {
    AdapterKind kind;
    uint64 interfaceVersion;
    bytes32 codeHash;
    bool activeForNewSubscriptions;
    string metadataURI;
}
```

Implementation note: `Subscription` should be storage-packed into internal structs rather than stored exactly as written. Public views may reconstruct this logical form.

---

## 2. Proposed Filecoin Pay interface

```solidity
// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

interface IFilecoinPayV1 {
    struct ValidationResult {
        uint256 modifiedAmount;
        uint256 settleUpto;
        string note;
    }

    struct RailView {
        address token;
        address from;
        address to;
        address operator;
        address validator;
        uint256 paymentRate;
        uint256 lockupPeriod;
        uint256 lockupFixed;
        uint256 settledUpTo;
        uint256 endEpoch;
        uint256 commissionRateBps;
        address serviceFeeRecipient;
    }

    function createRail(
        address token,
        address from,
        address to,
        address validator,
        uint256 commissionRateBps,
        address serviceFeeRecipient
    ) external returns (uint256 railId);

    function modifyRailLockup(
        uint256 railId,
        uint256 period,
        uint256 lockupFixed
    ) external;

    function modifyRailPayment(
        uint256 railId,
        uint256 newRate,
        uint256 oneTimePayment
    ) external;

    function settleRail(
        uint256 railId,
        uint256 untilEpoch
    ) external returns (
        uint256 totalSettledAmount,
        uint256 totalNetPayeeAmount,
        uint256 totalOperatorCommission,
        uint256 totalNetworkFee,
        uint256 finalSettledEpoch,
        string memory note
    );

    function terminateRail(uint256 railId) external;

    function getRail(uint256 railId)
        external
        view
        returns (RailView memory);

    function getAccountInfoIfSettled(
        address token,
        address owner
    ) external view returns (
        uint256 fundedUntilEpoch,
        uint256 currentFunds,
        uint256 availableFunds,
        uint256 currentLockupRate
    );

    function operatorApprovals(
        address token,
        address client,
        address operator
    ) external view returns (
        bool isApproved,
        uint256 rateAllowance,
        uint256 lockupAllowance,
        uint256 rateUsage,
        uint256 lockupUsage,
        uint256 maxLockupPeriod
    );
}
```

The integration test should import the actual contract rather than trusting this interface alone.

---

## 3. Proposed resource and pricing adapters

```solidity
// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

import {
    ResourceRef,
    ResourceStatus,
    RateQuote
} from "../libraries/BossTypes.sol";

interface IBossResourceAdapter {
    function interfaceVersion() external pure returns (uint64);

    function inspect(
        ResourceRef calldata resource,
        address expectedPayer,
        bytes calldata resourceData
    ) external view returns (ResourceStatus memory status);
}

interface IBossPricingAdapter {
    function interfaceVersion() external pure returns (uint64);

    function quoteRate(
        ResourceStatus calldata resource,
        bytes calldata pricingData
    ) external view returns (RateQuote memory quote);

    function quoteUsage(
        uint256 units,
        bytes calldata pricingData
    ) external view returns (uint256 grossCharge);
}
```

Recommended convention:

- streaming adapters implement `quoteRate` and may revert `UsageUnsupported`;
- metered adapters implement `quoteUsage` and return zero-rate from `quoteRate`;
- adapter calls are made through `staticcall` with a fixed gas budget;
- adapters never authenticate provider or reporter and never mutate Boss state.

---

## 4. Proposed factory interface

```solidity
// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

interface IBossFactory {
    event ImplementationPublished(
        uint64 indexed version,
        address indexed implementation,
        bytes32 codeHash
    );

    event BossAccountCreated(
        address indexed owner,
        address indexed account,
        address indexed filecoinPay,
        uint64 implementationVersion
    );

    function latestVersion() external view returns (uint64);

    function implementations(uint64 version)
        external
        view
        returns (address implementation);

    function predictAccount(
        address owner,
        address filecoinPay,
        uint64 implementationVersion
    ) external view returns (address account);

    function createAccount(
        address owner,
        address filecoinPay,
        uint64 implementationVersion
    ) external returns (address account);
}
```

Publishing an implementation is governance-controlled. An existing version cannot be overwritten. The factory has no account execution function. Account version 1 has no ownership-transfer function; recovery is provided by choosing a smart-account owner and migration uses a new Boss account.

---

## 5. Proposed service registry interface

```solidity
// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

interface IBossServiceRegistry {
    event ProviderRegistered(
        address indexed provider,
        string metadataURI
    );

    event ProviderSigningKeyUpdated(
        address indexed provider,
        address indexed signingKey,
        bool active
    );

    event ServicePublished(
        address indexed provider,
        bytes32 indexed serviceId,
        bytes32 serviceType,
        string metadataURI
    );

    event OfferNonceRevoked(
        address indexed provider,
        uint256 indexed nonce
    );

    function registerProvider(
        string calldata metadataURI,
        address initialSigningKey
    ) external;

    function setSigningKey(
        address signingKey,
        bool active
    ) external;

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
}
```

The implementation should allow the provider address itself to act as a signer by default or require explicit registration; this must be fixed in ADR 0005. Explicit registration is easier to index and revoke.

---

## 6. Proposed adapter registry interface

```solidity
// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

import {
    AdapterKind,
    AdapterRecord
} from "../libraries/BossTypes.sol";

interface IBossAdapterRegistry {
    event AdapterRegistered(
        address indexed adapter,
        AdapterKind kind,
        uint64 interfaceVersion,
        bytes32 codeHash,
        string metadataURI
    );

    event AdapterActivationChanged(
        address indexed adapter,
        bool activeForNewSubscriptions
    );

    function getAdapter(address adapter)
        external
        view
        returns (AdapterRecord memory record);

    function isActive(
        address adapter,
        AdapterKind expectedKind,
        uint64 expectedInterfaceVersion
    ) external view returns (bool);
}
```

Accepted subscriptions store the adapter address; the registry is consulted for new acceptance only.

---

## 7. Proposed Boss account interface

```solidity
// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

import {
    AcceptanceInput,
    BundleAcceptance,
    CapPolicy,
    ServiceOffer,
    Subscription,
    UsageClaim
} from "../libraries/BossTypes.sol";
import {IFilecoinPayV1} from "./IFilecoinPayV1.sol";

interface IBossAccount {
    event SubscriptionAccepted(
        bytes32 indexed subscriptionId,
        address indexed account,
        bytes32 indexed offerHash,
        bytes32 resourceKey,
        uint256 railId,
        address beneficiary,
        address token,
        uint256 initialRate,
        uint256 initialFixedBudget
    );

    event BundleAccepted(
        bytes32 indexed bundleId,
        address indexed account,
        bytes32 manifestHash
    );

    event ProviderActivationAcknowledged(
        bytes32 indexed subscriptionId,
        bytes32 provisioningHash
    );

    event SubscriptionActivated(
        bytes32 indexed subscriptionId,
        uint64 activatedEpoch
    );

    event RateSynchronized(
        bytes32 indexed subscriptionId,
        uint256 oldRate,
        uint256 newRate,
        uint64 validThroughEpoch
    );

    event SubscriptionPaused(
        bytes32 indexed subscriptionId,
        uint64 pausedEpoch
    );

    event PauseRateUpdateDeferred(
        bytes32 indexed subscriptionId,
        bytes reason
    );

    event SubscriptionResumed(
        bytes32 indexed subscriptionId,
        uint64 resumedEpoch
    );

    event SubscriptionTerminationRequested(
        bytes32 indexed subscriptionId,
        uint64 requestEpoch
    );

    event SubscriptionPayTerminationObserved(
        bytes32 indexed subscriptionId,
        uint256 indexed railId,
        uint256 endEpoch
    );

    event SubscriptionEnded(
        bytes32 indexed subscriptionId,
        uint64 endedEpoch
    );

    event CapsChanged(
        bytes32 indexed subscriptionId,
        bytes32 oldCapsHash,
        bytes32 newCapsHash
    );

    event FixedBudgetToppedUp(
        bytes32 indexed subscriptionId,
        uint256 oldBudget,
        uint256 newBudget
    );

    event UsageClaimCharged(
        bytes32 indexed subscriptionId,
        bytes32 indexed claimId,
        uint256 units,
        uint256 rawGross,
        uint256 chargedGross,
        bytes32 evidenceHash
    );

    event AccessGrantCommitted(
        bytes32 indexed subscriptionId,
        bytes32 accessGrantHash
    );

    event AccessGrantRevoked(
        bytes32 indexed subscriptionId,
        bytes32 revocationHash
    );

    function initialize(
        address owner,
        address filecoinPay,
        address serviceRegistry,
        address adapterRegistry,
        uint64 accountVersion
    ) external;

    function owner() external view returns (address);
    function payer() external view returns (address);
    function filecoinPay() external view returns (address);
    function accountVersion() external view returns (uint64);

    function acceptOffer(
        AcceptanceInput calldata input
    ) external returns (
        bytes32 subscriptionId,
        uint256 railId
    );

    function acceptBundle(
        BundleAcceptance calldata input
    ) external returns (
        bytes32 bundleId,
        bytes32[] memory subscriptionIds
    );

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
    function reconcileSubscription(bytes32 subscriptionId) external;
    function settle(bytes32 subscriptionId, uint256 untilEpoch) external;

    function setCaps(
        bytes32 subscriptionId,
        CapPolicy calldata newCaps
    ) external;

    function topUpFixedBudget(
        bytes32 subscriptionId,
        uint256 newFixedBudget
    ) external;

    function submitUsageClaim(
        bytes32 subscriptionId,
        UsageClaim calldata claim,
        bytes calldata reporterSignature
    ) external returns (uint256 grossCharged);

    function revokeAccessGrant(
        bytes32 subscriptionId,
        bytes32 revocationHash
    ) external;

    function getSubscription(
        bytes32 subscriptionId
    ) external view returns (Subscription memory);

    function validatePayment(
        uint256 railId,
        uint256 proposedAmount,
        uint256 fromEpoch,
        uint256 toEpoch,
        uint256 rate
    ) external returns (IFilecoinPayV1.ValidationResult memory result);

    function railTerminated(
        uint256 railId,
        address terminator,
        uint256 endEpoch
    ) external;
}
```

Implementation note: `setCaps` should support only changes that remain valid against already spent/locked amounts. The exact increase/decrease rules belong in tests and NatSpec.

---

## 8. Suggested internal mappings

```solidity
mapping(bytes32 subscriptionId => StoredSubscription) internal subscriptions;
mapping(bytes32 subscriptionId => ResourceRef) internal resourceBySubscription;
mapping(bytes32 subscriptionId => bytes) internal resourceDataBySubscription;
mapping(bytes32 subscriptionId => bytes) internal pricingDataBySubscription;
mapping(uint256 railId => bytes32 subscriptionId) internal subscriptionByRail;
mapping(bytes32 claimId => bool consumed) internal consumedClaims;
mapping(bytes32 subscriptionId => mapping(uint256 window => uint256 gross))
    internal grossByWindow;
mapping(bytes32 subscriptionId => bytes32 accessGrantHash)
    internal accessGrantHashes;
mapping(bytes32 subscriptionId => bytes32 accessRevocationHash)
    internal accessRevocationHashes;
```

Bundle membership can be event-only for MVP if on-chain enumeration is not needed by contracts. If stored, cap component count to avoid unbounded arrays.

---

## 9. Suggested `acceptOffer` pseudocode

```solidity
function acceptOffer(
    AcceptanceInput calldata input
) external onlyOwner returns (
    bytes32 subscriptionId,
    uint256 railId
) {
    ServiceOffer calldata offer = input.offer;

    _validateOfferWindow(offer);
    _validateOfferSignature(offer, input.providerSignature);
    _validateAdapter(offer.resourceAdapter, AdapterKind.RESOURCE);
    _validateAdapter(offer.pricingAdapter, AdapterKind.PRICING);

    if (keccak256(input.pricingData) != offer.pricingDataHash) {
        revert PricingDataHashMismatch();
    }

    ResourceStatus memory resource = _inspectResource(
        offer.resourceAdapter,
        input.resource,
        payer,
        input.resourceData
    );

    if (!resource.attachable || resource.payer != payer) {
        revert ResourceNotAttachable();
    }

    RateQuote memory quote = _quoteRate(
        offer.pricingAdapter,
        resource,
        input.pricingData
    );

    _validateCaps(
        offer,
        input.caps,
        input.initialFixedBudget,
        quote
    );

    bytes32 offerHash = _hashOffer(offer);
    subscriptionId = _deriveSubscriptionId(
        address(this),
        offerHash,
        resource.resourceKey
    );
    if (_subscriptionExists(subscriptionId)) {
        revert SubscriptionAlreadyExists(subscriptionId);
    }

    railId = IFilecoinPayV1(filecoinPay).createRail(
        offer.token,
        payer,
        offer.beneficiary,
        address(this),
        offer.commissionBps,
        offer.commissionRecipient
    );

    uint256 initialFixed = input.initialFixedBudget;
    IFilecoinPayV1(filecoinPay).modifyRailLockup(
        railId,
        offer.requiredLockupPeriod,
        initialFixed
    );

    uint256 initialRate = 0;
    SubscriptionState initialState =
        SubscriptionState.PENDING_ACTIVATION;

    if (offer.activationKind == ActivationKind.IMMEDIATE) {
        initialRate = quote.billable ? quote.ratePerEpoch : 0;
        IFilecoinPayV1(filecoinPay).modifyRailPayment(
            railId,
            initialRate,
            0
        );
        initialState = SubscriptionState.ACTIVE;
    }

    _storeSubscription(
        subscriptionId,
        offerHash,
        resource,
        offer,
        input.caps,
        railId,
        initialRate,
        initialFixed,
        quote.validThroughEpoch,
        initialState
    );

    resourceBySubscription[subscriptionId] = input.resource;
    resourceDataBySubscription[subscriptionId] = input.resourceData;
    pricingDataBySubscription[subscriptionId] = input.pricingData;
    subscriptionByRail[railId] = subscriptionId;

    emit SubscriptionAccepted(
        subscriptionId,
        address(this),
        offerHash,
        resource.resourceKey,
        railId,
        offer.beneficiary,
        offer.token,
        initialRate,
        initialFixed
    );
}
```

Storage should be prepared before external calls only where safe, or the complete transaction should rely on reversion and explicit callback handling. The real implementation must be reviewed for reentrancy around Filecoin Pay calls.

---

## 10. Prospective economic-change helper

A later quote or cap must not revive an earlier expired or capped interval. Before `syncRate`, `resume`, a lifetime/rate-cap increase, or an expiry extension, the implementation should settle the rail under its old terms.

```solidity
function _settleCurrentBeforeExpansion(
    StoredSubscription storage s
) internal {
    IFilecoinPayV1 pay = IFilecoinPayV1(filecoinPay);

    pay.settleRail(s.railId, block.number);

    IFilecoinPayV1.RailView memory rail =
        pay.getRail(s.railId);

    if (rail.settledUpTo != block.number) {
        revert RailNotCurrentForExpansion(
            s.railId,
            rail.settledUpTo,
            block.number
        );
    }
}
```

The exact equality condition must be confirmed against Filecoin Pay V1 termination and finalized-rail states. The principle is normative: expansion is prospective, and underfunding cannot make it retroactive.

`syncRate` then performs:

```text
settle old interval
→ inspect stored resource
→ quote from stored pricingData
→ enforce cap
→ modify rate
→ store new quote validity
```

## 11. Suggested streaming validation pseudocode

```solidity
function validatePayment(
    uint256 railId,
    uint256 proposedAmount,
    uint256 fromEpoch,
    uint256 toEpoch,
    uint256 rate
) external returns (
    IFilecoinPayV1.ValidationResult memory result
) {
    if (msg.sender != filecoinPay) revert OnlyFilecoinPay();

    bytes32 subscriptionId = subscriptionByRail[railId];
    StoredSubscription storage s = subscriptions[subscriptionId];
    if (s.state == SubscriptionState.NONE) {
        revert UnknownRail(railId);
    }

    uint256 settleUpto = toEpoch;
    uint256 billableFrom = fromEpoch;
    uint256 billableTo = toEpoch;

    if (billableFrom < s.activatedEpoch) {
        billableFrom = s.activatedEpoch;
    }

    if (s.caps.notAfterEpoch != 0 &&
        billableTo > s.caps.notAfterEpoch) {
        billableTo = s.caps.notAfterEpoch;
    }

    if (s.quoteValidThroughEpoch != 0 &&
        billableTo > s.quoteValidThroughEpoch) {
        billableTo = s.quoteValidThroughEpoch;
    }

    if (s.state == SubscriptionState.PAUSED &&
        billableTo > s.pausedEpoch) {
        billableTo = s.pausedEpoch;
    }

    if (s.state == SubscriptionState.ENDED ||
        s.state == SubscriptionState.EXHAUSTED) {
        billableTo = billableFrom;
    }

    if (s.state == SubscriptionState.TERMINATING) {
        if (s.terminationBillingKind ==
            TerminationBillingKind.ZERO_AFTER_REQUEST &&
            billableTo > s.terminationRequestedEpoch) {
            billableTo = s.terminationRequestedEpoch;
        }

        if (s.terminationBillingKind ==
            TerminationBillingKind.PAY_THROUGH_FILECOIN_PAY_END &&
            s.payEndEpoch != 0 &&
            billableTo > s.payEndEpoch) {
            billableTo = uint64(s.payEndEpoch);
        }
    }

    uint256 maximumByTime = 0;
    if (billableTo > billableFrom) {
        uint256 cappedRate = rate < s.caps.maxRatePerEpoch
            ? rate
            : s.caps.maxRatePerEpoch;
        maximumByTime = (billableTo - billableFrom) * cappedRate;
    }

    uint256 spent = s.settledGross + s.oneTimeChargedGross;
    uint256 remaining =
        spent >= s.caps.lifetimeCapGross
            ? 0
            : s.caps.lifetimeCapGross - spent;

    uint256 modified = _min3(
        proposedAmount,
        maximumByTime,
        remaining
    );

    s.settledGross += modified;
    if (remaining != type(uint256).max && modified == remaining) {
        s.state = SubscriptionState.EXHAUSTED;
    }

    result = IFilecoinPayV1.ValidationResult({
        modifiedAmount: modified,
        settleUpto: settleUpto,
        note: modified == proposedAmount
            ? "boss:accepted"
            : "boss:capped-or-nonbillable"
    });
}
```

The implementation must match Filecoin Pay's exclusive/inclusive epoch conventions and use overflow-safe arithmetic. The pseudocode is not a substitute for the integration suite.

---

## 12. Suggested termination pseudocode

```solidity
function terminate(
    bytes32 subscriptionId
) external onlyOwner {
    StoredSubscription storage s = subscriptions[subscriptionId];

    if (s.state == SubscriptionState.ENDED) return;
    if (s.state == SubscriptionState.TERMINATING) return;

    s.state = SubscriptionState.TERMINATING;
    s.terminationRequestedEpoch = uint64(block.number);

    emit SubscriptionTerminationRequested(
        subscriptionId,
        uint64(block.number)
    );

    if (s.billingKind == BillingKind.METERED_FIXED_LOCKUP) {
        // Reduction only; failure must not prevent termination.
        try IFilecoinPayV1(filecoinPay).modifyRailLockup(
            s.railId,
            s.lockupPeriod,
            0
        ) {
            s.currentFixedBudget = 0;
        } catch {}
    }

    IFilecoinPayV1(filecoinPay).terminateRail(s.railId);
}

function railTerminated(
    uint256 railId,
    address,
    uint256 endEpoch
) external {
    if (msg.sender != filecoinPay) return;

    bytes32 subscriptionId = subscriptionByRail[railId];
    StoredSubscription storage s = subscriptions[subscriptionId];
    if (s.state == SubscriptionState.NONE) return;

    s.state = SubscriptionState.TERMINATING;
    s.payEndEpoch = uint64(endEpoch);

    emit SubscriptionPayTerminationObserved(
        subscriptionId,
        railId,
        endEpoch
    );
}
```

`railTerminated` has no external calls and deliberately does not revert for unknown or unauthorized calls.

---

## 13. Suggested usage-claim pseudocode

```solidity
function submitUsageClaim(
    bytes32 subscriptionId,
    UsageClaim calldata claim,
    bytes calldata signature
) external returns (uint256 chargedGross) {
    StoredSubscription storage s = subscriptions[subscriptionId];
    _requireMeteredAndActive(s);
    _validateExactReporter(s.reporter, claim, signature);
    _validateClaimDelay(s, claim);

    if (consumedClaims[claim.claimId]) {
        revert ClaimAlreadyConsumed(claim.claimId);
    }
    if (claim.toEpoch <= claim.fromEpoch) {
        revert InvalidClaimInterval();
    }
    if (claim.fromEpoch < s.lastUsageToEpoch) {
        revert ClaimOverlap();
    }

    uint256 window = _windowForClaim(s, claim);
    uint256 rawGross = _quoteUsage(
        s.pricingAdapter,
        claim.units,
        s.pricingData
    );

    IFilecoinPayV1.RailView memory rail =
        IFilecoinPayV1(filecoinPay).getRail(s.railId);

    uint256 remainingWindow =
        _remainingWindowCap(s, window);
    uint256 remainingLifetime =
        _remainingLifetimeCap(s);
    uint256 remainingSingle =
        s.caps.maxSingleCharge == 0
            ? type(uint256).max
            : s.caps.maxSingleCharge;

    chargedGross = _min5(
        rawGross,
        remainingSingle,
        remainingWindow,
        remainingLifetime,
        rail.lockupFixed
    );

    consumedClaims[claim.claimId] = true;
    s.lastUsageToEpoch = claim.toEpoch;
    grossByWindow[subscriptionId][window] += chargedGross;
    s.oneTimeChargedGross += chargedGross;
    s.currentFixedBudget = rail.lockupFixed - chargedGross;

    IFilecoinPayV1(filecoinPay).modifyRailPayment(
        s.railId,
        0,
        chargedGross
    );

    emit UsageClaimCharged(
        subscriptionId,
        claim.claimId,
        claim.units,
        rawGross,
        chargedGross,
        claim.evidenceHash
    );
}
```

If the Filecoin Pay call reverts, Solidity reverts the preceding claim-state writes.

---

## 14. Proposed SDK types

```typescript
export type BossResource =
  | {
      type: 'fwss-pdp-dataset'
      chainId: number
      pdpVerifier: Address
      dataSetId: bigint
    }

export type BossAssurance =
  | 'cancellable-only'
  | 'onchain-deterministic'
  | 'trusted-metering'
  | 'attested'
  | 'disputable'

export interface BossCaps {
  maxRatePerEpoch: bigint
  maxFixedLockup: bigint
  maxSingleCharge: bigint
  maxChargePerWindow: bigint
  lifetimeCapGross: bigint
  chargeWindowEpochs: bigint
  notAfterEpoch: bigint
  maxLockupPeriod: bigint
}

export interface BossQuote {
  account: Address
  offerHash: Hex
  resourceKey: Hex
  beneficiary: Address
  reporter: Address
  token: Address
  initialRatePerEpoch: bigint
  quoteValidThroughEpoch: bigint
  initialFixedLockup: bigint
  lockupPeriod: bigint
  commissionBps: number
  commissionRecipient: Address
  estimatedNetworkFeePerPeriod?: bigint
  estimatedProviderNetPerPeriod?: bigint
  caps: BossCaps
  assurance: BossAssurance
  dependency: 'none' | 'soft' | 'hard'
  activation: 'immediate' | 'provider-ack'
  pauseAllowed: boolean
  transactionsRequired: BossPlannedTransaction[]
}

export type BossPlannedTransaction =
  | { type: 'approve-token'; amount: bigint }
  | { type: 'deposit-filecoin-pay'; amount: bigint }
  | {
      type: 'set-boss-operator-approval'
      rateAllowance: bigint
      lockupAllowance: bigint
      maxLockupPeriod: bigint
    }
  | { type: 'accept-offer' }

export interface BossAcceptanceExecution {
  bossAccount: Address
  tokenApprovalTxHash?: Hex
  depositTxHash?: Hex
  operatorApprovalTxHash?: Hex
  acceptanceTxHash: Hex
  subscriptionId: Hex
  railId: bigint
}

export interface BossSubscriptionView {
  id: Hex
  account: Address
  resource: BossResource
  railId: bigint
  state:
    | 'pending-activation'
    | 'active'
    | 'paused'
    | 'terminating'
    | 'ended'
    | 'exhausted'
  provider: Address
  beneficiary: Address
  currentRatePerEpoch: bigint
  currentFixedBudget: bigint
  quoteValidThroughEpoch: bigint
  settledGross: bigint
  oneTimeChargedGross: bigint
  caps: BossCaps
}
```

---

## 15. Proposed `ServicesManager` API

```typescript
export class ServicesManager {
  async getOrCreateAccount(options?: {
    implementationVersion?: bigint
  }): Promise<Address>

  async catalog(options?: {
    resource?: BossResource
    provider?: Address
    serviceType?: Hex
  }): Promise<ServiceCatalogEntry[]>

  async quote(input: QuoteServiceInput): Promise<BossQuote>

  async planFunding(input: {
    quote: BossQuote
    depositBufferDays?: number
  }): Promise<BossFundingPlan>

  async accept(input: {
    quote: BossQuote
    plan?: BossFundingPlan
    accessGrantHash?: Hex
    confirmations?: number
  }): Promise<BossAcceptanceExecution>

  async list(options?: {
    resource?: BossResource
    state?: BossSubscriptionView['state']
  }): Promise<BossSubscriptionView[]>

  async get(subscriptionId: Hex): Promise<BossSubscriptionView>

  async sync(subscriptionId: Hex): Promise<Hex>
  async pause(subscriptionId: Hex): Promise<Hex>
  async resume(subscriptionId: Hex): Promise<Hex>
  async terminate(subscriptionId: Hex): Promise<Hex>

  async topUp(input: {
    subscriptionId: Hex
    amount: bigint
  }): Promise<{
    depositTxHash?: Hex
    approvalTxHash?: Hex
    topUpTxHash: Hex
  }>

  async reconcile(subscriptionId: Hex): Promise<BossSubscriptionView>
}
```

The manager should expose typed simulation results before submitting writes and should preserve partial progress when the user rejects or a transaction fails.

---

## 16. Proposed CLI mapping

| CLI | SDK call |
|---|---|
| `services catalog` | `synapse.services.catalog` |
| `services quote` | `synapse.services.quote` |
| `services add` | `planFunding` + `accept` |
| `services list` | `list` |
| `services show` | `get` |
| `services sync` | `sync` |
| `services pause` | `pause` |
| `services resume` | `resume` |
| `services stop` | `terminate` |
| `services top-up` | `topUp` |
| `services claims` | Boss subgraph/read API |

The CLI should not reimplement pricing formulas when the contract/SDK can quote them. Local calculations are for display and cross-checking only.

---

## 17. Open interface decisions for PR A1

These must be resolved before interfaces are frozen:

1. Whether provider address is automatically an authorized offer signer.
2. Whether owner cap reductions are supported in account version 1.
3. Whether `evidenceURI` is emitted as a string or only represented by a content hash.
4. Exact maximum bundle component count.
5. Exact adapter `staticcall` gas stipend.
6. Whether adapter registry is governed by a protocol multisig or an immutable allowlist in account version 1.
7. Whether capacity quote TTL can be zero for a non-expiring dynamic quote; recommended public default is to require nonzero.
8. Whether a hard dependency automatically calls termination or only becomes zero-paying and emits a reconciliation signal.
9. Exact Filecoin Pay validator note strings; they should be short and machine-enumerable because V1 does not accumulate notes across segments.
10. Whether `BossStateView.quoteAcceptance` is deployed in the first contract release or implemented entirely in Synapse until the view ABI stabilizes.

None of these decisions may change the accepted beneficiary, user cap, resource binding, or non-reverting termination callback.

