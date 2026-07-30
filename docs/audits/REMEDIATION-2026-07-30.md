# Remediation — 2026-07-30 (pre-mainnet closure pass: F3 + A1–A6)

Closes the one **unapplied** finding from AUDIT-2026-07-29 (F3 — a verified patch that had been
written but never landed), plus the residuals still marked open/partial after that round and one
newly-found weight-integrity vector, its mirror image, and the last unhandled freeze in the system.
Every fix ships with a fail-before/pass-after regression (H1):
F3 in [`test/unit/DeferredClaimReturnRace.t.sol`](../../test/unit/DeferredClaimReturnRace.t.sol),
A1–A4 in [`test/unit/AuditA_ClosureFixes.t.sol`](../../test/unit/AuditA_ClosureFixes.t.sol), A5
in [`test/unit/AuditF4_SettleValuationInstant.t.sol`](../../test/unit/AuditF4_SettleValuationInstant.t.sol)
beside the F4 change whose residual it is, and A6 in
[`test/unit/AuditA6_StuckReturnEscape.t.sol`](../../test/unit/AuditA6_StuckReturnEscape.t.sol).

Two of these were found by *verifying the previous fix rather than trusting it* — A5 while checking
A1's reach, A6 while checking what the README's liveness claim actually rested on. Both were created
or masked by a correct-looking change: a fix that alters WHEN a quantity is measured, or a doc line
asserting a property nothing tested, is where the next finding tends to live.

**Verification of this pass**

- `forge test`: **482 passed, 0 failed** across 81 suites. `slither --fail-high` clean (168 informational, no high).
- Each was confirmed to **fail on the pre-fix tree** with the exact predicted failure mode, then
  pass after the fix (see the per-item "fail-before" note).
- `forge build --sizes` on pinned solc 0.8.28: all contracts inside EIP-170. Tightest after this
  pass: `B4Vault` 24,395 B (**181 B** headroom — improved from 141 B by moving `emergencyClearRecovery` into the recovery module), `B4VaultOps` 24,228 B (348 B). `forge fmt --check`
  clean; storage-layout guard passes (33 slots).

> **Headroom is the binding constraint on this codebase.** It reached 141 B mid-pass — 13 bytes
> over the project's own 128 B floor (`V3Venue_SizeGate`) — which is why A5 went into `B4VaultOps`
> and A6 into `B4VaultRecovery`. A6 then bought some back by moving `emergencyClearRecovery`'s body
> out of `B4Vault`, ending at **181 B**. The pattern to keep: cold-path owner functions belong in a
> module, and `B4Vault` should hold dispatchers, not bodies.

## F3 (High) — permissionless `claimDeferred` wedged an in-flight Core→EVM return

**This was a live, unpatched wedge — closed here.** `_unaccountedEvm` (the receipt proof for every
Core→EVM leg) excluded `deferredPayoutTotal` from `booked` on the false premise that it "changes
only inside settle / exit-finalize". `B4VaultRecovery.opsClaimDeferred` — permissionless, no idle
gate — also decrements it, so a claim mid-leg lowered the EVM balance without lowering the measure:
`received` fell permanently short of `evmNeeded`, the Core source had already decreased so A7 kept
the resend branch shut, and the intent could neither complete nor resend — freezing every
idle-gated entrypoint with no admin to unstick it. **An honest `Keeper.crank` triggers it** (it
reaches `crankVault` then `retryDeferred` in one transaction), so it needed no attacker.

**Fix** (`B4VaultEngine._unaccountedEvm`): add `deferredPayoutTotal[token]` to `booked`, so a claim
lowers `bal` and the subtrahend by the same amount and cancels exactly. `opsRecoverEvm` already
subtracted it on its own path — no double-count. The AUDIT-2026-07-29 scan wrote and panel-verified
this exact patch (`CLAUDE-SECURITY-20260729-140307/patches/F3.patch`); it had never been applied.
Full detail: [`AUDIT-2026-07-29.md`](AUDIT-2026-07-29.md) §F3.

**Fail-before:** both tests in `DeferredClaimReturnRace.t.sol` leave the return leg wedged
(`ReturnUsdc` never clears) on the pre-fix tree.

---

## A1 — deposit inside the settlement window no longer corrupts the entry basis (weight integrity)

**Severity: Medium. Newly found this pass. INVARIANTS #19.**

`opsSettle` re-anchors `entryLedgerWad = nav − paidVal` from the **frozen** `settleNavWad`
(captured by `snapshotNav` at `pointTime`). A `deposit` is reachable in the report window and is
not gated on a pending snapshot, so the ordering `snapshotNav → deposit(D) → settle` overwrote the
correct post-deposit basis `E+D` with the pre-deposit `nav ≈ E`, dropping `D`. The dropped
principal then reappeared as **phantom profit** at the next checkpoint — a performance fee on the
depositor's own capital and freshly-minted pool weight (the deposit-in-window residual of the
C-1 / F4 class).

