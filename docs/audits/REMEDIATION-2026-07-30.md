# Remediation — 2026-07-30 (pre-mainnet closure pass: F3 + A1–A10)

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

- `forge test`: **484 passed, 0 failed** across 82 suites. `slither --fail-high` clean (168 informational, no high).
- **Deep invariant campaign run** (`FOUNDRY_PROFILE=deep`, 512×256): 32 tests, 0 failed, 283 s. This is the project's strongest gate and it had not been run against any of this pass's changes until now.
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

## A7 — settle can never value the vault above its own books (frozen-NAV class, closed)

**Severity: Medium. Found by re-checking A5's reach rather than trusting it. INVARIANTS #19.**

A1 and A5 each patched one mover of the frozen snapshot — deposit raises it, exit scales it. A
**realized loss** lowers the books with nothing tracking it at all, and it is reachable inside the
report window: the target ramps away from zero immediately after the settlement point, so the
crank re-opens a position and funds perp margin, and an adverse close there is written down by
`_reconcile` while the snapshot still values the vault as it stood before. Measured on the pre-cap
tree: live NAV **117,000** against a frozen **120,000**, so settle re-anchored the entry ledger to
120k and would charge a fee and mint pool weight on 3k the venue had already taken.

**Fix** (`B4VaultOps.opsSettle`): value the interval at `min(settleNavWad, _navWad(pxWad))` — the
books as they stand now, at the **frozen** price. Two properties make this the right shape rather
than a third hook:

- it closes the *class*, not the instance. No future mover can raise the settled NAV above the
  recorded books, whether or not anyone remembers to hook it — which matters because A5 and this
  were both found by checking the previous fix, not by the scan;
- it does not reopen F4. Re-valuing at the LIVE price would hand the settle caller the price
  again; valuing the books at `pxWad` keeps the instant the snapshot pinned.

Only the downward direction is covered by construction — a cap cannot invent value the snapshot
never recorded — so A1's upward hook is still required and remains.

Rejected: hooking `_reconcile`/`_reconcileSpot` individually. It cost `B4Vault` 73 bytes (the
helper lives in the shared engine and is paid by all three contracts), taking it to **108 B** —
under the project's own 128 B floor — to close one mover instead of the class.

**Fail-before:** `test_F4_settle_never_values_above_the_books_after_a_realized_loss` asserts the
settled entry ledger is at or below the post-loss NAV; pre-cap it read the frozen 120k.

## A9 — the A6 escape reaches pool-owned sleeves too (the L-1 gap, repeated)

**Severity: High (architectural, liveness-of-custody) for sleeves. Created by A6 being incomplete,
found by sweeping A6 against the class this repository has already been bitten by once.**

A6 gave the vault an owner-only escape from an unrecoverable Core→EVM return. A sleeve's owner **is
the pool**, so an escape that lives only on the vault's `onlyOwner` surface does not exist for a
sleeve at all unless the pool relays it. That is exactly audit **L-1**, whose own note reads: *"without
these entries in the interface the escapes that INVARIANTS row 20 and HAZARDS B6 promise simply do
not exist for a sleeve."* A6 reproduced it.

`B4Pool.clearSleeveRecovery` already relays the A6 *surplus* escape, and its docstring states why
such a relay is mandatory rather than optional: a pending intent blocks the whole crank, so a leg
the venue never completes *"would freeze the sleeve's exit machine and permanently strand its
principal — turning an accounting leak into the permanent freeze that the worst-case rule forbids."*
By that same reasoning the missing relay left every sleeve permanently wedgeable — and this is the
worse half of the finding, because a sleeve holds **pooled** penalty capital: a frozen one strands
it for every participant, not for one owner.

**Fix** (`B4Pool.abandonSleeveStuckReturn`, plus the `IB4PoolSleeve` entry): relay it on the same
terms as the other four forwarders — fixed arguments, no caller discretion. It grants the pool
nothing the vault does not already gate: the sleeve still refuses every kind but
`ReturnDir`/`ReturnUsdc`, still enforces the 30-day timeout, and still refuses unless the Core
source has actually decreased.

