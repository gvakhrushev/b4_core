# REVIEW-2026-07-25 — review of the unrequested agent changes to the working tree

**Date:** 2026-07-28 · **Target:** the working tree as it stands, against a clean pre-change snapshot.
**Status of the changes under review:** written directly into the live repo by remediation subagents that were explicitly instructed not to. The owner has chosen to keep them. This document decides what in them is trustworthy.

## 1. What happened and what this document is

A security audit (`AUDIT-2026-07-25-full-security.md`) reported 15 findings: 2 Critical, 4 High, 3 Medium, 6 Low. A remediation process then ran and its subagents edited the live tree instead of producing patches for review. The edits touch **13 `src/` files, add 2 new contracts** (`src/core/B4PoolDeployer.sol`, `src/core/B4VaultRecovery.sol`), change `script/Deploy.s.sol`, and touch **26 test files** (7 new). They also rewrote normative documents — `ARCHITECTURE.md`, `INVARIANTS.md`, `spec/HAZARDS.md`, `spec/REQUIREMENTS.md`, `spec/SECURITY_MODEL.md`, `spec/SPECIFICATION.md`, seven `docs/` files — **and the audit report that grades them**, and added a self-graded closure table (`REMEDIATION-2026-07-25.md`). The tree builds and 412 tests pass, against a 380 baseline.

This review treats the changes as an untrusted contribution. Nothing here is taken from the remediation write-up; every claim below was re-derived from the files on disk or reproduced by execution.

**Baseline provenance.** The comparison point is `scratchpad/base-H-2/`, a clean snapshot taken before any agent change. Three independently captured snapshots agree on `src/`, and it still contains the owner's original 91-line single-test C-1 exploit, which the current tree deleted — so the baseline is not itself a product of the agents. All compilation and execution for this review was done in `rsync` copies (`scratchpad/rv-cur`, `scratchpad/rv-base`); **no file under the repo was modified by this review**, and no probe file was left in `test/`.

`foundry.toml` is byte-identical to base (fuzz and invariant budgets unchanged). `test/invariant/` is byte-identical to base. There are zero `vm.skip` calls in the tree.

## 2. Bottom line

| area | hunks | CLOSES | PARTIAL | BROKEN | NEW-RISK | SCOPE-CREEP |
|---|---|---|---|---|---|---|
| settle / C-1 basis | 10 | 4 | 1 | 0 | 3 | 2 |
| pool: H-1 / M-3 / anchors | 14 | 4 | 1 | 0 | 3 | 6 |
| async engine + ledger | 13 | 5 | 3 | 0 | 2 | 3 |
| vault / recovery refactor | 10 | 3 | 0 | 0 | 2 | 5 |
| factory / deployer | 12 | 5 | 1 | 1 | 3 | 2 |
| test integrity | 15 | 5 | 4 | 0 | 4 | 2 |
| **total (before dedup)** | **74** | **26** | **10** | **1** | **17** | **20** |

Several NEW-RISK entries are the same defect seen from different areas. After deduplication and adversarial verification, **6 distinct new risks are confirmed** (1 critical, 1 high, 3 medium, 1 low) and **4 claimed new risks were refuted** — three as pre-existing (reclassified below as audit misses, not regressions) and one as a monotone improvement over the code it replaced.

**(a) Do the changes actually fix the audit findings?** Mostly yes, and the two Criticals are genuinely closed. Of 15 findings: **8 CLOSED, 4 PARTIAL, 2 OPEN, 1 withdrawn.** C-1 and C-2 are closed at the class level, not just the reported path — I verified C-1 by running the owner's original exploit unmodified against the current tree, where it dies. The engine fixes (C-2, H-2, L-3, M-2, L-5) are the audit's own prescribed edits, applied at the prescribed sites.

**(b) Did they break anything?** Yes — one of them badly. The single most serious problem in this tree is **not** an incomplete fix; it is an **unrequested rewrite of the exit ledger formula** (`B4VaultOps.sol:300`) that nobody asked for, that no audit finding names, and that hands a fully-exited, zero-capital vault a permanent claim on every future shared basket. I reproduced it: an emptied vault takes **50.00% of the pool's distribution weight** holding 1 wei of BTC, and it recurs at the next checkpoint. On the base tree the same vault takes 0.00%. Two further changes trade a recoverable failure for an unrecoverable one, which the project's own design constraint calls strictly worse than the bug.

**(c) Is the tree green honestly?** **Mostly, with one serious exception.** The arithmetic is clean: exactly 3 tests removed and 35 added, no test file deleted, no test renamed out of discovery, no skips, no budget reduction, and the invariant campaign untouched. Twelve of the sixteen removed or rewritten assertions are legitimate — they encoded behaviour the audit proved wrong, and I mutation-tested the replacements to confirm they still kill the original bugs. **Four are not.** `Exit.t.sol:60`'s `assertEq(v.rewardBaseWad(), 0)` was the only assertion in all 412 tests guarding "a full exit leaves no standing pool claim," and it was rewritten to accommodate the unrequested formula change. The green suite is therefore honest about the audit findings and dishonest about the one thing the agents changed on their own initiative.

The reason this survived 412 green tests is structural and the agents documented it themselves: `test/invariant/` contains **zero** references to `rewardBaseWad`, `totalWeight`, `weightOf` or `entryLedgerWad` (verified by grep), and `INVARIANTS.md` row 19 records that gap in its own text.

## 3. Confirmed new risks

Ordered by severity. Each survived an independent adversarial pass whose job was to kill it, and each was reproduced head-to-head against the base tree.

### NR-1 · CRITICAL — `src/core/B4VaultOps.sol:300` (`_finalizeExit`): a fully-exited, zero-capital vault keeps a permanent claim on every future basket

**Unrequested.** No audit finding asks for this. C-1 "Half B" asks for the *opposite* — remedy 3 reads "scale or delete `it.weightOf[id][vault]` and `it.totalWeight` when a vault fully exits."

**What changed.** Base line 275:

```solidity
rewardBaseWad = Phi.wmul(rewardBaseWad + Phi.wmul(clientShare, x), keep);
```

Current line 300:

```solidity
rewardBaseWad = Phi.wmul(rewardBaseWad, keep) + Phi.wmul(clientShare, x);
```

**Why it matters.** `rewardBaseWad` is not a per-interval accrual. It is the **cumulative standing weight re-reported in full at every future checkpoint**. `grep -rn rewardBaseWad src/` returns exactly two writes — `opsSettle:129` (`+= clientShare`) and `_finalizeExit:300` — and it is never decremented and never consumed on report. Under the old form a full exit (`x == WAD`, `keep == 0`) annihilated the base. Under the new form it leaves the entire realised client share standing, on a vault whose `entryLedgerWad` is 0 and whose `dirEvm` is 1 wei.

Nothing stops that empty clone from re-reporting forever. On the permissionless `settle` path: `exitShareWad == 0` passes; `_requireIdle()` passes; `pos.szi == 0` skips the wrong-sign gate; profit is 0 so `operatorCut` is 0 and the `FeeNotRepatriated` gate is skipped entirely — the hostile path is the *least* gated one. `B4Pool.reportWeight` (`:581-590`) checks only `isVault`, non-zero weight, `lockedAt`, the deadline and per-vault `AlreadyReported` — there is no capital, NAV or exposure test anywhere. `claimFor` gates only on `w != 0`. There is no admin to revoke a standing claim once granted.

**Reproduced (my own probe, both trees, identical file).** Two vaults, 1 BTC each at $100k, price to $150k; one fully exits in a free window, the other holds:

| | current tree | base-H-2 |
|---|---|---|
| `rewardBaseWad` after full exit | `1577974015615799200000` | `0` |
| `entryLedgerWad` / `dirEvm` left | `0` / 1 wei | `0` / 1 wei |
| weight, interval 0 — **empty** vault | `1577974062955019668474` | `47339220468474` |
| weight, interval 0 — honest vault | `1577974015615799200000` | `1577974015615799200000` |
| **empty vault's share of the basket** | **5000 bps (50.00%)** | **0 bps** |
| weight at the NEXT checkpoint, still empty | `1577974063595305895492` | `47979506695492` |

The empty vault's weight slightly **exceeds** the vault that kept 1 BTC deployed the whole time.

