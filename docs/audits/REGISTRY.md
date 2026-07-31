# Finding registry

**One row per finding, ever. This file is the record — there is no other.**

Audits used to land as a new narrative document each round. After twelve of them — ~350 KB — the
archive was no longer knowledge but a set of claims a reader had to reconcile, and it had started
to mislead: a 2026-07-30 sweep spent real effort chasing gas figures that were correct in July and
stale since, and found `Keeper.sol` citing a test file that had never existed, three times over,
as the source of all four of its budgets. A citation to a missing test reads as evidence, so it
suppresses the very checking it appears to have had.

A pile of reports does not accumulate into knowledge. It accumulates into work. So the reports are
gone, not archived-and-ignored: **a finding lives in exactly three places** — this row, the code
that fixes it, and the test that keeps it fixed. Reasoning lives next to the code it explains,
which is where this codebase already puts it. The narrative is recoverable from git history if
provenance is ever needed; it is not carried forward as something to maintain.

## Using this in the next audit

- **Adding findings:** append rows. Do not write a report document — that is the habit this
  replaced.
- **Re-finding something:** extend the existing row. A repeat is information about the fix, not a
  new defect. Three rows below say so out loud (`M-3`, `L-1`, `L-6` were each completed by a later
  round), which is exactly the signal a fresh document would have buried.
- **Status is the load-bearing column.** `Fixed` — a test fails without the fix. `Enforced` — no
  defect, but a property was resting on unenforced reasoning and now is not. `Accepted` — a
  deliberate, documented residual. `Open` — not fixed; there should be very few, named plainly.
- **Every `Fixed` and `Enforced` row names its test**, and `script/check-citations.sh` fails the
  build if that test stops existing. That is what stops this file rotting the way the reports did.

## Scope note

Statuses were migrated from the round documents and re-verified against the **current** tree, not
against what those documents claimed on their dates — the distinction that motivated the whole
change. Where a later round completed an earlier fix, the earlier row names the completing round.

