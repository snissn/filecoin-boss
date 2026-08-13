# Filecoin Boss agent guidance

Read `CONTRIBUTING.md`, `SOURCE_LOCKS.md`, the owning issue, and `docs/IMPLEMENTATION_ISSUE_GRAPH.md` before changing code.

Key rules:

- Work only on the owning `gpt56/issue-<number>-<slug>` branch.
- Preserve the user-owned account, separate-service/separate-rail, and separate data-access boundaries.
- Start with a meaningful failing test or record the issue's permitted exception.
- Prefer the smallest maintained seam; do not add speculative factories, plugins, proxies, keepers, or arbitration.
- Do not duplicate Filecoin Pay accounting, PDP/FWSS ownership, or downstream SDK calculations.
- Run `forge fmt --check`, `forge build --sizes`, and `forge test -vvv` before claiming contract work is ready.
- Update the child issue first after a merge, then its tracker and the canonical graph ledger.