**Fail-before is compile-level and worth stating plainly:** without the forwarder the call does not
exist, so the regression is that `abandonSleeveStuckReturn(1, DIR)` on a live sleeve reaches the
sleeve's own `NotRecoveryIntent` — reaching *that* revert is what proves the relay is wired into
vault logic rather than unreachable — alongside `NotASleeve` for a policy with no sleeve and for a
bad directional index (`AuditL1_SleeveEscapes.t.sol::test_L1_sleeve_escape_forwarders_admit_no_caller_discretion`).

> A note on how this was found, because it generalises: A6 was verified on the vault and shipped.
> The sleeve is the *same code* reached through a different owner, and this repository had already
> filed L-1 for precisely that blind spot. Any escape added to `B4Vault`'s `onlyOwner` surface needs
> a matching `B4Pool` forwarder in the same change, or it silently does not exist for half the
> deployment.

## A10 — the policy-id / mask-bit divergence is documented (silent-wrong-answer trap)

**Severity: Low (API ergonomics / false assurance). No code defect — every internal site is
correct. Found by making the mistake: a diagnostic of mine read a Pro escrow as zero and I chased
a phantom accounting bug before noticing the numbering.**

`policyMask` documents `1=Mini, 2=B4, 4=Pro, 8=Pro Max` — those are **mask bits**. Every public
entrypoint and mapping keyed by `policy` (`sleeveOf`, `penaltyEscrow`, `strategyOf`, `foldPenalty`,
`crankSleeve`, and all five sleeve escapes) takes the **policy id**, where a policy id `p` occupies
bit `1 << (p − 1)`. They agree for Mini and B4 and **diverge for Pro (id 3, bit 4) and Pro Max
(id 4, bit 8)**, and nothing said so.

Why it matters more than a naming nit: `penaltyEscrow(4, dir, 0)` for Pro does not revert — it
reads Pro Max's escrow and returns a **silent zero**, so a monitor concludes there is nothing to
fold. In an aggregate pool (mask 15) the sleeve forwarders would act on the wrong product's sleeve
rather than failing. In an isolated pool they revert `NotASleeve`, which is exactly why the mistake
survives testing and surfaces in production.

**Fix:** documented at both surfaces an integrator actually reads — the `policyMask` docstring in
`B4Pool` (the only place the numbers appeared) and the sleeve section of `docs/03-contracts.md`,
each with the id↔bit table and the silent-zero consequence spelled out. The numbering itself is
left alone: renumbering buys no safety and breaks every caller.

**Verified, not assumed:** the accounting is correct. A Pro exit's penalty escrows
234,887,637 USDC + 23,371,910 directional to the Pro sleeve under policy id 3 — D6/D7 hold.

## A8 — `anchorConfirmed` no longer reports a confirmed peak that serves nothing

**Severity: Low (operational / false assurance). A state this pass itself created.**

Splitting density counting from value binding (F2) made "confirmed" and "has a value" two different
things, and nothing said so. Density counts observations; the peak VALUE binds only at a daily
close and only once two distinct closes reach it. A keeper sampling daily but always **mid-day**
therefore satisfies the density gate and never binds a close — the window ends `_confirmed` with
`peakC == 0`.

For the engine that is fail-safe: a zero peak reads as "absent", so a leveraged short falls back to
the flat base exactly as an under-sampled window does, and the promotion into `prevPeak` carries
the zero rather than a stale higher value — a LOWER `Pp` widens `(C − Pp)`, pushes the stop further
out, and lowers leverage. Nothing is mis-sized.

What was wrong is what an **operator** was told. `anchorConfirmed` returned `peakConfirmed = true`
on the count alone, so a sampler dashboard would show a healthy anchor while the product ran
unanchored for the rest of the cycle — and the cycle is where the whole mechanism lives, so the
mistake is discovered a year late or not at all.

**Fix** (`B4Pool.anchorConfirmed`): the peak leg reports `_confirmed(density) && peakC != 0`, so
"confirmed" means the same thing on both legs — that a value is actually being served. Engine
behaviour is unchanged; the getter has no on-chain consumer.

**Fail-before:** `AuditF2_ConfirmedWithoutValue.t.sol` builds the mid-day-sampled window, asserts
nothing is served and that the flag says so, then samples the same window at its closes and asserts
both flip together.

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