**Fix** (`B4Vault.deposit`): when a snapshot for a not-yet-settled interval is frozen
(`settleNavIdPlusOne > lastSettledPlusOne`), add the deposit's `valueWad` to `settleNavWad` too, so
the frozen NAV stays consistent with the raised ledger. Safe against a deferred/never-settled
interval: `_captureNav` always recomputes NAV from the live composition, so no double-count.

**Fail-before:** `test_A1_...` asserts `entryLedgerWad == 200k` after `deposit→snapshot→deposit→settle`;
the pre-fix tree left it at `100k` and minted weight on the dropped `100k` at the next checkpoint.

## A5 — exit inside the settlement window no longer mints on withdrawn capital

**Severity: Medium. Found while verifying A1. INVARIANTS #19. The EXIT-side counterpart of A1 —
same root, opposite sign, and it was left open when A1 closed the deposit side.**

A frozen snapshot values the whole position, and `_finalizeExit` scales `entryLedgerWad` and
`rewardBaseWad` by `keep` **without touching `settleNavWad`**. So `snapshotNav → initiateExit(x) →
crank → settle` had settle measure a NAV that still included the withdrawn share against an entry
that no longer did: the exited notional read as profit. Both halves of the window are reachable —
`opsSettle` only refuses an exit still *pending* (`exitShareWad != 0`), not one already finalized —
and the settlement point sits inside a `freeExit` transition zone, so the exit is penalty-free
as well.

Measured on the pre-fix tree, a 50% exit at a 130k NAV over a 100k entry: settle took **80k** of
profit where **15k** was real — 5.3× — minting pool weight against a shared basket on capital the
vault no longer held. Where A1 *dropped* principal (understating the basis), this *retained* it
(overstating the profit); A1's severity reasoning applies unchanged.

**Fix** (`B4VaultOps._finalizeExit`): under the same `settleNavIdPlusOne > lastSettledPlusOne`
condition A1 uses, scale the frozen NAV by the same `keep` both ledgers already use. In
`B4VaultOps`, not `B4Vault`, for the same headroom reason as A2.

**Fail-before:** `test_F4_exit_between_snapshot_and_settle_does_not_mint_on_withdrawn_capital`
pins `settleNavWad == wmul(pinned, keep)` and the settled profit at half the pre-exit profit; the
pre-fix tree measured 80k against the honest 15k.

## A6 — the permanent Core→EVM wedge now has a bounded escape (HAZARDS A7 residual)

**Severity: High (architectural, liveness-of-custody). Named by both the internal scan and the
external review; the last unhandled freeze in the system.**

A `ReturnDir`/`ReturnUsdc` whose Core source has decreased can never resend — A7 forbids it,
because the first send may still be in flight and a resend would send twice. If the EVM credit is
then permanently lost, `received < evmNeeded` holds forever, so the leg can never complete either.
`emergencyClearRecovery` refused the kind (A6 admitted `Recover*` only), and every idle-gated
entrypoint — settle, exit finalize, all three recovery paths — died on `_requireIdle()`. **The
whole vault was frozen for good**, with no admin anywhere able to unstick it, and the surviving
capital went down with the lost portion.

The false assurance that hid this is in `HAZARDS` A6 itself: *"with A2/A3 in place, transfer
intents always progress after the timeout and never need discarding."* It is not true for this
shape. The rule is corrected there: not "never discard", but **never discard funds that still
exist**.

**Fix** (`B4VaultRecovery.opsAbandonStuckReturn`, owner entry `B4Vault.abandonStuckReturn`):
after `RETURN_ABANDON_TIMEOUT` (30 days) and **only when the source has actually decreased**,
write the Core books down to the real balance (`LossReconciled`) and clear the intent. It changes
only the *second* loss — the first has already happened and no contract can undo it. A credit
arriving later lands as unaccounted EVM balance and reaches the owner through `recoverEvm`, the
same path any unattributed arrival takes, so nothing is destroyed that was not already gone.

Three gates, each load-bearing: **owner-only** (it realizes a loss on their own vault);
**30 days** (~720× any honest delay, so an impatient caller cannot abandon a merely slow leg); and
**source must have decreased** (while Core still holds the amount the resend branch is live, and
abandoning would discard a claim on funds that exist — still forbidden, and asserted).

> Headroom note: `emergencyClearRecovery`'s body moved to `B4VaultRecovery` in the same change,
> leaving only its dispatcher in `B4Vault`. The external selector is unchanged
> (`B4Pool.clearSleeveRecovery` relays it), and `B4Vault` came out **better** than before —
> 181 B of EIP-170 headroom against 141 B — while gaining the new escape.