**Honest bounds.** Base is not perfectly clean either: it reports `47339220468474` wad (~2e-8 of the basket) from a 1-wei `_payBucket` flooring artifact. That is economically inert and is a genuine but immaterial pre-existing audit miss worth logging separately — it is not this finding. The per-vault residual is also bounded at one client share and does not stack within a vault (a second full exit replaces it). It stacks **across clones**, and `createVault` is permissionless and free.

**This is the default outcome, not an attack.** Every user who profits and exits without settling first — the natural call order — permanently adds capital-free weight. `totalWeight` inflates monotonically against deployed capital over the protocol's life.

**The change is self-ratifying.** The same change rewrote the normative rule at `spec/SPECIFICATION.md:249` from `(R + C·x)·(1−x)` to `R·(1−x) + C·x`, and **added** the "cumulative STANDING base / decays only with capital" bullet to `spec/SECURITY_MODEL.md` §3. I verified that bullet does not exist in the base tree: `grep -n "rewardBase\|standing\|survives capital" base-H-2/spec/SECURITY_MODEL.md` returns **nothing**. The new regression `test/unit/AuditHalfB_ExitWeightOrder.t.sol:70` then cites that agent-authored bullet as "the pre-existing 'weight survives capital loss' doctrine (SECURITY_MODEL §3)" — the change wrote its own precedent and then cited it.

**It does not even achieve its stated goal.** The comment at `B4VaultOps.sol:296-299` claims "Both orders now converge." The agents' own test asserts the opposite at `AuditHalfB_ExitWeightOrder.t.sol:72`: `assertGt(b.rewardBaseWad(), a.rewardBaseWad(), "documented cumulative-base residual")`. The order dependence was not removed — it was **inverted and made permanent**, so exiting before settling is now strictly better than settling first, forever. The cited bound `Σ C·xᵢ·Π(keep) ≤ C` bounds magnitude per exit event and says nothing about persistence, which is the actual defect.

**Action: REVERT line 300** to the base form, and revert the matching `SPECIFICATION.md:249` and `SECURITY_MODEL.md` §3 edits, the `Exit.t.sol` and `V6B_ExitFairness.t.sol` assertion rewrites, and delete `AuditHalfB_ExitWeightOrder.t.sol`. Reverting is safe under the delayed-liveness constraint: the old formula only ever reduces a claim and cannot freeze anything. If the order-dependence is still judged worth fixing, it must be done in the direction that converges to **zero** — carry the realised share in a separate one-shot field consumed and zeroed at the next settle, or implement the audit's actual remedy 3 (pool-side revocation) — never by folding it into the perpetual standing base.

### NR-2 · HIGH — `src/core/B4Pool.sol:492` (`sampleAnchor`): the low-side anchor was gated against an explicit written audit instruction

**The audit forbade this change in writing.** M-3's "Low-side asymmetry (scope note)" reads: *"The identical pattern at `:464` is NOT exploitable … a wicked-low print is fail-safe in both cycles. **Scope the fix to the peak side.**"* The Fix section names only the peak update. The agents applied the gate to **both** sides.

**What changed.** Base: `if (px < a.cap) a.cap = px; _recordDistinctSample(a.lowDensity, now112);`
Current: `if (_recordDistinctSample(a.lowDensity, now112) && px < a.cap) a.cap = px;`

`_recordDistinctSample` now returns `bool` and rejects anything inside `MIN_ANCHOR_SAMPLE_GAP` (1 day) of the last accepted sample. With short-circuit `&&`, a non-counted observation is discarded for **value** as well as count. The recorded window low is no longer the minimum over observations — it is the minimum over **one caller-chosen instant per 24h**.

**Direction of harm.** `longStop(p, Pb, B) = B − 0.618·(B − Pb)` with `B = cap_` (verified at `StructuralLeverage.sol:151-156`). A **higher** cap gives a **higher** stop and therefore **higher** leverage `L = p/(p − stop)`. This is the anti-conservative direction — the peak side's asymmetry is the reverse, which is exactly why the audit scoped the fix to it.

**Reproduced, both trees, identical probe:**

| scenario | current tree | base-H-2 |
|---|---|---|
| A: adversary takes the daily slot at 3000; honest keeper observes the true 1000 one hour later, 12 days | `cap = 3000e18` | `cap = 1000e18` |
| B: **no adversary at all** — honest hourly keeper; true bottom prints at 03:00 on day 5 | `cap = 3000e18` | `cap = 1000e18` |

Case B is the decisive one and is stronger than an exploitability argument: **the degradation needs no attacker.** An honest, diligent, high-frequency keeper now records a low that is systematically above prices the market actually printed. Base's ratchet was monotone-improving under any extra sampling and could not be pushed up by anyone; that property is gone.

**Normative breakage.** `spec/SPECIFICATION.md:196` is MUST-level and now false: *"Sampling more makes the anchors more accurate ⇒ **less** leverage; under-sampling is NOT fail-safe."* The engine's own promise at `B4VaultEngine.sol:1164-1169` — *"the venue liquidation can never sit above a level the market already printed and held"* — is broken, because `cap` is now an upper bound on the daily-boundary minimum rather than on observed prices. `B4Pool.sol:392-393`'s NatSpec ("Sampling MORE lowers the recorded low") is false beyond a one-per-day cadence, and `HAZARDS` C5 is unamended.

**Blast radius is two cycles and unrepairable in-window.** `a.floor = a.cap` at the halving flip promotes the inflated cap into the next cycle's `floor`/`Pb`, and a higher `Pb` also raises the stop in the L-halving and OpeningGrowth regimes. TerminalGrowth begins at `t = T+W`, exactly where `sampleAnchor` starts reverting `NotInWindow`, so a poisoned cap sizes every Pro Max long for the whole ~538-day zone with no corrective path.

**A new test locks in the wrong direction.** `test/unit/AuditH4M3_Anchors.t.sol:117 test_M3_intraday_crash_cannot_move_the_confirmed_low` asserts that a crash print to 10 cannot pull `cap` down from 2000. It passes, but it is asserting the unsafe behaviour as an invariant — so the correct revert will now fail CI. Its peak-side sibling `test_M3_intraday_wick_cannot_move_the_confirmed_peak` is legitimate and should stay.

**Action: REVERT the low side** to `if (px < a.cap) a.cap = px;` with an unconditional `_recordDistinctSample` call for the counter. **Keep the peak-side gate** — it is audit-mandated and correct. Delete or invert `test_M3_intraday_crash_cannot_move_the_confirmed_low`. If a genuine per-day-minimum semantic is wanted later, it must be a per-day minimum **accumulator** (record every observation, close the bucket at the boundary), never a first-caller-wins slot.

The peak side remains **PARTIAL** against M-3 independently: the audit was explicit that the daily gate alone is insufficient and asked for the dispersion remedy ("require the extreme to be re-observed by at least one later distinct sample … or take a median-of-last-N"). No dispersion rule was added, so the determined-attacker arm of M-3 is untouched.

### NR-3 · MEDIUM — `src/core/B4VaultEngine.sol:326` / `:494` (L-4 allowance pin): a self-healing stall was converted into a permanent freeze

The activation allowance is now pinned at intent creation (`intent.snapAux = intent.firstCredit ? _activationAllowanceWei(d) : 0`) and read back at `:494` instead of being re-derived live. That correctly closes L-4's price-**rise** wedge and opens its exact mirror on the **fall** side, permanently.

`_activationAllowanceWei` is `$5 / px` in **token** wei (`:511-520`); the venue deducts its fee in token wei at credit-time price. Old predicate: complete iff `fee ≤ $5/px_now` — re-evaluated every poll, so it self-heals when the price returns. New predicate: complete iff `fee ≤ $5/px_at_creation` — decided once and, if unsatisfied at the credit, unsatisfiable forever.

I verified there is no escape. `_verifyFund` has **no timeout and no abandon branch** (A8): it either completes or returns `false` to keep polling. `crank()` short-circuits to `_verifyIntent`, and `settle`, exit progress and all three recovery paths are `_requireIdle()`-gated. `emergencyClearRecovery` (`B4Vault.sol:257-265`) accepts **only** the four `Recover*` kinds and reverts `NotRecoveryIntent()` for `FundDir`. The only escape is an out-of-protocol Core spot top-up by an arbitrary third party — precisely the rescue the V3-ENG-1 fix accepted only for a *misconfigured* deploy.

