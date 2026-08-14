# Filecoin Boss implementation issue graph

**Authority:** [`snissn/filecoin-boss#1`](https://github.com/snissn/filecoin-boss/issues/1)  
**Protocol target:** `snissn/filecoin-boss:main`  
**Last reconciled:** 2026-08-13

This ledger is the durable navigation surface for the cross-repository implementation. Issue bodies own detailed scope and exit evidence. The umbrella owns ordering and final acceptance.

## Target branches

| Repository | Default branch | Boss integration target |
|---|---|---|
| `snissn/filecoin-boss` | `main` | `main` |
| `snissn/synapse-sdk` | `master` | `gpt56/tracker-filecoin-boss-sdk` |
| `snissn/filecoin-pin` | `master` | `gpt56/tracker-filecoin-boss-cli` |
| `snissn/filecoin-pay-explorer` | `main` | `gpt56/tracker-filecoin-boss-explorer` |

Downstream issue branches use `gpt56/issue-<number>-<slug>` and target the corresponding tracker branch. A tracker branch reaches its default branch only after its repository release gate passes.

## Protocol graph — `snissn/filecoin-boss`

| Node | Issue | Role | Depends on | Authoritative gate |
|---|---|---|---|---|
| A0 | [#2](https://github.com/snissn/filecoin-boss/issues/2) | repository/authority scaffold | none | clean-checkout Foundry CI and ownership ADRs |
| A1 | [#3](https://github.com/snissn/filecoin-boss/issues/3) | wire-format substrate | A0 | exact types, hashes, selectors, and vectors |
| A2 | [#4](https://github.com/snissn/filecoin-boss/issues/4) | signer/adapter registries | A1 | signer rotation and adapter-codehash authority |
| A3 | [#5](https://github.com/snissn/filecoin-boss/issues/5) | immutable account substrate | A1 | deterministic user-owned accounts with no upgrade/transfer seam |
| A4 | [#6](https://github.com/snissn/filecoin-boss/issues/6) | flat Pay lifecycle | A2, A3 | first complete separate-rail service lifecycle |
| A5 | [#7](https://github.com/snissn/filecoin-boss/issues/7) | FWSS/PDP resource binding | A4 | attach only the recorded FWSS payer's live resource |
| A6 | [#8](https://github.com/snissn/filecoin-boss/issues/8) | prospective capacity pricing | A5 | deterministic non-retroactive rate synchronization |
| A7 | [#9](https://github.com/snissn/filecoin-boss/issues/9) | capped trusted metering | A4 | reporter cannot exceed accepted prepaid caps |
| A8 | [#10](https://github.com/snissn/filecoin-boss/issues/10) | bundles/views/events/artifacts | A4, A6, A7 | complete bounded public integration surface |
| A9 | [#11](https://github.com/snissn/filecoin-boss/issues/11) | devnet/Calibration deployment | A8 | reproducible verified manifests |
| A10 | [#12](https://github.com/snissn/filecoin-boss/issues/12) | Boss subgraph | A8, A9 | deterministic event replay and rail association index |
| A11 | [#13](https://github.com/snissn/filecoin-boss/issues/13) | security/invariant gate | A8 | authority, cap, settlement, and termination invariants |
| A12 | [#14](https://github.com/snissn/filecoin-boss/issues/14) | FilOne/final evidence | A6, A9, A10, A11, downstream release gates | exact devnet/Calibration product lifecycle |

```text
A0 -> A1 -> {A2, A3} -> A4 -> {A5 -> A6, A7} -> A8 -> {A9 -> A10, A11} -> A12
```

## Synapse SDK graph

Tracker: [`snissn/synapse-sdk#4`](https://github.com/snissn/synapse-sdk/issues/4)

| Node | Issue | Depends on | Gate |
|---|---|---|---|
| B0 | [#5](https://github.com/snissn/synapse-sdk/issues/5) | protocol A1/A8/A9 artifacts | ABI, deployment, types, hashes, and Node/browser vectors |
| B1 | [#6](https://github.com/snissn/synapse-sdk/issues/6) | B0 and protocol lifecycle adapters | reads, quotes, transaction builders, and explicit funding plans |
| B2 | [#7](https://github.com/snissn/synapse-sdk/issues/7) | B1 | maintained `Synapse.services` lifecycle/reconciliation API |
| B3 | [#8](https://github.com/snissn/synapse-sdk/issues/8) | B2 | browser/devnet/Calibration/release evidence; React only if concretely required |

## Filecoin Pin graph

Tracker: [`snissn/filecoin-pin#35`](https://github.com/snissn/filecoin-pin/issues/35)

| Node | Issue | Depends on | Gate |
|---|---|---|---|
| C0 | [#36](https://github.com/snissn/filecoin-pin/issues/36) | Synapse B1 | signer-free catalog, quote, list, and show |
| C1 | [#37](https://github.com/snissn/filecoin-pin/issues/37) | C0, Synapse B2 | explicit funding plan and recoverable attach |
| C2 | [#38](https://github.com/snissn/filecoin-pin/issues/38) | C1 | sync, claims, top-up, pause/resume, and underfunded stop |
| C3 | [#39](https://github.com/snissn/filecoin-pin/issues/39) | C2 | documentation and devnet/Calibration release evidence |

## Filecoin Pay Explorer graph

Tracker: [`snissn/filecoin-pay-explorer#13`](https://github.com/snissn/filecoin-pay-explorer/issues/13)

| Node | Issue | Depends on | Gate |
|---|---|---|---|
| D0 | [#14](https://github.com/snissn/filecoin-pay-explorer/issues/14) | protocol A9/A10 | distinct Boss GraphQL client, types, and deployment config |
| D1 | [#15](https://github.com/snissn/filecoin-pay-explorer/issues/15) | D0 | complete signer-free offer/resource/subscription pages |
| D2 | [#16](https://github.com/snissn/filecoin-pay-explorer/issues/16) | D0 | verified Boss-subscription-to-Pay-rail association |
| D3 | [#17](https://github.com/snissn/filecoin-pay-explorer/issues/17) | D1, D2, Synapse B2 | wallet actions plus devnet/Calibration release evidence |

## Cross-repository critical path

```text
A8/A9 artifacts -> B0 -> B1 -> B2
B1 -> C0 -> C1 -> C2 -> C3
A9/A10 -> D0 -> {D1, D2} -> D3
A11 + B3 + C3 + D3 -> A12
```

## Existing work retained as adjacent authority

- Synapse issue #1 and the merged target-runway helper remain adjacent payment-planning work.
- Filecoin Pin payment-funding, Squid, and self-funding issues remain adjacent wallet-funding work.
- Explorer guided funding/top-up and alert issues remain adjacent generic Filecoin Pay work.
- These issues are not superseded and do not prove Boss support by themselves.

## Execution rules

1. Reconcile live default/tracker heads, issue bodies, PRs, and latest-head CI before opening a lane.
2. Keep at most three issue implementation lanes active; only genuinely independent nodes run in parallel.
3. Establish the failing behavior before implementation, except for explicitly documented bootstrap/generated-artifact exceptions.
4. Merge each child into its declared target only after its authoritative gate is current.
5. Prefer existing maintained primitives; reject speculative abstractions, duplicated ledgers/calculations, and unbounded query or callback surfaces.
6. Update the child first after a merge, then its tracker and this ledger.

## Current activation

A0 / [`filecoin-boss#2`](https://github.com/snissn/filecoin-boss/issues/2) is the first unblocked executable node. All downstream implementation nodes remain blocked on protocol surfaces or Synapse APIs named above.
