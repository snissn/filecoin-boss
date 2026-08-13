# ADR 0001: Boss accounts are user-owned and immutable in v1

- **Status:** Accepted
- **Date:** 2026-08-13
- **Authority:** `docs/FILECOIN_BOSS_SPEC_v0.2.md`

## Context

Filecoin Pay V1 grants an operator bounded authority to create and manage rails for a payer. Giving a service provider direct operator authority would couple commercial participation to payment control and would make safe underfunded termination dependent on provider behavior.

Boss also must not make payment authorization equivalent to custody or data access.

## Decision

Each payer uses a deterministic Boss account whose v1 owner is the Filecoin Pay payer.

The Boss account, not the provider, is the Filecoin Pay operator and validator for Boss add-on rails. The account is immutable in v1: it has no implementation-upgrade entry point and no ownership-transfer entry point.

The owner explicitly accepts signed offers and spending caps. Providers, reporters, and storefronts receive only the narrowly defined roles pinned by an accepted offer.

Data-access capabilities are granted and revoked separately; they are never inferred from service payment state.

## Consequences

- A user can terminate a Boss rail through the Boss operator path even when direct payer termination is funding-sensitive.
- A provider cannot create arbitrary rails or broaden user caps.
- Wallet recovery belongs to the owner's smart-account or multisig design, not to a mutable Boss ownership hook.
- A future ownership-transfer or upgrade design requires a new version and explicit security review; it is not an implicit extension of v1.