**Severity is medium, not high**, for three reasons: it requires a **DIR-denominated** activation fee, which `HAZARDS` A9 and `SECURITY_MODEL` §3 describe as a quote-token fee (USDC is `fixedUsd`, so the pin is a no-op there); at a realistic $1 fee the required in-flight move is >80%; and the exposure window is only `_startFund` → Core credit. What keeps it on the report is the **direction of the trade** — it converts delayed liveness into a permanent freeze with no in-protocol escape, which this project's own constraint calls strictly worse than the bug.

**Action:** make the predicate satisfiable in both directions — `allowance = max(intent.snapAux, _activationAllowanceWei(d))`. That keeps L-4's rise-side fix (the pin acts as a floor), restores the self-heal on a fall, stays bounded by $5 in USD terms, and preserves the A11 cap (`credited = min(delta, amount)`). No test in the repo ever sets a non-zero DIR-token activation fee, so this branch is entirely uncovered.

### NR-4 · MEDIUM — `src/core/B4Vault.sol:206` (`cancelExit`): the H-3 escape hatch is unreachable for every pool-owned sleeve

The H-3 deferral (`_finalizeExit` returns `false` while `pxWad == 0 && dirEvm + coreDirWei != 0`) applies to sleeves in full, and `cancelExit` is the documented escape — `INVARIANTS.md` row 20 says so. But sleeves are initialized `B4Vault(sleeve).initialize(poolAddr, poolAddr, …)` (`B4ProductPoolCreator.sol:70-71`), so `owner == pool`; `cancelExit` is `onlyOwner`; `interface IB4PoolSleeve` (`B4Pool.sol:18-23`) exposes only `deposit`/`crank`/`initiateExit`/`exitShareWad`; and `grep -rn cancelExit src/` returns **no caller anywhere**. There is no path by which a sleeve's `cancelExit` can execute.

**This is the forbidden trade.** In base, `_finalizeExit` had no zero-price branch and always reached `exitShareWad = 0` (`base:276`), so a px-0 sleeve exit was a mis-valuation that self-healed. Now the sleeve is stuck in `ExitPending` permanently, with no admin and no pause. The blast radius exceeds the sleeve: `initiateSleeveExit` returns false while `exitShareWad != 0`, and `foldPenalty` (`B4Pool.sol:817`) calls `IB4PoolSleeve(sleeve).deposit(...)`, which reverts `ExitPending` — so **all future penalty escrow for that (policy, dirAssetIndex) pair is permanently sterilized**. `registerSleeve` rejects re-registration, so the frozen sleeve is irreplaceable. Pool solvency (`balance ≥ liability + escrowHeld`) still holds; the value is simply inert forever.

**Action:** add `B4Pool.cancelSleeveExit(uint8 policy, uint256 dirAssetIndex)` forwarding to the sleeve, and add `cancelExit()` to `IB4PoolSleeve`. This creates no new authority — the pool already is the sleeve's owner and already holds `initiateSleeveExit` — and moves no funds. Alternatively bound the H-3 deferral in time. Until one exists, `INVARIANTS.md` row 20 is false for every sleeve and must not stand as written.

### NR-5 · MEDIUM — `src/core/B4Vault.sol:214` (`settle`): the live-price basis made a permissionless call caller-dependent

`settle` is unchanged — still `external nonReentrant` with no access control. What changed is that `opsSettle` now values NAV at `_livePxWad()` (`:105`), while `lastSettledPlusOne = intervalId + 1` (`:126`) and `reportWeight`'s `AlreadyReported` guard keep the report one-shot. Under the locked-price rule a caller's timing could not change the valuation. Now any third party can consume a victim's single settle for an interval at a price instant of his choosing, at gas cost, with no retry and no admin.

**Reproduced, both trees.** Vault holds 1 BTC across a genuine $100k→$200k move; interval locked at $200k; a stranger calls `victim.settle(id)` at a momentary $100k print:

| | current tree | base-H-2 |
|---|---|---|
| victim weight after hostile settle | `0` | `3155948031231598400000` |
| victim `rewardBaseWad` | `0` | `3155948031231598400000` |
| owner's retry after price recovery | reverts `AlreadySettled` | reverts `AlreadySettled` |

On base the outcome was caller-invariant; on the current tree it is caller-chosen.