| ID | Date | Sev | Finding | Status | Lives in | Kept fixed by |
|---|---|---|---|---|---|---|
| **V6-M-1** | 2026-07-20 | Medium | Anchor ratchet promotes sparsely-sampled windows → one-directional over-leverage (latent; durable on-chain data) | Fixed | anchor density gate | V9AnchorDensity.t.sol |
| **V6-M-2** | 2026-07-20 | Medium | USDC deposits never reach the strategy; dir-only leveraged deposits run silently unlevered (C7 remnant, still live) | Fixed | USDC reclassify into strategy | V6B_DepositRouting.t.sol |
| **V6-M-3** | 2026-07-20 | Medium | A same-sign residual perp below the $10 venue minimum is never closed; planner never converges | Fixed | close-on-zero-target in `_planPerpStep` | V6D_VenueGaps.t.sol |
| **V6-M-4** | 2026-07-20 | Medium | Spot orders emitted below the $10 venue minimum after lot flooring → rejection wedge (H3); MockCore hides the class | Fixed | $10 venue minimum after lot flooring | V6D_VenueGaps.t.sol |
| **V6-M-5** | 2026-07-20 | Medium | The team's High-rated F2 fix is tested only against an in-test mirror; its "fail-before" claim is false | Fixed | tested against the real engine, not a mirror | AuditV5Fixes.t.sol |
| **V6-M-6** | 2026-07-20 | Medium | Halving root-of-trust rests entirely on the Citrea light client + LZ DVN config + delegate renouncement (config-gated) | Accepted | halving root of trust = Citrea + LZ DVN (funded gate) | — |
| **C5** | 2026-07-21 | High | Structural leverage was half-built: the flat-φ reserve stayed, so the confirmed-extreme stop was never actually placed | Fixed | `B4VaultEngine.sol:783` → shipped as margin control | StructuralSizing.t.sol |
| **C9** | 2026-07-21 | High | The short side had no confirmed-peak anchor at all — a fall-zone short sized off a product-flat substitute | Fixed | `B4VaultOps.sol:89` → sized off confirmed peaks | StructuralLeverageShort.t.sol |
| **C10** | 2026-07-21 | Medium | Backtest anchors are unreproducible at decision time (model bound) | Accepted | `B4Pool.sol:235` | BacktestReal.t.sol |
| **C7** | 2026-07-21 | Medium | Deposit routing left the settlement leg out of the strategy, so a settlement-token deposit was inert | Fixed | `B4Vault.sol:130` → routed into the strategy leg | V6B_DepositRouting.t.sol |
| **V8-M-1** | 2026-07-24 | Medium | Under-sampled anchors produce LIVE over-leverage (sparse peak confirmed; V6-M-1 now load-bearing) | Fixed | under-sampled anchors withheld | V9AnchorDensity.t.sol |
| **V8-M-2** | 2026-07-24 | Medium | Peak wick-poisoning: unrepairable in-window; next-cycle over-leverage or a full-cycle short outage | Fixed | peak wick-poisoning (completed by F2) | V8C_PeakWick.t.sol |
| **V8-M-3** | 2026-07-24 | Medium | User-facing benchmark and shipped-status claims are stale in BOTH directions; the test pins cannot catch the drift | Fixed | benchmark/status claims regenerated | BacktestReal.t.sol |
| **V8-M-4** | 2026-07-24 | Medium | Carried from V6: spot orders still emitted below the $10 venue minimum after lot flooring | Fixed | spot orders above the $10 minimum | V6D_VenueGaps.t.sol |
| **C-1** | 2026-07-25 | Critical | Just-in-time checkpoint weight: post-lock deposits mint unbounded pool weight, and pool-side weight survives a full exit | Fixed | `B4VaultOps.opsSettle` live-price basis | AuditC1_JitWeight.t.sol |
| **C-2** | 2026-07-25 | Critical | `_verifySpotOrder` completes on the externally-toppable destination balance | Fixed | `_verifySpotOrder` input-debit proof | AsyncReturnReceipt.t.sol |
| **H-1** | 2026-07-25 | High | `capturePenalty()` escrows the pool's entire unattributed balance, not the exit's receipt | Fixed | `capturePenalty` measured receipt | AuditH1_PenaltyReceipt.t.sol |
| **H-2** | 2026-07-25 | High | A zero spot-price read re-sizes a HELD structural perp by the flat-φ rule | Fixed | dead spot feed ⇒ hold in `_planPerpStep` | AuditH3_ZeroPrice.t.sol |
| **H-3** | 2026-07-25 | High | The two ledger-WRITING consumers of `_livePxWad()` have no zero-price guard | Fixed | zero-price guards on both ledger writers | AuditH3_ZeroPrice.t.sol |
| **H-4** | 2026-07-25 | High | The L-halving branch feeds the post-halving running low into the delta-anchor slot | Fixed | L-halving anchors on promoted `floor` | AuditH4M3_Anchors.t.sol |
| **M-1** | 2026-07-25 | Medium | `_verifyReturn`'s post-timeout re-clamp can make the completion predicate unsatisfiable forever | Fixed | `Return` zero re-clamp clears, plus A2's `_reconcileSpot` | AuditA_ClosureFixes.t.sol |
| **M-2** | 2026-07-25 | Medium | `usdcMarginEvm` has no reclassify-back path | Fixed | `usdcMarginEvm` reclassify-back | V6B_DepositRouting.t.sol |
| **M-3** | 2026-07-25 | Medium | Incomplete V8-M-2: the anchor density gate counts samples but does not gate the value ratchet | Fixed | daily-close + corroborated peak value (completed by F2/A8) | AuditH4M3_Anchors.t.sol |
| **L-1** | 2026-07-25 | Low | Pool-owned sleeves can never execute the vault's recovery entrypoints | Fixed | pool relays every sleeve escape (extended by A9) | AuditL1_SleeveEscapes.t.sol |
| **L-2** | 2026-07-25 | Low | The shipped Keeper never calls `sampleAnchor` | Fixed | `Keeper` samples anchors | GasBounds.t.sol |
| **L-3** | 2026-07-25 | Low | `_perpTargetMargin` divides by a live `g` while using a frozen stop, with no `g != 0` guard on that branch | Fixed | `g != 0` guard on the frozen-stop branch | StructuralSizing.t.sol |
| **L-4** | 2026-07-25 | Low | The first-credit activation allowance is re-derived at the live price on every poll | Fixed | activation allowance pinned at creation | V9Engine.t.sol |
| **L-5** | 2026-07-25 | Low | `slippageBps` is validated only from above; a vault created at 0 is permanently unable to rotate | Fixed | `MIN_SLIPPAGE_BPS` floor | VaultConfig.t.sol |
| **L-6** | 2026-07-25 | Low | The V8-L-1 zero-mark guard reports false progress | Fixed | `_startPerpOrder` reports real progress (completed by A3) | AuditA_ClosureFixes.t.sol |
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
| **A12** | 2026-07-30 | — | Exit-waterfall safety rested on hand proofs, unenforced | Enforced | `_payBucket` | Exit.t.sol |
| **A13** | 2026-07-30 | — | F1's partial-scaling case had no deterministic test | Enforced | `B4Pool.scaleWeight` | StrictPool.invariant.t.sol |
| **A14** | 2026-07-30 | — | Keeper gas budgets cited a test that never existed; three figures stale, one false | Fixed | `Keeper` budgets | GasBounds.t.sol |
| **A15** | 2026-07-31 | Low | Deleting the report archive fixed every link TARGET and left every link LABEL naming a document that no longer exists | Fixed | live docs + `check-citations.sh` | — |
| **A16** | 2026-07-31 | — | Unordered LayerZero delivery is the only thing stopping a permissionless liveness attack on the sole external fact, justified by one comment word | Enforced | `HalvingOracle.nextNonce` | HalvingOracle.t.sol |
| **A17** | 2026-07-31 | — | Two `test_*` functions carried no assertion: one a diagnostic whose question had been answered, one a printf that could stop reporting silently | Enforced | test suite | BacktestReal.t.sol |
| **A18** | 2026-07-31 | Low | The registry migration wrote 22 links as repo-root paths, so every `docs/` page's registry link resolved to `docs/docs/…` and was dead; the checker asked only whether that basename existed *somewhere* | Fixed | `docs/`, `check-citations.sh` check 6 | — |
| **A19** | 2026-07-31 | Low | SPEC §5 defined rotated capital as "settlement from Close sales", omitting direct settlement deposits — a reader implementing from spec routes a USDC deposit into the margin reserve, where it is inert and notional sizes off zero | Fixed | `SPECIFICATION.md` §5 | V6B_2a |
| **A20** | 2026-07-31 | — | An orphaned proposal described all four of its shipped steps as pending/uncommitted and named green tests as failing, against a "269/269" tree that is now 488 | Fixed | deleted | — |
| **A21** | 2026-07-31 | Low | Four rows of this registry put a source location in the `Finding` column and the finding text under `Lives in` — a reader scanning what the bug *was* saw `B4VaultEngine.sol:783` | Fixed | rows C5/C7/C9/C10 | — |
| **A22** | 2026-07-31 | — | The approved standing-pool-short design (SPS-1) is not implementable on the shipped engine: the structural stop is frozen while a position is live, so folded increments inherit the first stop instead of sizing at their own price — the exact blended-entry drift the design assumed away | Recorded | `docs/07-fee-routing.md` known-limitation section | — |
| **A23** | 2026-07-31 | Medium | Published drawdown for Pro Max was measured on `navWad`, which excludes unrealized perp PnL (B3) — and pure-perp Pro Max holds `spot = 0`, so NAV was blind to its entire position and reported 0.00 %; the real figure is 75.40 % and the product draws DEEPER than B4/Pro, not shallower | Fixed | `_equityWad` mark-to-market in the benchmark; README + docs/11 tables | BacktestReal.t.sol |
