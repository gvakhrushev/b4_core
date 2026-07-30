# Finding registry

**One row per finding, ever. This file is the index; nothing else is.**

Audits used to land as a new narrative document each round — twelve of them, ~350 KB, each true on
its own date and none authoritative. That is not an archive, it is a set of claims a reader has to
reconcile, and it actively misleads: a 2026-07-30 sweep spent real effort chasing figures that were
correct in 2026-07-20 and stale since, and found `Keeper.sol` citing a test file that had never
existed. A pile of reports does not accumulate into knowledge — it accumulates into work.

So the reports stop being the record. **A finding lives in exactly three places**: this row, the
code that fixes it, and the test that keeps it fixed. Anything else the round produced is reasoning,
and reasoning belongs next to the code it explains — which is where this codebase already puts it.

## How to use this in the next audit

- **Adding findings:** append rows. Do not write a new report document.
- **Re-finding something:** if an ID already exists, extend that row rather than opening a new one —
  the repeat is information about the fix, not a new defect.
- **Status is the load-bearing column.** `Fixed` means a test fails without the fix. `Enforced`
  means no defect existed but a property was resting on unenforced reasoning and now is not.
  `Accepted` means the residual is documented and deliberate. `Open` means it is not fixed —
  and there should be very few, named plainly.
- **Every `Fixed` and `Enforced` row names its test**, and `script/check-citations.sh` fails the
  build if that test stops existing. That is what stops this file rotting the way the reports did.

## Where the narrative went

The pre-registry reports are in [`archive/`](archive/), unchanged and non-normative. They are
source material, correct as of their dates, and are **not** maintained: `AUDIT-V6.md` cites
`Backtest.t.sol`, which existed when written and was later replaced. Read them for provenance,
never for current behaviour. For current behaviour read `spec/`, `INVARIANTS.md` and the code.

## Registry

