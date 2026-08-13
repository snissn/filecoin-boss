# Filecoin Boss

Filecoin Boss is a user-owned service-composition layer for Filecoin Onchain Cloud resources.

It is designed to let a user attach independently operated and independently billed services to an existing PDP or FWSS-backed data set while preserving the user's control of the underlying resource, payment authorization, service bundle, spending caps, and termination rights.

The protocol reuses Filecoin Pay rather than introducing a new payment rail. Each independently governed service receives its own bounded Filecoin Pay rail and lifecycle.

> **Status:** specification and implementation planning. The contracts and APIs described here are not yet production code or audited.

## Document set

| Document | Purpose |
| --- | --- |
| [Document-set index](docs/FILECOIN_BOSS_DOCUMENT_SET_INDEX.md) | Reading order, authority, source locks, and package overview |
| [Normative specification v0.2](docs/FILECOIN_BOSS_SPEC_v0.2.md) | Protocol behavior, authority model, billing, lifecycle, caps, and invariants |
| [Implementation draft](docs/FILECOIN_BOSS_IMPLEMENTATION_DRAFT_v0.1.md) | Proposed repository trees, exact components, integration seams, and PR ordering |
| [API and event draft](docs/FILECOIN_BOSS_API_AND_EVENT_DRAFT_v0.1.md) | Near-source Solidity interfaces, structs, events, TypeScript APIs, and pseudocode |
| [Test and rollout plan](docs/FILECOIN_BOSS_TEST_AND_ROLLOUT_PLAN_v0.1.md) | Unit, integration, invariant, devnet, Calibration, audit, and release gates |
| [Human-facing summary](docs/FILECOIN_BOSS_HUMAN_SUMMARY_v0.1.md) | Product and stakeholder explanation |
| [v0.1 to v0.2 diff](docs/FILECOIN_BOSS_SPEC_v0.1_to_v0.2.diff) | Unified textual revision history |
| [Archived v0.1 specification](docs/archive/FILECOIN_BOSS_SPEC_v0.1.md) | Original supplied design |
| [Manifest](docs/manifest.json) | Document hashes, byte sizes, statuses, and source locks |

## Proposed implementation repositories

The implementation graph spans these `snissn` repositories:

- [`snissn/filecoin-boss`](https://github.com/snissn/filecoin-boss): contracts, adapters, deployment, protocol tests, and final cross-repository evidence.
- [`snissn/synapse-sdk`](https://github.com/snissn/synapse-sdk): low-level Boss primitives and the high-level services API.
- [`snissn/filecoin-pin`](https://github.com/snissn/filecoin-pin): reference CLI service discovery, quoting, attachment, funding, synchronization, metering, and termination flows.
- [`snissn/filecoin-pay-explorer`](https://github.com/snissn/filecoin-pay-explorer): Boss indexing, read-only service pages, Filecoin Pay rail association, and user console actions.

The MVP consumes the existing Filecoin Pay, PDP, and FWSS interfaces without requiring runtime changes to their upstream contracts.

## Initial product slices

The first implementation is specified around three billing examples:

1. a flat additional `1 USDFC` per accepted data-set subscription per 30-day month;
2. an additional `1 USDFC/TiB` per 30-day month, synchronized from PDP capacity;
3. a capped trusted-metering model for CDN-like bandwidth charges using fixed Filecoin Pay lockup and explicit per-claim, per-window, and lifetime limits.

The first commercial pilot is a Filone-style managed-storage offer composed over an existing FWSS/PDP data set without forking FWSS.

## Development policy

Implementation work is tracked through linked umbrella and child issues. Each executable issue owns one coherent reviewable slice, names its first red behavior or invariant, classifies performance relevance, and has one authoritative completion gate.

No specification in this repository should be interpreted as an audit, deployment approval, or guarantee of production safety until the final security and release gates are complete.
