# ADR 0002: Each independently governed service uses a separate Filecoin Pay rail

- **Status:** Accepted
- **Date:** 2026-08-13
- **Authority:** `docs/FILECOIN_BOSS_SPEC_v0.2.md`

## Context

A Boss bundle may combine base FWSS storage with services from several independent providers. Hiding those obligations inside one aggregate rail would obscure recipients, caps, settlement rules, lifecycle, and failure isolation.

Filecoin Pay already supplies point-to-point rails, rates, fixed lockup, validators, operators, and settlement. Boss should add service semantics rather than another payment ledger.

## Decision

Every independently governed Boss service subscription maps to one independently governed Filecoin Pay rail with its own beneficiary, pricing rule, fixed lockup, cap policy, validator state, and lifecycle.

The existing FWSS storage rail remains unchanged. A user-owned bundle is only a grouping and presentation object; it does not become an economic recipient or acquire authority over its member rails.

## Consequences

- One service can pause, degrade, or terminate without deleting the PDP dataset or stopping unrelated services.
- Storefronts may present a unified total, but every component and recipient remains visible before acceptance.
- Account-level Filecoin Pay solvency may still be shared across rails; Boss must disclose that rather than imply hidden payment priority.
- A future aggregate-rail or priority model would be a different protocol and is outside v1.