| ID | Date | Sev | Finding | Status | Lives in | Kept fixed by |
|---|---|---|---|---|---|---|
| **V6-M-1** | 2026-07-20 | Medium | Anchor ratchet promotes sparsely-sampled windows → one-directional over-leverage (latent; durable on-chain data) | see [`AUDIT-V6.md`](archive/AUDIT-V6.md) | — | — |
| **V6-M-2** | 2026-07-20 | Medium | USDC deposits never reach the strategy; dir-only leveraged deposits run silently unlevered (C7 remnant, still live) | see [`AUDIT-V6.md`](archive/AUDIT-V6.md) | — | — |
| **V6-M-3** | 2026-07-20 | Medium | A same-sign residual perp below the $10 venue minimum is never closed; planner never converges | see [`AUDIT-V6.md`](archive/AUDIT-V6.md) | — | — |
| **V6-M-4** | 2026-07-20 | Medium | Spot orders emitted below the $10 venue minimum after lot flooring → rejection wedge (H3); MockCore hides the class | see [`AUDIT-V6.md`](archive/AUDIT-V6.md) | — | — |
| **V6-M-5** | 2026-07-20 | Medium | The team's High-rated F2 fix is tested only against an in-test mirror; its "fail-before" claim is false | see [`AUDIT-V6.md`](archive/AUDIT-V6.md) | — | — |
| **V6-M-6** | 2026-07-20 | Medium | Halving root-of-trust rests entirely on the Citrea light client + LZ DVN config + delegate renouncement (config-gated) | see [`AUDIT-V6.md`](archive/AUDIT-V6.md) | — | — |
| **C5** | 2026-07-21 | High | `B4VaultEngine.sol:783` | see [`AUDIT-2026-07-structural-leverage.md`](archive/AUDIT-2026-07-structural-leverage.md) | — | — |
| **C9** | 2026-07-21 | High | `B4VaultOps.sol:89` | see [`AUDIT-2026-07-structural-leverage.md`](archive/AUDIT-2026-07-structural-leverage.md) | — | — |
| **C10** | 2026-07-21 | Medium | `B4Pool.sol:235` | see [`AUDIT-2026-07-structural-leverage.md`](archive/AUDIT-2026-07-structural-leverage.md) | — | — |
| **C7** | 2026-07-21 | Medium | `B4Vault.sol:130` | see [`AUDIT-2026-07-structural-leverage.md`](archive/AUDIT-2026-07-structural-leverage.md) | — | — |
| **V8-M-1** | 2026-07-24 | Medium | Under-sampled anchors produce LIVE over-leverage (sparse peak confirmed; V6-M-1 now load-bearing) | see [`AUDIT-V8.md`](archive/AUDIT-V8.md) | — | — |
| **V8-M-2** | 2026-07-24 | Medium | Peak wick-poisoning: unrepairable in-window; next-cycle over-leverage or a full-cycle short outage | see [`AUDIT-V8.md`](archive/AUDIT-V8.md) | — | — |
| **V8-M-3** | 2026-07-24 | Medium | User-facing benchmark and shipped-status claims are stale in BOTH directions; the test pins cannot catch the drift | see [`AUDIT-V8.md`](archive/AUDIT-V8.md) | — | — |
| **V8-M-4** | 2026-07-24 | Medium | Carried from V6: spot orders still emitted below the $10 venue minimum after lot flooring | see [`AUDIT-V8.md`](archive/AUDIT-V8.md) | — | — |
| **C-1** | 2026-07-25 | Critical | Just-in-time checkpoint weight: post-lock deposits mint unbounded pool weight, and pool-side weight survives a full exit | see [`AUDIT-2026-07-25-full-security.md`](archive/AUDIT-2026-07-25-full-security.md) | — | — |
| **C-2** | 2026-07-25 | Critical | `_verifySpotOrder` completes on the externally-toppable destination balance | see [`AUDIT-2026-07-25-full-security.md`](archive/AUDIT-2026-07-25-full-security.md) | — | — |
| **H-1** | 2026-07-25 | High | `capturePenalty()` escrows the pool's entire unattributed balance, not the exit's receipt | see [`AUDIT-2026-07-25-full-security.md`](archive/AUDIT-2026-07-25-full-security.md) | — | — |
| **H-2** | 2026-07-25 | High | A zero spot-price read re-sizes a HELD structural perp by the flat-φ rule | see [`AUDIT-2026-07-25-full-security.md`](archive/AUDIT-2026-07-25-full-security.md) | — | — |
| **H-3** | 2026-07-25 | High | The two ledger-WRITING consumers of `_livePxWad()` have no zero-price guard | see [`AUDIT-2026-07-25-full-security.md`](archive/AUDIT-2026-07-25-full-security.md) | — | — |
| **H-4** | 2026-07-25 | High | The L-halving branch feeds the post-halving running low into the delta-anchor slot | see [`AUDIT-2026-07-25-full-security.md`](archive/AUDIT-2026-07-25-full-security.md) | — | — |
| **M-1** | 2026-07-25 | Medium | `_verifyReturn`'s post-timeout re-clamp can make the completion predicate unsatisfiable forever | see [`AUDIT-2026-07-25-full-security.md`](archive/AUDIT-2026-07-25-full-security.md) | — | — |
| **M-2** | 2026-07-25 | Medium | `usdcMarginEvm` has no reclassify-back path | see [`AUDIT-2026-07-25-full-security.md`](archive/AUDIT-2026-07-25-full-security.md) | — | — |
| **M-3** | 2026-07-25 | Medium | Incomplete V8-M-2: the anchor density gate counts samples but does not gate the value ratchet | see [`AUDIT-2026-07-25-full-security.md`](archive/AUDIT-2026-07-25-full-security.md) | — | — |
| **L-1** | 2026-07-25 | Low | Pool-owned sleeves can never execute the vault's recovery entrypoints | see [`AUDIT-2026-07-25-full-security.md`](archive/AUDIT-2026-07-25-full-security.md) | — | — |
| **L-2** | 2026-07-25 | Low | The shipped Keeper never calls `sampleAnchor` | see [`AUDIT-2026-07-25-full-security.md`](archive/AUDIT-2026-07-25-full-security.md) | — | — |
| **L-3** | 2026-07-25 | Low | `_perpTargetMargin` divides by a live `g` while using a frozen stop, with no `g != 0` guard on that branch | see [`AUDIT-2026-07-25-full-security.md`](archive/AUDIT-2026-07-25-full-security.md) | — | — |
| **L-4** | 2026-07-25 | Low | The first-credit activation allowance is re-derived at the live price on every poll | see [`AUDIT-2026-07-25-full-security.md`](archive/AUDIT-2026-07-25-full-security.md) | — | — |
| **L-5** | 2026-07-25 | Low | `slippageBps` is validated only from above; a vault created at 0 is permanently unable to rotate | see [`AUDIT-2026-07-25-full-security.md`](archive/AUDIT-2026-07-25-full-security.md) | — | — |
| **L-6** | 2026-07-25 | Low | The V8-L-1 zero-mark guard reports false progress | see [`AUDIT-2026-07-25-full-security.md`](archive/AUDIT-2026-07-25-full-security.md) | — | — |
| **F3** | 2026-07-29 | High | Permissionless `claimDeferred` races an in-flight Core→EVM return → permanent wedge | Fixed | `B4VaultEngine._unaccountedEvm` | DeferredClaimReturnRace.t.sol |
| **F1** | 2026-07-29 | Medium | Exit-weight forfeiture gated on exact `keep == 0`, so `initiateExit(WAD−1)` kept 100% of the reported weight | Fixed | `B4Pool.scaleWeight` | AuditHalfB_ExitWeightOrder.t.sol |
| **F2** | 2026-07-29 | Medium | Peak-anchor daily slot squattable: a suppressed `peakC` over-levers every structural short | Fixed | `B4Pool.sampleAnchor` | AuditF2_PeakSlotSquat.t.sol |
| **F4** | 2026-07-29 | Low | One-shot `settle` let a third party pin another vault's weight at a trough | Fixed | `B4Vault.snapshotNav` | AuditF4_SettleValuationInstant.t.sol |
| **A6** | 2026-07-30 | High | A lost Core→EVM credit froze the whole vault forever, with no escape | Fixed | `B4VaultRecovery.opsAbandonStuckReturn` | AuditA6_StuckReturnEscape.t.sol |
| **A9** | 2026-07-30 | High | The A6 escape did not exist for pool-owned sleeves (the L-1 gap, repeated) | Fixed | `B4Pool.abandonSleeveStuckReturn` | AuditL1_SleeveEscapes.t.sol |
| **A1** | 2026-07-30 | Medium | Deposit inside the settlement window dropped from the entry basis → phantom profit | Fixed | `B4Vault.deposit` | AuditA_ClosureFixes.t.sol |
| **A2** | 2026-07-30 | Medium | Spot principal above the real Core balance livelocked the Return leg (M-1 second clause) | Fixed | `B4VaultOps._reconcileSpot` | AuditA_ClosureFixes.t.sol |
| **A5** | 2026-07-30 | Medium | Exit between snapshot and settle minted on withdrawn capital (5.3× overstated profit) | Fixed | `B4VaultOps._finalizeExit` | AuditF4_SettleValuationInstant.t.sol |
| **A7** | 2026-07-30 | Medium | Settle could value the vault above its own books after a realized loss | Fixed | `B4VaultOps.opsSettle` (min-cap) | AuditF4_SettleValuationInstant.t.sol |
| **A10** | 2026-07-30 | Low | policy-id vs mask-bit divergence returned a silent zero for Pro/Pro Max | Documented | `B4Pool.policyMask` docstring | — |
| **A11** | 2026-07-30 | Low | A silently downgraded penalty routing had no on-chain trace (G1) | Fixed | `PenaltyRoutingDegraded` event | — |
| **A3** | 2026-07-30 | Low | `_startPerpOrder` reported false progress on a dead mark feed | Fixed | `B4VaultEngine._startPerpOrder` | AuditA_ClosureFixes.t.sol |
| **A4** | 2026-07-30 | Low | `selectPolicy` could re-target while a leg was in flight | Fixed | `B4VaultOps.opsSelectPolicy` | AuditA_ClosureFixes.t.sol |
| **A8** | 2026-07-30 | Low | `anchorConfirmed` reported a confirmed peak that served nothing | Fixed | `B4Pool.anchorConfirmed` | AuditF2_ConfirmedWithoutValue.t.sol |
| **A12** | 2026-07-30 | — | Exit-waterfall safety rested on hand proofs, unenforced | Enforced | `_payBucket` | Exit.t.sol (fuzz) |
| **A13** | 2026-07-30 | — | F1's partial-scaling case had no deterministic test | Enforced | `B4Pool.scaleWeight` | StrictPool.invariant.t.sol |
| **A14** | 2026-07-30 | — | Keeper gas budgets cited a test that never existed; three figures stale, one false | Fixed | `Keeper` budgets | GasBounds.t.sol |
