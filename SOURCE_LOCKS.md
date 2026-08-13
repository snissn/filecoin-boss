# Filecoin Boss source locks

These commits are the reviewed design inputs for the initial Filecoin Boss implementation graph. Updating a lock requires an issue-scoped compatibility review; a newer upstream commit is not authoritative merely because it exists.

## Upstream protocol and client inputs

| Repository | Locked commit | Initial use |
| --- | --- | --- |
| `FilOzone/filecoin-pay` | `04ded6af6c15c4b5d98545f393dc656004d4aede` | Filecoin Pay V1 rail, approval, settlement, validator, and termination semantics |
| `FilOzone/filecoin-services` | `54885b9ad04915888ba627ae6bae94df58d68c81` | FWSS dataset/payer state, pricing compatibility, and base-rail boundary |
| `FilOzone/pdp` | `4d2a930194367477050302792de89e29275a6047` | PDP dataset identity, listener, liveness, and capacity state |
| `FilOzone/synapse-sdk` | `811163e609cab96b8e089dd972632b221a96e8a7` | SDK architecture and package conventions |
| `filecoin-project/filecoin-pin` | `27b65c4d7314fb8539d2d5fcee06a2ab03fa4d21` | CLI architecture and maintained payment/funding seams |
| `FilOzone/filecoin-pay-explorer` | `0e0a7683ec20415f53f4807151221673f1590faa` | Explorer, Pay subgraph, and wallet-console architecture |

## Implementation repositories

| Repository | Reconciled baseline | Filecoin Boss target |
| --- | --- | --- |
| `snissn/filecoin-boss` | `d64d94c1b12923d2467c9238051bfbe2384361ab` | `main` |
| `snissn/synapse-sdk` | `831c5b84053e6a6bf5983eed988310c7b43bac3e` | `gpt56/tracker-filecoin-boss-sdk` |
| `snissn/filecoin-pin` | `e1ba69309c645302bfbd97fd75e4b267732c2b68` | `gpt56/tracker-filecoin-boss-cli` |
| `snissn/filecoin-pay-explorer` | `e8902ea3b6489fdb4680616dc90ce3e322f3436c` | `gpt56/tracker-filecoin-boss-explorer` |

The `snissn` baselines preserve fork-only history while containing the named upstream inputs. Child issues must re-resolve their live target branch before implementation and record any compatibility delta.

## Normative local documents

The v0.2 specification and its companion drafts under `docs/` are the semantic authority. The implementation issue graph in `docs/IMPLEMENTATION_ISSUE_GRAPH.md` owns current execution order; it does not override the normative protocol semantics.