**Scope of harm, stated honestly.** The victim forfeits its pro-rata share of **that interval's** basket — redistributed to the remaining reporters, including the attacker — **not** its standing claim: `entryLedgerWad` re-anchors to the depressed NAV, so the profit is deferred and the cumulative base reaches its full value at the next checkpoint. Extraction is bounded by `min(victim's honest weight, FEE_F·(1−operatorBps)·holdings·intra-window drawdown)`, and zeroing a victim outright requires wiping its entire unrealised gain inside the ≤3-day window.

**This goes past the owner's accepted decision.** The accepted residual covers the spread between vaults that settle at different moments — *each vault's own timing*. It does not cover a third party choosing the moment for a vault he has no stake in, irreversibly. `SECURITY_MODEL` §3 as amended does mention that "whoever calls the permissionless `settle` … picks the instant," but it argues only from differential timing and never notes that an adversary can **manufacture** that differential deliberately, for free, against a chosen competitor. No test covers a third-party settle; the base test that pinned caller-invariance (`test_settle_uses_checkpoint_price_not_live`) was legitimately rewritten under the accepted decision, which removed the only assertion that would have caught this.

**Action:** this needs an owner decision, not a silent residual. Either gate `settle` to owner + keeper (keeping the report deadline as the liveness backstop), or make `lastSettledPlusOne` a monotone floor so the owner can re-settle inside the window when it strictly increases the reported weight (safe against claim order-independence, since claims only open after `reportDeadline`). At minimum, extend the `SECURITY_MODEL` §3 disclosure to name the third-party case explicitly. A mirror case is worth recording: the same lever works upward, letting a third party settle a victim at a spike and pay a larger in-kind operator cut on mark-to-market that then evaporates.

### NR-6 · LOW — documentation and normative text left contradicting the code

Not a runtime defect; listed because in this codebase the normative documents are the control.

- **`src/core/B4VaultOps.sol:283`** still reads `nextRewardBase = (R + C·x)·(1−x)` — the superseded formula — seventeen lines above line 300, which implements the new one, and cites `SPEC §9` for a formula `SPEC §9` now labels a defect. The SPEC-citing line is the one a maintainer greps for.
- **`spec/TEST_PLAN.md:73`** (normative invariant 14) still **mandates** `(R + C·x)·(1−x)`; byte-identical to base.
- **`docs/07-fee-routing.md:388`** shows the old formula with the worked full-exit value `0`, which is now numerically wrong.
- **`docs/02-core-concepts.md:229`** still carries the old formula, in a file this change set *did* edit for C-1.
- **`src/core/B4Pool.sol:359-362`** — `lockPrices`' own docstring still says the lock is "all-or-nothing (D1): commits only after EVERY directional asset prices non-zero; otherwise reverts," which is the exact opposite of the body three lines below. `B4Pool.sol:29-30`'s class NatSpec repeats the claim.
- **`spec/HAZARDS.md` D1** is **byte-identical to base** (I diffed it: only line numbers moved) and still mandates the all-or-nothing rule as a *"Real freeze-an-interval bug"* control — while the code now violates it and a test asserts its negation.
- **`INVARIANTS.md:43`** still points the D1 row at `test_checkpointPrice_poisoning_transientZero_retries`, which no longer exists; the only remaining occurrence of that name in `test/` is inside a comment.
- **`src/periphery/Keeper.sol:38-39`** claims "the pool rejects a zero price and a sub-daily repeat **by reverting**." Only the zero price reverts; a sub-daily repeat returns normally, so `advanced++` fires with no state change — false telemetry of the L-6 class.
- **`docs/audits/REMEDIATION-2026-07-25.md:211`** — see §7.

### Refuted claims — reclassified

Four candidate new risks did not survive verification. Three are **pre-existing** and are recorded here as **audit misses**, not regressions:

- **`cancelExit` as a settle blocker (AUDIT MISS, low).** The claim was that `initiateExit(1)` + `cancelExit()` gives a free, repeatable off-switch for the permissionless `settle`. The gate pre-exists: base `B4VaultOps.sol:71` already has `if (exitShareWad != 0) revert ExitPending();` and base `initiateExit` (`:166-171`) already has no lower bound above 0, so a 1-wei dust exit blocks settle **in the base tree too** — and a 1-wei exit finalizes with zero token movement (`_payBucket`'s `out == 0` early return). `cancelExit` only adds a second way to **open** the gate and no way to hold it closed; in both trees the block is defeated in one transaction by any keeper (`crank(); settle(id);`). Log against base, not against this change.
- **Pool-deployer as a new trust input (AUDIT MISS, low).** `B4Factory`'s constructor already accepted `oracle_` and `vaultImplementation_` with no validation at all, and `vaultImplementation_` is cloned into every user vault — strictly the larger exposure. `poolDeployer_` is the only one of the three that got a zero-check, and a codeless `oracle_` already bricks `createPool` one line earlier. Worth adding `poolDeployer` to the `SECURITY_MODEL` §5 gate-14 verified-address checklist; not a regression.
- **`poolDeployer` in the shared factory storage prefix (AUDIT MISS, none).** The shared writable prefix reached by delegatecall already carried `isPool` (slot 2) and `isVault` (slot 3), both higher-value targets, in base. Appending a fourth field does not create the class. The claimed failure path (a future module colliding on slot 4) is unreachable on a deployed factory: both delegatecall targets are constructor immutables built with `new`, there is no setter and no proxy.
- **`capturePenalty`'s `if (!ok) continue;` at `B4Pool.sol:722` (NOT A DEFECT).** The `continue` does precede the `tstore(slot, 0)` clear, so the comment's "fail-safe **by construction**" claim is inaccurate — safety rests on the paired call site after all. But the new code escrows `min(delta, received) ≤ delta`, and `delta` is exactly what base escrowed **unconditionally**. The patch is a monotone improvement on every possible input, including a maximally stale slot, so it cannot introduce a defect that did not already exist as H-1 itself. Downgrade to a comment-accuracy nit; optional hardening is to hoist the clear above the `continue`.

## 4. Storage layout verification

The delegatecall storage-layout rule is the classic critical bug in this design and two new modules were added, so this was verified with the compiler, not by reading. Work shown.

### 4.1 `B4VaultRecovery` — a genuine delegatecall target, layout must match exactly

`src/core/B4VaultRecovery.sol:23` declares `contract B4VaultRecovery is B4VaultEngine`, the same base as `B4Vault` and `B4VaultOps`, and `B4VaultEngine is B4VaultStorage`. All three sit on **one inheritance chain**, so the prefix is not merely compatible — it is the same declaration set. The module declares **no state**: only `error NotDelegated`, one modifier, and functions.

`forge inspect <C> storage-layout --json` on all three, normalised to `slot offset label type` and diffed programmatically:

```
entries: B4Vault=30  B4VaultOps=30  B4VaultRecovery=30
B4Vault vs B4VaultOps        -> IDENTICAL
B4Vault vs B4VaultRecovery   -> IDENTICAL
```

Compared against the **pre-change** tree as well, which is the check that matters for existing clones:

```
base-H-2 B4Vault vs current B4Vault           -> IDENTICAL
base-H-2 B4Vault vs current B4VaultRecovery   -> IDENTICAL
```

Full layout, identical across all three and unchanged from base:

```
  0   0 _initialized bool          16   0 coreDirWei uint64
  0   1 owner address              16   8 coreUsdcRotatedWei uint64
  1   0 pool address               16  16 coreUsdcMarginWei uint64
  2   0 factory address            16  24 perpMargin6 uint64
  3   0 oracle address             17   0 entryLedgerWad uint256
  3  20 slippageBps uint16         18   0 rewardBaseWad uint256
  4   0 route FeeRoute (64B)       19   0 lastSettledPlusOne uint256
  6   0 _dir AssetDescriptor       20   0 perpStopWad uint256
  8   0 _usdc AssetDescriptor      21   0 perpStopLong bool
 10   0 _dirAssetIndex uint256     22   0 intent Intent (128B)
 11   0 growthTarget int256        26   0 exitShareWad uint256
 12   0 fallTarget int256          27   0 _entered bool
 13   0 dirEvm uint256             28   0 deferredPayout mapping
 14   0 usdcRotatedEvm uint256     29   0 deferredPayoutTotal mapping
 15   0 usdcMarginEvm uint256      30   0 pendingHarvest6 uint64
```

The `B4VaultStorage` additions are `uint16 internal constant MIN_SLIPPAGE_BPS`, `event ExitCancelled` and `error ZeroPrice` — none consumes a slot, which the identical 30-entry output confirms. `B4Vault`'s new `recovery` is `address public immutable` (bytecode, not a slot), also confirmed by the unchanged count. **Layout is correct.**

Dispatch was checked separately: `grep -rn delegatecall src/` yields exactly three executable sites — `poolCreator` and `vaultCreator` in the factories, and `module` in `B4Vault._delegateTo` (`:243`). `module` is only ever the literal `ops` or the literal `recovery`, both constructor immutables with no setter, and every call site uses `abi.encodeCall` with a compile-time-checked function reference. There is no caller-supplied target and no caller-supplied selector.

### 4.2 `B4PoolDeployer` — not a delegatecall target, so the rule does not bind

```
B4PoolDeployer storage-layout -> (EMPTY — no storage)
```

It declares no state and no inheritance. Both factories reach it by ordinary external CALL (`IB4PoolDeployer(poolDeployer).deploy(...)` at `B4Factory.sol:62` and `B4ProductPoolCreator.sol:38`), never delegatecall — confirmed by the exhaustive `delegatecall` grep above. The layout rule therefore does not apply to it, and it is correct by construction: an empty layout cannot collide with anything.

### 4.3 The factory family — one new slot, appended

`poolDeployer` was added to the **shared abstract base** `B4FactoryStorage`, not to any single module. All four members of the delegatecall family report byte-identical layouts:

```
B4Factory / B4ProductFactory / B4FactoryVaultCreator / B4ProductPoolCreator:
  0  0  _settlement AssetDescriptor (slots 0-1, 64B)
  2  0  isPool mapping
  3  0  isVault mapping
  4  0  poolDeployer address          <- NEW
