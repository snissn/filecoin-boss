// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

/// @notice Canonical Filecoin Boss v1 wire types and cap helpers.
library BossTypes {
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
        string note;
    }

    struct UsageClaim {
        bytes32 claimId;
        uint64 fromEpoch;
        uint64 toEpoch;
        uint256 units;
        bytes32 evidenceHash;
        string evidenceURI;
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
        uint64 quoteTtlEpochs;
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

    struct AdapterRecord {
        AdapterKind kind;
        uint64 interfaceVersion;
        bytes32 codeHash;
        bool activeForNewSubscriptions;
        string metadataURI;
    }

    struct Bundle {
        bytes32 bundleId;
        address owner;
        bytes32 resourceKey;
        bytes32 manifestHash;
        uint64 version;
    }

    function isPinnedAdapter(AdapterRecord memory record, address adapter, AdapterKind kind)
        internal
        view
        returns (bool)
    {
        return record.kind == kind && record.interfaceVersion == 1 && record.codeHash != bytes32(0)
            && adapter.code.length != 0 && adapter.codehash == record.codeHash;
    }

    function isUnlimitedCap(uint256 cap) internal pure returns (bool) {
        return cap == type(uint256).max;
    }

    function remainingCap(uint256 cap, uint256 used) internal pure returns (uint256) {
        if (isUnlimitedCap(cap)) return type(uint256).max;
        return used >= cap ? 0 : cap - used;
    }

    function isNoExpiry(uint64 notAfterEpoch) internal pure returns (bool) {
        return notAfterEpoch == 0;
    }
}
