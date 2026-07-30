# Remediation — 2026-07-30 (pre-mainnet closure pass: F3 + A1–A4)

Closes the one **unapplied** finding from AUDIT-2026-07-29 (F3 — a verified patch that had been
written but never landed), plus the residuals still marked open/partial after that round and one
newly-found weight-integrity vector. Every fix ships with a fail-before/pass-after regression (H1):
F3 in [`test/unit/DeferredClaimReturnRace.t.sol`](../../test/unit/DeferredClaimReturnRace.t.sol),
A1–A4 in [`test/unit/AuditA_ClosureFixes.t.sol`](../../test/unit/AuditA_ClosureFixes.t.sol).

**Verification of this pass**

- `forge test` (excl. the historical backtest): **462 passed, 0 failed** — the prior 456 plus the
  6 regressions below (F3 adds 2).
- Each was confirmed to **fail on the pre-fix tree** with the exact predicted failure mode, then
  pass after the fix (see the per-item "fail-before" note).
- `forge build --sizes` on pinned solc 0.8.28: all contracts inside EIP-170. Tightest after this
  pass: `B4Vault` 24,435 B (**141 B** headroom), `B4VaultOps` 24,200 B (376 B). `forge fmt --check`
  clean; storage-layout guard passes (33 slots).

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