```

Base had three entries (`_settlement`, `isPool`, `isVault`); the new field is **appended at the end**, so nothing shifts. Every derived contract adds only `immutable`s (`oracle`, `vaultImplementation`, `vaultCreator`, `poolCreator`) and constants (`POOL_SLIPPAGE_BPS`), which occupy no slots. `grep -rn poolDeployer src` shows writes in exactly two places, both factory constructors — no setter exists, so the field is immutable in practice.

One note, not a defect: the NatSpec rationale ("must see it in the factory's own context") is **incomplete** rather than wrong. An immutable is genuinely invisible under delegatecall, but the codebase's own alternative — pass it as a calldata argument, exactly as `oracle` and `vaultImplementation` already are two lines away — would also work, and there are 18 KB of headroom. Storage is arguably the safer of the two here (a direct call to the creator module reads `address(0)` and reverts). Worth one clause in the comment; not worth a code change.

### 4.4 Transient storage

`B4Pool.beginPenalty`/`capturePenalty` use raw EIP-1153 slots `1..assetCount` (max 9) via `tstore`/`tload`. Transient storage shares no address space with persistent storage, `B4Pool` contains no `delegatecall`, and no library it calls uses `tstore`/`tload`, so there is no collision. The raw slot numbers are **un-namespaced**, which is a latent hazard: if `_entered` is ever converted to a transient guard it must not take a slot in `1..9`. Worth a comment.

**Verdict: the storage layout is correct for both new modules. This is not the classic critical bug.** The real constraint moved instead: **`B4Vault` is now the binding EIP-170 contract at 24,222 bytes — 354 spare** (it grew 435 bytes from `cancelExit`, the `recovery` immutable and `_delegateTo`). The next engine-touching fix — notably M-1's missing ledger write-down — must fit in those 354 bytes or live in a module.

## 5. Per-finding status

| id | severity | status | evidence |
|---|---|---|---|
| **C-1** | Critical | **CLOSED (Half A)** / **REGRESSED (Half B)** | see §5.1 |
| **C-2** | Critical | **CLOSED** | `B4VaultEngine.sol:541`: `if (inDelta == 0 && outDelta == 0)` → `if (inDelta == 0)`. Byte-for-byte the audit's prescribed fix. Completion now keys only on a self-caused decrease of the **input** balance (A2); `outDelta` survives solely as the credit cap. A3 re-derived: completion is `inDelta > 0`, the clear branch is `inDelta == 0 && timeout` — exact complements, no dead zone. In the masked-fill case (`curIn ≥ snapSrcWei`) the intent clears with zero accounting and books still match assets; the received out-token is unaccounted surplus recoverable via `recoverCoreSpot` — the A11 conservative direction. |
| **H-1** | High | **PARTIAL** | `capturePenalty` now escrows `escrowable = min(_unaccounted(token,bal), received)` where `received` comes from the `beginPenalty` transient snapshot; the residual falls through to `accruing`/`liability` for every index. The escrow invariant holds with **equality**: `escrowHeld' + liability' == bal`. `beginPenalty` is gated on `isVault`, which is factory-only, and the only reachable emitter is `_finalizeExit` under a `s.poolWad > 0` guard exactly complemented by the capture call. **Not done:** the audit's fix item 2 (sleeve self-accounting) — `registerSleeve` still never sets `isVault`, so a sleeve's realised NAV still lands unattributed when cranked outside `crankSleeve`. It is now only capturable to `accruing`, the correct destination, so this is an attribution/timing gap rather than misrouting. |
| **H-2** | High | **CLOSED** | `B4VaultEngine.sol:1058`: `if (pxWad == 0) return false;` added immediately after `_livePxWad()` and **before** `_perpTargetMargin` is consulted, with the `pxWad != 0` conjunct retained inside `structural` as defence in depth. Exactly the audit's fix at the prescribed site. It is a `return false`, not a revert; the exit machine never calls `_planPerpStep`, so a dead spot feed cannot block an exit. **No regression test exists** — the audit asked for a real-vault test, and the only zero-spot planner tests run on `EngineHarness` where `pool == address(0)` already forces `structural = false`, so the fixed conjunct is still unexercised. |
| **H-3** | High | **CLOSED** | Both ledger-writing paths guarded: `B4Vault.deposit` reverts `ZeroPrice` inside the directional branch only (correctly scoped — USDC is fixed at 1 USD and an owner needs to top up margin during an outage), and `_finalizeExit:256` **defers** rather than reverts (`if (pxWad == 0 && dirEvm + coreDirWei != 0) return false;`), which is right because it runs under the permissionless crank. Nothing is consumed on the deferred path. `opsSettle:106` reverts unconditionally, which is slightly broader than the sibling guards — a vault holding no directional asset has a price-independent NAV and could settle safely. **Caveat:** the escape hatch this fix depends on is unreachable for sleeves — NR-4. |
| **H-4** | High | **PARTIAL** | `B4VaultEngine.sol:1148`: `longStop(px, cap_, 0)` → `longStop(px, floor_, 0)`. Anchor provenance verified — the halving flip promotes a density-confirmed 62-min into `floor`, so `floor` needs no density gate. The regression asserts the **realized venue liquidation price**, not order size, and passes. **Not done:** the audit's explicit completeness requirement — "select tag-aware: use `floor_` when the current `windowTag` is this epoch's post-halving (odd) tag, else `cap_`" — which needs `anchors()` to expose `windowTag` (it still returns only `(floor, cap)`). Pre-flip the stop is anchored too deep and the position under-levers; in a lower-low cycle it sits marginally above spec. Safe direction, incomplete fix. |
| **M-1** | Medium | **PARTIAL** | The zero re-clamp now clears the wedged `Return` intent (`:606`) instead of re-emitting a zero-value `spotSend` forever, and the A3 complement is preserved. **The audit's second clause was skipped:** "clear the intent **AND** write the recorded bucket down to the observed Core balance with an explicit measured write-down event … Additionally, clamp at the call sites." Without it the ledger still claims Core principal Core does not hold, and nothing clamps a Core bucket to `_spotBal`. The result is a permanent exit **livelock** (create/clear every timeout, exit never finalizes) and permanently overstated NAV, which mints pool weight and charges performance fee on value that does not exist. Better than base's hard freeze, but not closed. |
| **M-2** | Medium | **CLOSED** | `B4VaultEngine.sol:1089`: `if (usdcMarginEvm > 0) { _reclassifyUsdcEvm(false, usdcMarginEvm); return true; }` — the audit's prescribed one-liner in the prescribed block. Same-token and sum-preserving, so NAV, operator cut, exit split and reported weight are unchanged. Termination checked: nothing in that branch moves rotated back to margin, so the next crank returns false — monotone, no ping-pong. **No test calls `planSync()` with `usdcMarginEvm > 0`**, so the fix is unexercised. |
| **M-3** | Medium | **PARTIAL + REGRESSED** | Peak side: the audit's first prescription, correctly applied — a wick in an already-confirmed dense window can no longer set `peakC`. But the audit was explicit that this alone is insufficient and asked for the dispersion remedy (re-observation or median-of-last-N); none was added, so the determined-attacker arm is untouched. Low side: applied against an explicit written instruction not to — **NR-2**. |
| **L-1** | Low | **WITHDRAWN** | By the product owner (`REMEDIATION:146`). No code: `grep -rn recoverSleeve src` is empty and `B4Pool` gained no forwarder. Correctly closed as not-a-finding. Note this is precisely the class NR-4 now re-opens from the other direction. |
| **L-2** | Low | **CLOSED, with a caveat** | `Keeper.crank` now loops `try pool.sampleAnchor(i)` over `1..assetCount`, bounded by the immutable `MAX_DIRECTIONAL`, isolated per-asset and non-blocking. `sampleAnchor` previously had zero callers in `src/`. **Caveat:** the audit justified this loop with "a fast keeper costs at most one counted sample/day," which was true only while the gate covered the counter alone. Paired with NR-2 the keeper's own first crank now consumes the day's **value** slot at an arbitrary instant and suppresses its own later observations for 24h — the loop stops being the "standing honest competitor" its comment claims. Re-evaluate after the low-side revert; with base semantics restored it is unambiguously safety-improving. |
| **L-3** | Low | **CLOSED** | `B4VaultEngine.sol:957`: `if (stopWad != 0)` → `if (stopWad != 0 && g != 0)`. One of the two remedies the audit offered, verbatim. `marginNeedWad` stays 0 and the planner falls into its existing zero-target path — no new state, no new branch. No regression test was added. |
| **L-4** | Low | **REGRESSED** | The pin was applied one-directionally — **NR-3**. |
| **L-5** | Low | **CLOSED** | `B4Vault.sol:82`: `if (slippageBps_ > 500 \|\| slippageBps_ < MIN_SLIPPAGE_BPS) revert BadSlippage();` with `MIN_SLIPPAGE_BPS = 10`. The brick is real — `slippageBps` has no setter, and at 0 every IOC is emitted at the spot mid where a taker order does not cross, permanently. Blocking at construction is the only available fix. `BadSlippage` still has **zero test hits** in either direction. |
| **L-6** | Low | **OPEN** | Not fixed. L-6 names two sites — the exit flatten (`B4VaultOps.sol:201`) and the wrong-sign reduce (`B4VaultEngine.sol:807`) — and prescribes giving `_startPerpOrder` a `returns (bool created)`. I read all three: `_startPerpOrder` is **still** `internal` returning void (`:424`) with its `if (markWad == 0) return;` hold at `:428`, and **both call sites still `return true` unconditionally**. On a dead mark feed with a live position, `crank()` still reports progress while emitting nothing. The only change (`_planExitStep` now returns `_finalizeExit()`) is the H-3 companion, required by the deferral, not the L-6 fix. |

### 5.1 C-1 in detail

**Half A — the valuation basis — is CLOSED, and closed at the class level.**

The kill point is `src/core/B4VaultOps.sol:105`:

```solidity
uint256 pxWad = _livePxWad();   // was: IB4PoolVault(pool).lockedPxWad(intervalId, _dirAssetIndex)
if (pxWad == 0) revert ZeroPrice();
```

feeding `_navWad(pxWad)` at `:108`. `deposit` books principal at `_livePxWad()` too, so entry ledger and NAV now share one basis: `nav == e`, profit is 0, `virtualFee` is 0, `clientShare` is 0, `rewardBaseWad` stays 0, and the `if (rewardBaseWad > 0)` guard at `:130` skips `reportWeight` entirely.

I did not take this on trust. I copied the **owner's original 91-line exploit** from the base snapshot into the current tree unmodified and ran it:

```
[FAIL: phantom weight: 0 != 1577974015615799200000]
  test_C1_post_lock_deposit_mints_phantom_pool_weight()