**Fail-before:** `AuditA6_StuckReturnEscape.t.sol` ×6. `test_a_lost_credit_wedges_the_vault_permanently`
pins the wedge itself (50 cranks past `RESEND_TIMEOUT` do not clear it, and `recoverEvm` reverts
`IntentPending` behind it); the rest pin the escape and each of its three gates, plus the late
delivery still reaching the owner.

## A2 — spot principal written down to the real Core balance (audit M-1, second clause)

**Severity: Medium; the freeze half of M-1. Coupled to a §5 funded gate.**

`_reconcile` covered only perp margin. If a booked spot bucket ever exceeds the real Core spot
balance — a cross-margin liquidation reaching spot USDC, or a partial `spotSend` — the Return leg
for the phantom remainder proves `decreased` but never reaches `received ≥ evmNeeded`, and the
zero-reclamp path clears the *intent* without writing down the *bucket*, so the planner retries it
forever: **permanent exit livelock + overstated NAV**.

**Fix** (`B4VaultOps._reconcileSpot`, called at the head of the return sequence in `_planExitStep`):
the spot analogue of `_reconcile`. Clamps `coreDirWei` and the shared `coreUsdcRotatedWei +
coreUsdcMarginWei` down to the real balances (shortfall absorbed from rotation first, then margin),
emitting `LossReconciled`. A no-op on the happy path (books ≤ balance). The USDC sum is computed in
`uint256` so it can never revert-on-overflow on the exit crank.

> Placed in `B4VaultOps` (not the engine) so it does not consume `B4Vault`'s 174-byte headroom.
> Whether the trigger can occur at all — the venue reducing our spot below books — remains **§5
> funded gate B-3** (cross-margin spot drawdown / `spotSend` insufficient-balance semantics). This
> fix makes the exit **self-heal** if it does, rather than livelock.

**Fail-before:** `test_A2_...` drives a Pro exit, pulls margin to Core spot USDC, drops the real
balance below books (`coreDrawdown`), and asserts the exit finalizes. Pre-fix: `exitShareWad`
stuck at `1e18` (livelock).

## A3 — no false progress on a dead perp mark feed (A13 / audit L-6 / V8-L-1)

**Severity: Low (liveness only).**

`_startPerpOrder` was `void` and emitted nothing when the mark feed was down, yet the two flatten
sites (`_planSyncStep`, `_planExitStep`) returned `true` unconditionally — so a keeper's bounded
loop spun on a step that changed nothing.

**Fix:** `_startPerpOrder` now returns `bool emitted` (false on dead mark / zero size). The two
flatten sites propagate it, so a dead-mark flatten reports no progress and correctly does **not**
fall through to sizing while a wrong-sign perp is still open. The two sizing sites already ran
behind a `markWad != 0` guard and now return the value for symmetry.

**Fail-before:** `test_A3_...` sets `markPx = 0` with a wrong-sign perp open; `crank()` must return
`false`. Pre-fix it returned `true`.

## A4 — `selectPolicy` requires an idle engine and cannot re-enter

**Severity: Low.**

`opsSelectPolicy` read `IStrategy(strategy).targets()` on the caller-supplied address before any
validation, with no idle gate and no reentrancy guard on the entry, and mutated
`growthTarget`/`fallTarget` while a leg could be in flight.

**Fix:** `_requireIdle()` at the top of `opsSelectPolicy` (a live leg was planned against the old
target), and `nonReentrant` on `B4Vault.selectPolicy` so the pre-validation external call cannot
re-enter `deposit`/`crank`.

**Fail-before:** `test_A4_...` opens an in-flight intent (auto-exec off) and asserts
`selectPolicy` reverts `IntentPending`. Pre-fix it did not revert.

---

## Items confirmed already-closed in code (audit archive lagged the source)

- **V6-M-4 / V8-M-4 (spot order below the $10 venue minimum).** Already guarded:
  `B4VaultEngine._startSpotOrder` re-checks the emitted order's own notional against
  `MIN_ORDER_USD_WAD` after lot flooring and holds. No change needed.
- **Weight-ledger campaign read.** `invariant_weight_ledger_is_closed` already asserts
  `totalWeight == Σ weightOf`. A1's regression additionally pins the "weight only from real P&L"
  property for the deposit-in-window vector.

## Remaining (not shipped-contract defects — test-coverage / on-venue)

- **A7:** a stateful campaign that also reads `entryLedgerWad`/`rewardBaseWad` and drives a
  deposit-in-window handler (the A1 vector is covered deterministically here; the campaign
  generalization is an external-audit-phase item).
- **§5 funded gates** remain the gating precondition for real funds, unchanged — B-3 (spot
  drawdown / `spotSend` semantics, which decides whether A2's trigger can occur), EIP-1153 live,
  delegate renounce, `CoreTypes.Position` field order, reduce-only-to-raw-zero, and the rest.
