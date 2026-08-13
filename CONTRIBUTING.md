# Contributing to Filecoin Boss

## Authority and scope

Start from the owning GitHub issue. Each implementation issue owns one coherent exit gate and names its dependencies, target branch, first failing behavior, tests, and non-goals.

The normative protocol is `docs/FILECOIN_BOSS_SPEC_v0.2.md`. Source revisions are pinned in `SOURCE_LOCKS.md`.

## Branches and pull requests

- Protocol issue branches: `gpt56/issue-<number>-<slug>` from current `main`.
- Downstream issue branches follow the same pattern and target their repository's `gpt56/tracker-filecoin-boss-*` branch.
- Use Conventional Commit titles.
- Keep PRs draft until the focused behavior, affected tests, and required evidence are coherent.
- Latest-head CI is authoritative; stale green checks do not prove mergeability.

## Test-first workflow

1. Add the smallest test that fails for the intended external behavior or invariant.
2. Record an explicit exception for bootstrap, generated artifacts, or documentation-only changes where an artificial red test would add no protection.
3. Implement the smallest coherent change that makes the test pass.
4. Refactor while focused and affected suites remain green.
5. Record gas, RPC/query, or other performance evidence only when the owning issue classifies the path as performance-relevant.

## Design discipline

- Reuse Filecoin Pay, PDP, FWSS, and maintained client interfaces; do not create parallel ledgers or ownership models.
- Prefer direct data structures and explicit lifecycle code over speculative frameworks.
- Do not add upgrade, plugin, arbitration, keeper, storefront, or access-control machinery before a current issue requires it.
- Payment authorization and data-access authorization remain separate.
- One independently governed service maps to one independently governed Filecoin Pay rail.

## Local contract commands

```sh
forge fmt --check
forge build --sizes
forge test -vvv
```

The CI workflow uses Foundry `v1.3.5` and Solidity `0.8.30`, matching the locked Filecoin Pay toolchain.

## Generated artifacts

Generated ABIs and deployment manifests must be reproducible from committed source and scripts. Do not hand-edit generated output. Every artifact must record the exact protocol commit and deployment/network authority it represents.
