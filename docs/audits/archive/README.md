# Archive — pre-registry audit reports

**Non-normative. Correct as of their dates, not maintained, and not the record.**

These are the narrative reports from six audit rounds. They were superseded on 2026-07-30 by
[`../REGISTRY.md`](../REGISTRY.md), which is now the only index of findings.

## Why they stopped being the record

Each round produced a document. After twelve of them — ~350 KB — the archive had become a set of
claims a reader has to reconcile rather than knowledge they can use, and it began to actively
mislead. Two concrete costs, both paid:

- a sweep spent real effort chasing gas figures that were correct when written and stale since;
- `Keeper.sol` cited `test/unit/GasBounds.t.sol` as the source of all four of its budgets, three
  times over, and that file had never existed — a citation to a missing test reads as evidence, so
  it suppressed the checking it appeared to have had.

A pile of reports does not accumulate into knowledge. It accumulates into work.

## What to use instead

| You want | Read |
|---|---|
| What was ever found, and where it lives now | [`../REGISTRY.md`](../REGISTRY.md) |
| What the code must do | [`../../../spec/`](../../../spec/) |
| Which test holds an invariant | [`../../../INVARIANTS.md`](../../../INVARIANTS.md) |
| Why the code is shaped this way | [`../../../ARCHITECTURE.md`](../../../ARCHITECTURE.md) and the code comments |
| Provenance — how a finding was reasoned about at the time | these files |

## Known-stale by design

`AUDIT-V6.md` cites `Backtest.t.sol`, which existed when written and was later replaced by
`BacktestReal.t.sol`. That is not a defect to fix: an audit record's job is to record what was true
on its date. `script/check-citations.sh` therefore treats this directory as advisory and never
fails the build on it, while enforcing every live document strictly.
