# B4 documentation

This set explains the **shipped implementation**: how it works, how to build on it, and how
to operate it. The *normative* behavior it is judged against lives in
[`../spec/`](../spec/) — start with [`../spec/SPECIFICATION.md`](../spec/SPECIFICATION.md)
when you need the authoritative `MUST`/`MUST NOT` statements.

> **Pre-mainnet.** Not externally audited; the funded release gates
> ([`../spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §5) are unmet. See
> [`../REPORT.md`](../REPORT.md) for exactly what is and is not proven.

## Reading order

| # | Document | Read it for |
|---|---|---|
| 1 | [Overview](01-overview.md) | What B4 is, the product ladder, the external anchors |
| 2 | [Core concepts](02-core-concepts.md) | The calendar, the exposure equation, vault vs pool |
| 3 | [Contract map](03-contracts.md) | What each contract does — and what it may not do |
| 4 | [Integration](04-integration.md) | Signatures, the owner/keeper lifecycle, events |
| 5 | [Security model](05-security.md) | Trust boundaries, invariants, audit posture |
| 6 | [Deployment](06-deployment.md) | Runbook and the funded release-gate checklist |
| 7 | [Fees, penalty and the pool](07-fee-routing.md) | Performance fee, fee route, exit penalty, claims |
| 8 | [Keeper operations](08-keeper.md) | Running the permissionless crank |
| 9 | [Roles](09-roles.md) | Owner / operator / referrer / keeper — flows, earnings, hard limits |
| 10 | [Off-chain architecture](10-offchain-architecture.md) | API, automation and UI — trust boundaries for operators |

**Integrating?** 1 → 2 → 4. **Auditing?** 2 → 3 → 5, then
[`../spec/HAZARDS.md`](../spec/HAZARDS.md) and [`../INVARIANTS.md`](../INVARIANTS.md).
**Deploying?** 6 → 8. **Running an interface?** 9 → 10.

## The one-paragraph version

A user deposits a directional asset plus canonical USDC into an isolated **vault** clone and
selects a policy: a `(growth, fall)` target pair times a scale. Time since the last *proven*
Bitcoin halving picks and interpolates the active signed target `n`; it decomposes once as
`spot = clamp(n, 0, 1)` and `perp = n − spot`. Execution against HyperCore is
**asynchronous** — actions are emitted, then their effect is *proven* by a later Core state
read, and accounting only ever credits actual received balance deltas. At each settlement
checkpoint, profit over the entry ledger is fee'd, the operator cut is paid in kind, and the
client share becomes reward weight in a shared **pool**. The pool is funded by the early-exit
penalty — out of which the operator/referrer payment is carved first, so only the residual
reaches the pool — and its inventory is distributed in kind, pro rata to weight, with no
internal swap. The vault, pool and factory contracts have no admin, no upgrade path and no
privileged fund mover; a permissionless **keeper** merely advances the machine.

## Related records

- [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — design decisions and async discipline (normative
  for the implementation per `HAZARDS` G3)
- [`../INVARIANTS.md`](../INVARIANTS.md) — invariant → test traceability with honest gaps
- [`../REPORT.md`](../REPORT.md) — the security dossier and full internal audit history
- [`../SLITHER.md`](../SLITHER.md) — static-analysis triage
- [`../SECURITY.md`](../SECURITY.md) — how to report a vulnerability
