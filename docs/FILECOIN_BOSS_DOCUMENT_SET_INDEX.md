# Filecoin Boss v0.2 document set

**Prepared:** 2026-08-12  
**Purpose:** Move the Filecoin Boss concept from architecture proposal to an implementation-ready design package.

---

## Files

### `FILECOIN_BOSS_SPEC_v0.2.md`

The revised normative specification.

Use this document to review:

- user, provider, storefront, and resource authority;
- one-service/one-rail payment topology;
- signed offer and cap semantics;
- exact MVP resource support;
- lifecycle and termination rules;
- flat, capacity, and metered billing;
- implementation repository boundary;
- mandatory release invariants.

### `FILECOIN_BOSS_IMPLEMENTATION_DRAFT_v0.1.md`

The engineering implementation plan.

It contains:

- proposed `filecoin-boss` repository tree;
- exact contract and library files;
- contract responsibilities and Filecoin Pay call order;
- adapter implementation details;
- exact Synapse, Filecoin Pin, and Explorer file changes;
- Boss subgraph entities;
- optional upstream follow-ups;
- ordered pull-request graph;
- end-to-end definition of done.

### `FILECOIN_BOSS_API_AND_EVENT_DRAFT_v0.1.md`

A near-source interface draft.

It contains proposed:

- Solidity enums and structs;
- Filecoin Pay compatibility interface;
- resource and pricing adapter interfaces;
- factory, service registry, adapter registry, and account interfaces;
- events;
- internal mappings;
- acceptance, validation, termination, and usage-claim pseudocode;
- TypeScript SDK types;
- `ServicesManager` API;
- CLI mapping;
- interface decisions that must be resolved in PR A1.

This file is not represented as compiling or audited code.

### `FILECOIN_BOSS_TEST_AND_ROLLOUT_PLAN_v0.1.md`

The quality and release plan.

It contains:

- exact Foundry unit, integration, fuzz, and invariant test files;
- Filecoin Pay V1 compatibility scenarios;
- PDP/FWSS integration scenarios;
- Synapse, Filecoin Pin, subgraph, and Explorer tests;
- cross-repository devnet scenario;
- Calibration stages;
- mainnet gates;
- security review and audit scope;
- monitoring and reconciliation;
- release checklist.

### `FILECOIN_BOSS_HUMAN_SUMMARY_v0.1.md`

The product- and stakeholder-facing explanation.

It covers:

- what Boss is;
- why it is needed;
- user experience;
- authority model;
- billing models;
- failure behavior;
- repository impact;
- recommended FilOne pilot;
- MVP and product decisions.

### `FILECOIN_BOSS_SPEC_v0.1_to_v0.2.diff`

A unified textual diff from the supplied v0.1 specification to the revised v0.2 specification.

### `manifest.json`

Machine-readable file list, byte sizes, SHA-256 hashes, source locks, and document status.

---

## Reading order

### Product review

1. Human summary.
2. Specification §§0–5 and §§15–18.
3. FilOne decision list in specification §25.
4. Implementation draft §18.

### Protocol and smart-contract review

1. Specification §§6–16.
2. API and event draft.
3. Implementation draft §§4–9.
4. Test plan §§3–7 and §§15–18.

### SDK, CLI, and Explorer review

1. Implementation draft §§10–13.
2. API draft §§13–15.
3. Test plan §§8–11.
4. Specification §20.

### Program planning

1. Implementation draft §15.
2. Specification §23.
3. Test plan §§12–17.

---

## Specification change map

| v0.2 section | Change from v0.1 |
|---|---|
| Header / changelog | Updated date/source locks and summarized implementation decisions |
| §6 | Replaced abstract core objects with exact MVP enums, offer fields, caps, subscription accounting, and access-grant commitments |
| §7 | Locked factory/account behavior, `owner == payer` MVP, adapter split, callback behavior, Pay call order, pause semantics, and event join key |
| §12 | Replaced implicit current-state billing with prospective rate sync and explicit one-day quote TTL |
| §13 | Made Boss compute metered price; fixed claim ordering, replay protection, cap formula, and top-up sequence |
| §20 | Replaced high-level integration list with exact repositories, directories, files, commands, routes, and subgraph boundary |
| §22 | Named mandatory contract, SDK, CLI, indexer, and UI test suites |
| §23 | Replaced broad phases with an ordered PR dependency graph |
| §27 | Updated all live source locks to 2026-08-12 |
| §28 | Defined this document package and first repository artifact |

---

## Required MVP code changes

```text
NEW  FilOzone/filecoin-boss
EDIT FilOzone/synapse-sdk
EDIT filecoin-project/filecoin-pin
EDIT FilOzone/filecoin-pay-explorer
```

No MVP production-contract changes:

```text
UNCHANGED FilOzone/filecoin-pay
UNCHANGED FilOzone/pdp
UNCHANGED FilOzone/filecoin-services
```

Optional later:

```text
DOCS      FilOzone/filecoin-pay
VIEW API  FilOzone/filecoin-services
RUNTIME   filecoin-project/curio
REPORTER  Filecoin Beam repositories
```

---

## First implementation sequence

```text
A0  repository + ADR scaffold
A1  types, EIP-712 hashing, interfaces
A2  service and adapter registries
A3  deterministic immutable Boss account
A4  flat streaming service over Filecoin Pay V1
A5  FWSS-backed PDP resource adapter
A6  capacity adapter + quote TTL
A7  capped metered usage
A8  bundle + state view + event completeness
A9  Calibration deployment package
A10 Boss subgraph
B0  synapse-core/boss
B1  synapse.services
C0  Filecoin Pin read-only commands
C1  Filecoin Pin accept/funding
D0  Explorer Boss client/types
D1  Explorer service/resource pages
E0  FilOne offer/storefront
```

The first scientifically meaningful implementation milestone is A4+A5: a user attaches and independently terminates a flat service on a real FWSS-backed dataset without modifying the storage contract.

---

## Source locks

| Repository | Revision |
|---|---|
| `FilOzone/filecoin-pay` | `04ded6af6c15c4b5d98545f393dc656004d4aede` |
| `FilOzone/filecoin-services` | `54885b9ad04915888ba627ae6bae94df58d68c81` |
| `FilOzone/pdp` | `4d2a930194367477050302792de89e29275a6047` |
| `FilOzone/synapse-sdk` | `811163e609cab96b8e089dd972632b221a96e8a7` |
| `filecoin-project/filecoin-pin` | `27b65c4d7314fb8539d2d5fcee06a2ab03fa4d21` |
| `FilOzone/filecoin-pay-explorer` | `0e0a7683ec20415f53f4807151221673f1590faa` |

---

## Status caveat

The package is detailed enough to open the repository scaffold and first interface PRs. It is not an audit, deployment approval, or claim that the sketched interfaces compile unchanged.

The most important unresolved product decision is whether the FilOne pilot is:

- an independently priced 2.49 USDFC/TiB/month managed-service component; or
- an exact 4.99 USDFC/TiB/month inclusive product whose add-on rate is dynamically derived from the current FWSS quote.

The recommended first pilot is the independent component.