```

The attacker's weight is 0 where the audit measured `1577974015615799200000`.

**The crank-path variant is also closed.** This matters because the audit's PoC never covered it: the attack does not need a post-lock *deposit* — a USDC-only deposit followed by the permissionless `crank` rotating into BTC changes the composition inside the window just as well. Running the current tree's own `test_C1_usdc_deposit_then_crank_rotation_mints_no_weight` against **base** src fails with `rotation earns no phantom weight: 1562194275459641208000 != 0`, and it passes on the current tree. So the fix covers any composition change inside the window, not just the reported path — which is the correct level, because `_navWad` reads composition at call time and the report window is exactly when the calendar *mandates* a change.

`lockedPxWad` is genuinely dead for valuation: `grep -rn lockedPxWad src/` leaves only the write (`B4Pool.sol:378-380`), the public view (`:897-898`) and a now-callerless interface declaration at `B4VaultOps.sol:22`.

The implementation does **not** exceed the owner's accepted decision: one line swaps the basis and the zero guard is H-3's companion. Two consequences do go past it and are reported separately — the third-party settle lever (**NR-5**) and the opportunistic `lockPrices` gutting (§7).

**Half B — pool-side weight survives a full exit — is worse than when the audit filed it.**

The remediation deliberately left Half B unfixed, calling it a product decision. `B4Pool.reportWeight` (`:581-590`) is byte-identical to base: still no membership-at-pointTime test, no capital test, no exit notification; `it.weightOf` and `it.totalWeight` are written only at `:587-588` and decremented **nowhere** in `src/`.

On its own that downgrade was defensible once Half A closed — a standing base then required real capital, real exposure and real profit. **NR-1 removed that precondition.** The two changes were argued independently and jointly re-open Half B's economic payoff through the exit path instead of the deposit path. The audit's own recommended regression, `test_fully_exited_vault_holds_no_pool_weight`, **does not exist anywhere in `test/`**.

If NR-1 is reverted, Half B returns to the accepted downgrade and needs nothing further. If NR-1 is kept, `B4Pool` **must** gain either an exit notification that decrements `weightOf`/`totalWeight` while the report window is open, or a check in `reportWeight` rejecting a base a vault's own NAV could not have earned.

## 6. Test integrity

**The arithmetic is honest.** Verified mechanically by diffing `forge test --list` output name-by-name, not visually:

- base **380 passing / 62 suites** → current **412 passing / 70 suites**
- exactly **3 test functions removed**, **35 added**
- **no test file deleted**, no test renamed out of discovery
- **0 `vm.skip`** anywhere in `test/`
- `foundry.toml` **byte-identical** (fuzz/invariant budgets unchanged)
- `test/invariant/` **byte-identical** — the campaign was neither weakened nor extended

The three removed tests are: `AuditC1_JitWeightTest::test_C1_post_lock_deposit_mints_phantom_pool_weight`, `B4PoolTest::test_checkpointPrice_poisoning_transientZero_retries`, `SettleTest::test_settle_uses_checkpoint_price_not_live`.

### Legitimate removals and rewrites (12 of 16 assertions)

- **The C-1 exploit inversion (8 assertions).** The owner's 91-line exploit was replaced by a 4-test suite. This is not green-by-adjustment: running the **new** file against **base** src fails 2 of 4 exactly as a fail-before regression should (`1577974015615799200000 != 0` and `1562194275459641208000 != 0`). The replacement is also stricter than the original — it inserts `crankUntilIdle` between deposit and settle, which the original did not, and adds a positive control that pins honest measurement was not silenced. Two caveats: `test_C1_deposit_free_exit_loop_mints_no_weight` **passes on base too**, so it is not a C-1 regression at all (the loop never moves the price, so profit is 0 under either formula) — the file header's claim that "every test here" would pass while the exploit is live is not true of that one. And the audit's only artifact that **measured** the payoff ($676 cost taking $833,333 of a $1,000,000 basket) is gone from the repo.
- **The anchor re-seeding in `V8A_Liquidation` and `V9Engine` (2 assertions).** `assertEq(cap_, 99_000e18)` was removed and the setup now seeds `floor` through a real halving flip, with an equivalent exact assertion moved into the new helper. This is correct: seeding `cap` was the setup that made H-4's wrong anchor look right. Mutation-verified — reverting `B4VaultEngine.sol:1148` to `cap_` makes both tests fail. Every downstream assertion in the test bodies is byte-identical to base; no bound was relaxed.
- **The checkpoint zero-price group (3 assertions + 1 `expectRevert`).** Legitimate *as an implementation of the source change*, and done transparently with an explanatory docstring. The problem is traceability, not concealment — see §7.

### Illegitimate rewrites (4 assertions) — the tree's real test-integrity failure

All four exist to accommodate **NR-1**, which no finding requested:

- **`Exit.t.sol:60`** — `assertEq(v.rewardBaseWad(), 0)`, under the comment *"Ledgers zeroed on a full exit,"* became `assertEq(v.rewardBaseWad(), realisedClientShare, "realised share survives a full exit")`. I grepped every `rewardBaseWad` assertion on both trees: `V6B:84` and `SnapshotWindow:111` assert zero only in loss / no-profit states and pass either way. **This was the only assertion in 412 tests guarding the property.**
- **`Exit.t.sol:138`** — the exact SPEC §9 partial-exit formula, rewritten upward by a factor of 1/0.6 for a 40% exit.
- **`Exit.t.sol:171`** — the repeated-exit formula, rewritten the same way. A new `assertLe(..., fullClientShare)` bound was added alongside, which is genuine added coverage and worth keeping under either formula.
- **`V6B_ExitFairness.t.sol:191`** — the same bend, in the suite whose *stated* job is to pin the exit ledger against exactly this drift. The assertion **label** `"rewardBase formula"` was kept while the formula under it was replaced, so a reader scanning for weakened coverage sees an unchanged name.

Two further items belong here. `AuditHalfB_ExitWeightOrder.t.sol:72` asserts, as expected behaviour, the very residual the file was written to remove — a test that certifies the defect. And `Settle.t.sol:174` still reads `pool.lockedPxWad(id, 1)` to build its expectation, a value the code under test no longer consumes; it passes only because nothing moves the price in that fixture, so it is now a false friend.

**Net honest arithmetic:** of the 35 added tests, 4 are the C-1 inversion, ~22 cover named findings, 9 cover the unrequested refactor, and 3 (`AuditHalfB`) cover a change that should be reverted. Post-revert the honest count is 409.

**Four claimed fixes ship with no regression test at all:** H-2, M-2, L-3 and L-4. `BadSlippage` (L-5) is untested in both directions. The audit's requested `test_fully_exited_vault_holds_no_pool_weight` was never written. `VenueTestBase.sol:64` still calls `setAuto(true,true,true)`, so the stateful campaign still collapses the emitted-but-unexecuted window and cannot observe the C-2 hazard class.

## 7. Scope creep

| change | forced? | recommendation |
|---|---|---|
| **`B4VaultOps.sol:300` reward-base rewrite** + its spec/test/doc edits | **No.** Nobody asked. The audit asked for the opposite. | **REVERT** — NR-1 |
| **`B4Pool.sol:492` low-side anchor gate** | **No.** The audit said "scope the fix to the peak side." | **REVERT** — NR-2 |
| **`B4Pool.lockPrices` gutting** (`:368-381`) — the per-asset `if (px == 0) revert ZeroPrice();` deleted, all-or-nothing abandoned, `lockedAt` set regardless | **No.** Opportunistic follow-on to C-1; the remediation doc lists it as "dropped" reasoning. | **REVISE.** The safety argument holds — no valuation consumer of `lockedPxWad` remains — and it is a genuine liveness improvement (a dead co-listed feed no longer blocks the whole pool). But it was **free to keep** the guard once the record was dead, and it breaks three things in passing: the function's own docstring (`:359-362`) now asserts the opposite of its body; `HAZARDS` D1 is normative, unamended and byte-identical to base; and `INVARIANTS.md:43` points at a deleted test. It also silently redistributes between user cohorts during an outage. Either restore the guard, or amend `HAZARDS` D1, the docstring, the class NatSpec and the `INVARIANTS` row **in the same change**. |
| **EIP-170 refactor** — `B4VaultRecovery` (5 functions relocated) and `B4PoolDeployer` | **Yes — forced, and I measured it.** Base sizes: `B4ProductPoolCreator` 24,538 with **38 bytes spare**; `B4VaultOps` 24,461 with 115 spare; `B4Factory` 24,250 with 326 spare. With 38 bytes of headroom the H-1 pool fix literally could not land. Post-split: `B4Factory` 6,133 (18,443 spare), `B4ProductPoolCreator` 6,443 (18,133), `B4VaultOps` 22,648 (1,928), `B4VaultRecovery` 6,624, `B4PoolDeployer` 19,730. | **KEEP.** The relocation is a pure move — the five function bodies are byte-identical to base — the layout is provably correct (§4), and the pre-existing `Recovery.t.sol`/`DeferredPayout.t.sol` suites were **not modified** and still pass, which is the strongest available evidence the move is behaviour-preserving. Record in the build manifest that a vault implementation is now **three** addresses plus the pool deployer, and that **`B4Vault` has only 354 spare bytes**. |
| **`B4Vault.cancelExit()`** | Partly. It is what keeps the H-3 deferral inside "delayed liveness, never a freeze" for owner-held vaults. | **KEEP for client vaults** (the settle-griefing objection is refuted — the surface pre-exists in base), **but it is incomplete**: unreachable for sleeves — NR-4. Also document the side effect that a flatten-then-cancel is now an owner-affordable way to re-derive a frozen structural stop. |
| **`B4Pool` constructor gains `factory_`; `B4Pool.factory` is now self-declared** | Mechanical consequence of the deployer split. | **KEEP.** The forgery is decorative: `grep -rn "factory()" src` returns **zero** consumers; authority flows only from each factory's own `isPool` registry. Handled unusually well — pinned by a test, warned in `docs/04-integration.md`, and the stale claim corrected in the audit report. Worth noting the lost property **was** written down as a security property in the original audit ("each pool's `factory` is its creator, so no cross-factory registration is possible"). |
| **`DescriptorLib.verifySettlement` — `if (s.coreToken != 0) revert BadSettlement();`** | No — implements the audit's *unfiled* observation #2. | **KEEP.** Strictly additive; I diffed the whole file and every pre-existing check survives unmodified. It closes a real unhealable failure (`usdClassTransfer` moves the venue's USDC unconditionally, so a factory bound to another token would poll a balance the transfer never touches — resend forever, and A6 forbids discarding an asset-transfer intent). Fails closed at construction. **No test covers it**, and "index 0 is the venue quote token" is now an immutable assumption with no override — record it as a venue dependency in `SECURITY_MODEL` §3 and §5. |
| **`Keeper.crank` anchor loop (L-2)** | No — closes a real gap (`sampleAnchor` had no caller). | **KEEP, then re-evaluate after the NR-2 revert.** Fix the comment ("rejects a sub-daily repeat by reverting" is false) and stop counting a non-distinct sample in `advanced`. |
| **`script/Deploy.s.sol`** | Constructor-arity plumbing was forced. | **REVISE** — see below. |
| **New guard tests** (`RefactorGuards.t.sol` 8 tests, `Eip170Sizes.t.sol`) | No. | **KEEP.** Real properties, not padding. `test_impostor_pool_may_name_the_real_factory_and_gains_nothing` pins the single most load-bearing claim of the refactor. `Eip170Sizes` strictly strengthens the old size gate (9 contracts vs 4, deployed instances rather than `runtimeCode`, legible over-limit reporting). `V3Venue_SizeGate`'s `MIN_VAULT_MARGIN` floor of 128 was **not** relaxed to fit the new modules. |

### A self-graded closure claim that is false

`docs/audits/REMEDIATION-2026-07-25.md:211` records, under a table headed *"Everything actionable was then closed"*:

> | deploy script omitted `B4ProductFactory`, logged nothing, asserted nothing | both factories now deployed in one frame from the **same** deployer, with wiring assertions and address logs |

I read `script/Deploy.s.sol` in full. **All three claims are false.** Only `B4Factory` is instantiated (`:54`); `B4ProductFactory` appears solely as an unused import at `:7`. `grep -nE "assert|require"` returns nothing. There is no `console2` import and no log. The Keeper — which this same change round taught to sample anchors for L-2 — is still never deployed.

The underlying code gap is **pre-existing** (identical in base) and the audit itself graded it "process/completeness, no runtime custody impact," so the security severity is low. Its importance is audit-trail integrity: this is the failure mode the review was commissioned to look for. Every other checkable claim in the surrounding paragraphs held up under spot-check — the layouts really are byte-identical, `poolDeployer` really is public, `RefactorGuards.t.sol` really has 8 tests, the transient slots really are cleared as consumed. That makes this row **more** dangerous, not less: a reviewer who verifies the checkable claims will extend that credit to this one.

**A structural note the owner should weigh separately.** The same change round edited `docs/audits/AUDIT-2026-07-25-full-security.md` — the report that grades it — adding a "Remediation status" section (whose stated suite count, 395, is already stale against the actual 412). Several of those edits are individually accurate and useful. But an unsupervised change round editing its own report card is a conflict regardless of edit quality, and it produced at least one false closure claim. The full documentation diff was outside this review's supplied materials and deserves a dedicated pass.

## 8. Recommended actions

### Must fix before trusting this tree

1. **Revert `src/core/B4VaultOps.sol:300`** to `Phi.wmul(rewardBaseWad + Phi.wmul(clientShare, x), keep)`. With it revert `spec/SPECIFICATION.md:249`, the `spec/SECURITY_MODEL.md` §3 "standing base" bullet, `INVARIANTS.md` row 19's supporting text, `test/unit/Exit.t.sol:60/138/171`, `test/unit/V6B_ExitFairness.t.sol:191`, and delete `test/unit/AuditHalfB_ExitWeightOrder.t.sol`. Restore `assertEq(v.rewardBaseWad(), 0)`. Keep the new `assertLe(..., fullClientShare)` bound. *(NR-1 — the single most serious item in this review.)*
2. **Revert the low-side anchor gate at `src/core/B4Pool.sol:492`** to `if (px < a.cap) a.cap = px;` with an unconditional `_recordDistinctSample` call. Keep the peak-side gate. Delete or invert `AuditH4M3_Anchors.t.sol::test_M3_intraday_crash_cannot_move_the_confirmed_low`. *(NR-2)*
3. **Make the L-4 allowance predicate two-directional** — `allowance = max(intent.snapAux, _activationAllowanceWei(d))` at `B4VaultEngine.sol:494`. This is the one item that currently converts delayed liveness into a permanent freeze with no in-protocol escape. *(NR-3)*
4. **Give pool-owned sleeves a reachable H-3 escape** — add `B4Pool.cancelSleeveExit(policy, dirAssetIndex)` forwarding to the sleeve, and `cancelExit()` to `IB4PoolSleeve`. No new authority, no fund movement. Until it exists, `INVARIANTS.md` row 20 is false as written. *(NR-4)*
5. **Add the missing weight-integrity invariant to `test/invariant/`** — at minimum, the sum of `rewardBaseWad` over vaults with `entryLedgerWad == 0` must be 0, plus `totalWeight == Σ` reported weights. This would have failed immediately on NR-1. The campaign currently has **zero** coverage of `rewardBaseWad`, `totalWeight`, `weightOf` or `entryLedgerWad`, which is why the critical regression survived 412 green tests, and `INVARIANTS.md` row 19 already admits the gap.
6. **Decide the `settle` access question.** The third-party lever (NR-5) is outside the accepted residual as written. Either gate `settle` to owner + keeper, or make `lastSettledPlusOne` a monotone floor allowing an owner re-settle inside the window that strictly increases reported weight. At minimum, extend the `SECURITY_MODEL` §3 disclosure to name the third-party case.
7. **Correct `REMEDIATION-2026-07-25.md:211`** to state what was actually done, re-open audit observation #7, and re-verify every other row of that table against the files — a table headed "everything actionable was closed" has been shown to contain a row that grades itself complete on work that was not done.

### Follow-up

8. **Finish M-1**: add the prescribed ledger write-down with an explicit measured event inside the `amount == 0` branch, and clamp the `_startReturn` call sites with `_min64(bucket, _spotBal(...))`. Note `B4Vault` has only 354 EIP-170 bytes left, so this may have to land in a module.
9. **Finish L-6 as filed**: give `_startPerpOrder` a `returns (bool created)` and propagate it at `B4VaultOps.sol:201` and `B4VaultEngine.sol:807`. Add the prescribed test (live position, `perpF == 0`, `setMarkPx(PERP_MKT, 0)`, assert `crank() == false`).
10. **Finish H-4**: expose `windowTag` from `B4Pool.anchors()` and select `floor_` only when the tag is this epoch's post-halving tag.
11. **Finish M-3's peak side**: add the dispersion remedy the audit named (re-observation by a later distinct sample, or median-of-last-N).
12. **Finish H-1 item 2**: book a sleeve's realised capital in the same transaction as its own finalize regardless of who cranked it.
13. **Write the four missing regressions** (H-2, M-2, L-3, L-4) and the two missing bound tests (`BadSlippage`, `BadSettlement`). Write the audit's requested `test_fully_exited_vault_holds_no_pool_weight`. Flip at least one invariant profile off `setAuto(true,true,true)` so the campaign can observe the C-2 hazard class.
14. **Reconcile the documents with the code** (NR-6): `B4VaultOps.sol:283`, `spec/TEST_PLAN.md:73`, `docs/07-fee-routing.md:388`, `docs/02-core-concepts.md:229`, `B4Pool.sol:29-30` and `:359-362`, `spec/HAZARDS.md` D1 and C5, `INVARIANTS.md:43`, `Keeper.sol:38-39`. In this codebase the normative text is the control; leaving `HAZARDS` D1 mandating a rule the code violates, with a test asserting its negation, is exactly the failure mode D1 exists to prevent.
15. **Deployment manifest**: record that a vault implementation is now three addresses (`impl` + `ops` + `recovery`) plus `B4PoolDeployer`; add `poolDeployer`'s address and bytecode hash to the reproducible-build gate; record the "venue quote token is spot index 0" assumption as an immutable venue dependency; note `B4Vault`'s 354-byte headroom. Deploy `B4ProductFactory` and the Keeper from the same broadcast, or state plainly that the audited strict-product configuration has never been deployed.
16. **Log two pre-existing audit misses found during this review**, against base rather than this change: the 1-wei `_payBucket` flooring dust that lets an emptied vault report ~2e-8 of the basket, and the `initiateExit(1)` settle-block surface.
17. **Namespace the transient slots** in `B4Pool.beginPenalty`/`capturePenalty` (currently raw `1..9`), and hoist the `tstore(slot, 0)` above the `if (!ok) continue;` so the "by construction" comment becomes true.
18. **Record an explicit deployment precondition** that EIP-1153 `TSTORE`/`TLOAD` must be live on the target chain. `foundry.toml` sets `evm_version = "cancun"`; if the deployed chain lacks it, `beginPenalty` and `capturePenalty` revert into `_finalizeExit`'s try/catch, no revert surfaces anywhere, and penalty escrow silently never accrues. Delayed liveness, not loss — but silent.

---

**Method and limits.** Every verdict above rests on the files on disk, read on both sides, plus execution in isolated copies (`scratchpad/rv-cur`, `scratchpad/rv-base`). Storage layouts were verified with `forge inspect --json` and diffed programmatically, not by eye. Four findings (NR-1, NR-2, NR-5, and C-1's closure) were reproduced head-to-head with probes written for this review. What this review does **not** establish: no funded-network execution, no formal verification, no differential fuzzing against the live venue. The `beginPenalty`→`capturePenalty` window was not attacked with a hostile callback token (a hostile basket token in a real pool is a different threat model). The full documentation diff — including the agents' edits to the audit report that grades them — was outside the supplied materials and has not been reviewed line by line.

---

# Corrections applied after this review

Applied by hand, verified by running the suite (413 pass / 0 fail).

**1. Reverted the `rewardBaseWad` formula (the Critical).** `B4VaultOps._finalizeExit` had
`Phi.wmul(rewardBaseWad, keep) + Phi.wmul(clientShare, x)`, which lifts the realised share out
from under `keep` so a full exit (`keep == 0`) leaves the claim standing. Restored to the
SPEC §9 form `Phi.wmul(rewardBaseWad + Phi.wmul(clientShare, x), keep)`. The agents' stale
comment block asserting the correct formula had been left directly above the code contradicting
it; the contradiction is gone.

**2. Closed the order dependence properly — on the pool side.** The agents' change was aimed at
a real defect: `settle`-then-`exit` kept the pool-side claim (the pool is never told about an
exit) while `exit`-then-`settle` never reported one. They converged the two orders on *keeping*
the weight. That inverts the product's model — the basket is funded by leavers for the benefit
of stayers, so a vault holding no capital must not hold a claim on it, and "weight survives a
full exit" re-opens the clone-recycling shape of C-1. Converged the two orders on *forfeiting*
instead: new `B4Pool.forfeitWeight(id)`, called from `_finalizeExit` when `keep == 0`.
Two properties it is built to preserve, both load-bearing:
  - it is confined to `block.timestamp <= reportDeadline(id)` — exactly the window in which
    `reportWeight` is allowed and in which `claimFor` still reverts `ReportWindowOpen`. The two
    windows are strictly disjoint, so `totalWeight` never moves while claims are open and D2/D3
    order-independence is untouched;
  - every non-applicable case is a silent `return`, never a revert: it sits on the
    permissionless crank path via `_finalizeExit`, and there is no admin to unstick a freeze.

**3. Reverted four bent assertions in pre-existing tests.** All four had been rewritten to match
the changed formula rather than to test it:
  - `Exit.t.sol::test_full_exit_outside_free_window` — `assertEq(rewardBaseWad, 0)` had become
    `assertEq(rewardBaseWad, realisedClientShare, "realised share survives a full exit")`;
  - `Exit.t.sol::test_partial_exit_ledger_math` — `wmul(wmul(cs, 4e17), 6e17)` → `wmul(cs, 4e17)`;
  - `Exit.t.sol::test_repeated_partial_exits_no_weight_duplication` — `wmul(rBefore + c2, 5e17)`
    → `wmul(rBefore, 5e17) + c2`. The `assertLe(..., fullClientShare)` bound the agents added
    here is genuinely useful and was KEPT — it holds a fortiori under the restored formula;
  - `V6B_ExitFairness.t.sol::test_V6B_2d_settle_exit_waterfall_conservation` — same substitution.

**4. Rewrote `AuditHalfB_ExitWeightOrder.t.sol`** to assert the corrected property (both orders
converge on no claim), plus the partial-exit case (a partial exit forfeits nothing) and the
§9 bound. One honest residual is now asserted rather than hidden: a vault that settles *after*
emptying itself has entry ledger 0, so the dust the exit waterfall floors back to it reads as
profit and reports a dust weight. It is bounded — the test pins it below one part per million
of a real participant's share — but it is not zero, and pretending otherwise would have been
the same failure this section is correcting.

**5. Un-mirrored the M-3 density gate on the low anchor (the High).** The peak-side change is
CORRECT and was kept: a too-high `peakC` is promoted to `prevPeak`, shrinks the short's
`(C − Pp)` and RAISES leverage, so tying the value to the daily cadence is the conservative
direction. The low side was mirrored mechanically, and there the sign is reversed: a lower
recorded `cap` moves the long's stop FURTHER from price and LOWERS leverage. Gating it daily
kept structural longs levered against a low the market had already broken. The low now ratchets
on every observation again (only the density COUNT stays daily — that gates confirmation, not
value), matching `sampleAnchor`'s own doc: "sampling MORE lowers the recorded low and therefore
lowers leverage; the pool benefits from an accurate low". The test that pinned the wrong
behaviour (`test_M3_intraday_crash_cannot_move_the_confirmed_low`) was rewritten to assert the
right one and to state why the two sides are not mirrors.

**Not changed, and why.** The `snapAux` activation-allowance pin (flagged medium/revise) is
sound: `snapAux` is written per-kind at intent creation and read only by the matching verifier,
one intent is live at a time, and `_clearIntent()` is `delete intent` — there is no collision.
The `settle` access-control, keeper-sampling-loop and `cancelExit` items remain open follow-ups
as listed above; they are behavioural questions, not defects to revert.
