# Filecoin Boss implementation stack verification

**Verified:** 2026-08-13  
**Canonical graph:** [`docs/IMPLEMENTATION_ISSUE_GRAPH.md`](IMPLEMENTATION_ISSUE_GRAPH.md)

## Canonical protocol state

- Repository: `snissn/filecoin-boss`
- Default and integration branch: `main`
- Documentation-package commit: `8b287f59b142107753e82d9ab0cd96e3ba7afd87`
- Graph-ledger commit: `345a268814a6055fed7140c182f2f4e9b0bca286`
- Umbrella: [`#1`](https://github.com/snissn/filecoin-boss/issues/1)
- First unblocked node: [`#2`](https://github.com/snissn/filecoin-boss/issues/2)

The exact v0.2 normative specification, implementation draft, API/event draft, test/rollout plan, human summary, revision diff, manifest, and v0.1 archive are present under `docs/`. Temporary document staging and one-shot assembly workflows have been removed.

## Downstream tracker branches

| Repository | Reconciled default head | Tracker issue | Tracker branch |
|---|---|---|---|
| `snissn/synapse-sdk` | `831c5b84053e6a6bf5983eed988310c7b43bac3e` | [`#4`](https://github.com/snissn/synapse-sdk/issues/4) | `gpt56/tracker-filecoin-boss-sdk` |
| `snissn/filecoin-pin` | `e1ba69309c645302bfbd97fd75e4b267732c2b68` | [`#35`](https://github.com/snissn/filecoin-pin/issues/35) | `gpt56/tracker-filecoin-boss-cli` |
| `snissn/filecoin-pay-explorer` | `e8902ea3b6489fdb4680616dc90ce3e322f3436c` | [`#13`](https://github.com/snissn/filecoin-pay-explorer/issues/13) | `gpt56/tracker-filecoin-boss-explorer` |

Each tracker branch was created from the listed reconciled default head. Downstream implementation PRs target tracker branches, not default branches. A tracker-to-default PR is a repository release gate, not a routine child merge.

## Live graph inventory

- Protocol: `filecoin-boss#2` through `#14`
- Synapse SDK: `synapse-sdk#5` through `#8`
- Filecoin Pin: `filecoin-pin#36` through `#39`
- Explorer: `filecoin-pay-explorer#14` through `#17`

Total live control-plane issues in this graph: 29, including the four tracker/umbrella issues.

## Existing adjacent work

Existing funding, target-runway, Squid, guided-top-up, and alert issues remain retained. They are not rewritten as Boss work and are not treated as evidence that Boss support exists.

## Execution constraints

- Maximum active implementation lanes: three.
- Current first lane: protocol A0 / `filecoin-boss#2`.
- Downstream lanes remain blocked until the exact protocol or Synapse artifacts named by their issue bodies exist.
- Every PR-bearing issue owns one exit gate and requires start-phase failing behavior or an explicit allowed exception.
- Latest-head CI, not historical checks, controls mergeability.
- Ponytail/YAGNI applies: extend maintained seams, avoid speculative frameworks, and keep each issue to the smallest coherent implementation that satisfies its gate.
