# AUDIT-2026-07-25 — full security audit of the working tree (product pools + structural leverage)

**Date:** 2026-07-25 · **Target: the WORKING TREE** — HEAD `bea4514` **plus 77 uncommitted paths**, including 4 untracked `src/` files (`B4FactoryVaultCreator.sol`, `B4ProductFactory.sol`, `B4ProductPoolCreator.sol`, `IB4PoolPolicy.sol`) and 11 modified ones (`B4Pool.sol` +461 lines, `B4VaultEngine.sol` +323, `B4Vault.sol`, `B4VaultOps.sol`, `B4VaultStorage.sol`, `B4Factory.sol`, `HalvingOracle.sol`, `Calendar.sol`, `SafeTransfer.sol`, `StructuralLeverage.sol`, `Keeper.sol` +40).
**Baseline:** `forge build` OK (lint warnings only).
**Series:** V3 → V4 → V6 → V8 → this round. The strict Product Pool subsystem (`B4ProductFactory`, `B4ProductPoolCreator`, `penaltyEscrow`/`escrowHeld`/sleeves, `IB4PoolPolicy`) is **entirely new since AUDIT-V8** and has never been audited. `Calendar.depositOpen` was **deleted** this round — deposits now enter throughout the cycle. That deletion is the enabling condition for the highest-severity finding below.

## Method

Twelve independent hunt dimensions (access-control, async-engine, accounting, pool, oracle/cross-chain, calendar, math, venue, structural, economic, dos-liveness, external-calls) plus a completeness critic that enumerated every `external`/`public` entrypoint in `src/` and re-read the full uncommitted diff. Every candidate went through a **refuter** (an independent pass whose job was to kill it) and, for medium-and-above, a **3-lens adversarial pass** (exploitability / invariant-and-conservation / existing-defenses-and-coverage). Findings that survived all four are reported here; findings that died are in the appendix so a future round does not re-spend the effort.

Line numbers in this report were re-verified against the files on disk at write time, not copied from the hunt notes.

**What this method does NOT establish.** Static reasoning plus local mock execution only. No funded-network execution, no formal verification, no differential fuzzing against the live venue. Several dimensions built passing Foundry PoCs in rsync'd scratchpad copies of the tree; those were discarded.

**One exception, added after the hunt:** C-1 now carries a committed, passing exploit —
`test/unit/AuditC1_JitWeight.t.sol` — that runs the full attack against the real contracts
and measures the payoff ($676 cost, $833,333 taken). It is the only file this audit added to
the repository; **no `src/` file was modified**. Every *other* claim below rests on a named
function, a named reachable state and a quoted line, not on a committed test — that is a real
limit, and C-2 in particular deserves the same treatment before anything is fixed.

## Verdict

**2 Critical, 4 High, 3 Medium, 6 Low.** The async engine's core discipline (measured deltas, exact-complement resends, idle-gated valuation) holds up under sustained attack — the classes that killed earlier rounds are genuinely closed. The new risk has moved exactly where the code changed: **the pool's weight/distribution layer and the new product-sleeve escrow**, neither of which has a numbered invariant with traceability coverage. `INVARIANTS.md`'s table stops at row 18; **SECURITY_MODEL §2 invariant 19 has no row at all**, and the two Criticals attack properties that no §2 invariant asserts. Both Criticals are permissionless, capital-recyclable, and drain the shared reward basket rather than any vault's principal.

This code is not ready for an external audit until the two Criticals are fixed and the weight layer gets an invariant.

---

## Remediation status (updated after the fix round — see `REMEDIATION-2026-07-25.md`)

Suite: **395 passing, 0 failing** (was 380). Every fix carries a fail-before/pass-after regression.

| id | status |
|---|---|
| **C-1** | **Fixed** — but *not* as this report proposed. Root cause restated below. |
| **C-2** | **Fixed** — completion no longer keys on an out-token increase. |
| **H-2** | **Fixed** — hold on a dead feed, as an early return in `_planPerpStep`. |
| **H-3** | **Fixed** — guards on both ledger-writing paths + a `cancelExit` escape. |
| M-1, M-2, L-3, L-5 | **Fixed.** |
| L-6 | **Partly fixed** — `_finalizeExit` now returns `bool` and `_planExitStep` propagates it. |
| **H-1**, M-3, L-2 | **Fixed** after the EIP-170 refactor that unblocked them. |
| **H-4** | **Fixed** — STRUCTURAL-STATE-MACHINE §3 row PM5 settles the anchor normatively (`floor`). |
| L-1 | **Withdrawn** — its premise was a block-listed sleeve address; that is not the protocol's problem, and a catch-and-divert would turn a transient oracle outage into permanent misrouting. |
| L-4 | Deferred (fires only under a DIR-denominated activation fee — a funded gate). |

**C-1's root cause was misdiagnosed here.** This report frames it as a stale *lock* and proposes
a deposit-side rule. Three independent critics refuted that, and a patch implementing it was
measured to *create* a cheaper attack (a free, repeatable weight mine via the live-priced
`_finalizeExit`) while leaving two full-payoff paths open — the USDC leg, which the permissionless
crank rotates into the directional asset, and the pre-`lockPrices` sub-window.

The actual defect: `_navWad` reads composition **at call time** while the price was fixed
**earlier**, so *any* composition change inside the window is measured against a stale reference —
and at a settlement point the calendar **mandates** one (`targetAt` is 0 there and ramps
immediately after). No deposit-side rule can close it, because the crank reaches the same window
and never touches the entry ledger. The fix is a single price basis: settle at the live price.

**Half B (weight survives a full exit) is downgraded** from a Critical enabler to a product
decision: with C-1 closed it needs real capital, real exposure and real profit across a real
interval. What remains is an ordering inconsistency, recorded in `SECURITY_MODEL.md` §3.

**Two findings are withdrawn.** A zero operator rate is not a defect — the virtual fee is still
computed, and understating profit is self-punishing at any rate. Time-in-interval weighting is not
a missing control — it would contradict REQUIREMENTS §5.6 by rewarding tenure over performance;
profit is already time-weighted by construction.

**New finding from the fix round: the codebase is at the EIP-170 wall.** `B4VaultOps` and
`B4ProductPoolCreator` sit within ~100 and ~40 bytes of the limit, and — not noted anywhere before —
**`B4Pool`'s bytecode is embedded in `B4ProductPoolCreator`**, so `B4Pool`'s apparent 8 KB of
headroom is illusory: any pool-side change consumes the creator's ~40 bytes. A correct, tested H-1
fix was written and had to be reverted for exactly this reason. `Eip170Sizes.t.sol` now guards
every deployed contract and prints headroom; the previous guard covered one contract.

---

## Summary of surviving findings

| id | sev | site | one-line |
|---|---|---|---|
| **C-1** | Critical | `src/core/B4VaultOps.sol:92-96` + `src/core/B4Vault.sol:130` + `src/core/B4Pool.sol:549` | Settle values the vault's *current* composition at the interval's *locked* price while `deposit` books entry at the *live* price, and nothing qualifies weight by time-in-interval or revokes it on exit — a clone created after the basket is public mints unbounded pool weight for gas and exits free in the same transaction. |
| **C-2** | Critical | `src/core/B4VaultEngine.sol:522` | `_verifySpotOrder` completes on an INCREASE of the destination Core balance; 1 wei donated while the IOC is still queued clears the intent with zero accounting, leaving books > assets and then a permanently unsatisfiable Return. |
| **H-1** | High | `src/core/B4Pool.sol:666` | `capturePenalty()` escrows the pool's ENTIRE unattributed balance into the *caller's* product sleeve, not the receipt that exit produced — a zero-cost dust exit reroutes realised sleeve capital and donations into a leveraged sleeve of its choosing. |
| **H-2** | High | `src/core/B4VaultEngine.sol:903` | A zero spot-price read is folded into the `structural` predicate, so a spot-feed outage silently re-sizes a HELD structural perp by the flat-φ rule and force-closes most of it. |
| **H-3** | High | `src/core/B4VaultOps.sol:240` + `src/core/B4Vault.sol:130` | The two ledger-WRITING consumers of `_livePxWad()` have no zero-price guard, unlike the five order-emission/pool consumers that do; a zero read burns an exit share paying nothing and/or books a deposit at basis 0, then taxes principal and mints phantom pool weight. |
| **H-4** | High | `src/core/B4VaultEngine.sol:1088` | The L-halving branch passes the pool's `cap` (the still-forming post-halving low) into `longStop`'s delta-anchor slot instead of the 62-window bottom now sitting in `floor`, sizing a flat Pro Max long at up to venue-max leverage. |
| **M-1** | Medium | `src/core/B4VaultEngine.sol:577` | `_verifyReturn`'s post-timeout re-clamp can set `intent.amount = 0`; the completion predicate is then unsatisfiable forever and every idle-gated escape dies with it. The three sibling legs all carry the zero-clear guard this one omits. |
| **M-2** | Medium | `src/core/B4VaultEngine.sol:1027` | The `marginNeedWad == 0` branch reclassifies only the CORE margin bucket back to rotation; `usdcMarginEvm` has no counterpart, so exit-created margin is invisible to the planner for the whole zero-perp span. |
| **M-3** | Medium | `src/core/B4Pool.sol:416` | Incomplete V8-M-2: the peak density gate counts samples but does not gate the VALUE ratchet, so one print above the true high becomes a density-CONFIRMED peak and mis-sizes every short next cycle. |
| **L-1** | Low | `src/core/B4ProductPoolCreator.sol:69` + `src/core/B4Pool.sol:18` | Sleeves are owned by the pool, and the pool exposes no forwarder to the vault's `onlyOwner` recovery entrypoints — every surplus class a sleeve accrues is permanently unrecoverable. |
| **L-2** | Low | `src/periphery/Keeper.sol:20` | `B4Pool.sampleAnchor` has zero callers in `src/`; the anchor ratchet's only documented safety mechanism (competitive honest sampling) is unimplemented. |
| **L-3** | Low | `src/core/B4VaultEngine.sol:919` | `_perpTargetMargin` divides by a LIVE `g` while using a FROZEN stop with no `g != 0` guard on that branch; a legacy-pool policy change to a zero-fall pair while holding a short makes `crank()` revert until the owner intervenes. |
| **L-4** | Low | `src/core/B4VaultEngine.sol:487` | The first-credit activation allowance is re-derived at the LIVE price every poll, so a fee already deducted at credit-time price can permanently exceed the threshold. |
| **L-5** | Low | `src/core/B4Vault.sol:65` | `slippageBps` is validated only from above; a vault created at 0 emits IOCs at the mid that never cross, permanently, and the parameter is immutable. |
| **L-6** | Low | `src/core/B4VaultOps.sol:197` | The V8-L-1 zero-mark guard was added inside `_startPerpOrder`, but that helper returns `void` and both callers `return true` — the planner reports progress with no state change (A13). |

---

# Critical

## C-1 — Just-in-time checkpoint weight: post-lock deposits mint unbounded pool weight, and pool-side weight survives a full exit

**Sites:** `src/core/B4VaultOps.sol:92-96` (consumption) · `src/core/B4Vault.sol:130` (origin) · `src/core/B4Pool.sol:549-559` (admission) · `src/core/B4VaultOps.sol:275` (the exit scaling that does *not* reach the pool)

This is one defect with two independent halves. Either half alone is exploitable; together they remove both the capital requirement and the risk.

### Half A — the price-basis mismatch

`B4Vault.deposit` books new principal at the LIVE spot price:

```solidity
127:        if (dirAmount > 0) {
128:            uint256 received = _pull(_dir.evmToken, dirAmount);
129:            dirEvm += received;
130:            valueWad += Phi.wmul(_toWad(received, _dir.evmDecimals), _livePxWad());
131:        }
...
141:        entryLedgerWad += valueWad;
```

`opsSettle` values that same principal at the interval's LOCKED checkpoint price:

```solidity
92:        uint256 pxWad = IB4PoolVault(pool).lockedPxWad(intervalId, _dirAssetIndex);
93:        // Idle ⇒ every in-flight leg has credited its bucket; NAV is exact.
94:        uint256 nav = _navWad(pxWad);
95:        uint256 e = entryLedgerWad;
96:        uint256 profit = nav > e ? nav - e : 0;
```

`_navWad` → `_strategyValueWad` (`B4VaultEngine.sol:200-206`) reads `dirEvm + coreDirWei` **at call time** and multiplies by the passed price. It reads composition *now* and price *then*. Nothing anywhere records the composition as of `pointTime`; `B4VaultStorage` has no deposit timestamp, and `opsSettle` destructures `intervalInfo` as `(, uint64 lockedAt,,)` — it discards `pointTime` and never compares `lockedAt` to anything (`grep -n lockedAt src/` shows it is used only as a boolean).

So directional capital deposited between `lockPrices(id)` and `reportDeadline(id)` produces `profit = size · (lockedPx − livePx)` that no capital ever experienced, and `FEE_F` of it (4.5085%) becomes `rewardBaseWad` → `reportWeight`.

### Half B — no participation qualification, and weight is never revoked

`B4Pool.reportWeight` accepts any registered vault with no age, stake or membership-at-`pointTime` test:

```solidity
549:    function reportWeight(uint256 id, uint256 weight) external {
550:        if (!isVault[msg.sender]) revert NotAVault();
551:        if (weight == 0) revert ZeroWeight();
552:        Interval storage it = _interval(id);
553:        if (it.lockedAt == 0) revert NotLocked();
554:        if (block.timestamp > reportDeadline(id)) revert ReportWindowClosed();
555:        if (it.weightOf[msg.sender] != 0) revert AlreadyReported();
556:        it.weightOf[msg.sender] = weight;
557:        it.totalWeight += weight;
```

`AlreadyReported` is **per vault**. `_registerVault` records no join time. And a full exit scales only the *vault-side* accumulator — `_finalizeExit` at `B4VaultOps.sol:275` computes `rewardBaseWad = Phi.wmul(rewardBaseWad + Phi.wmul(clientShare, x), keep)` with `keep == 0` — while `it.weightOf[id][vault]` and `it.totalWeight` in `B4Pool` are **never decremented anywhere** (writes occur only at `B4Pool.sol:556-557`; there is no delete, no unwind, no pool-side exit notification). An emptied, fully-exited clone keeps its full claim and collects days later.

### Failure scenario

The calendar guarantees the exit is free. `Calendar.nextSettlementPoint` returns `P − H` and `T + H`; `zoneAt` (`Calendar.sol:79-87`) puts `[P−H, P)` in `OpeningFall` and `[T+H, T+W)` in `OpeningGrowth`, both accepted by `freeExit` (`Calendar.sol:128-133`). `reportDeadline = pointTime + SNAPSHOT_WINDOW(24h) + REPORT_WINDOW(2d)` = `pointTime + 3 days`, and `H = 10 days`. **The entire 3-day snapshot-plus-report window sits inside a 10-day free-exit zone at both settlement points, by construction.**

1. `pool.advance()` materializes interval `id`; `bucket[i]` — up to ~1.2 years of accumulated exit penalties — becomes publicly readable via `bucketOf`. The attacker sizes the attack against a known prize.
2. Anyone (including the attacker) calls the permissionless `pool.lockPrices(id)` inside the 24h window, fixing `lockedPx`. The attacker may pick the window's high.
3. At any instant in the following ≤3 days where spot prints below `lockedPx`, one transaction loops K times: `B4ProductFactory.createVault(pool, dirHash, strategy, WAD, slip, FeeRoute(0,0,0,0))` → `deposit(Q, 0)` → `settle(id)` → `initiateExit(WAD)` → `crank()`.
   - Every `opsSettle` gate passes on a fresh clone: `exitShareWad == 0`; `_requireIdle()` (a clone that never cranked has `intent.kind == None`); `lastSettledPlusOne == 0` so `AlreadySettled` cannot fire; `pos.szi == 0` so the `WrongSignPerp` gate at `:86-89` is skipped even for a leveraged product; `operatorCut == 0` (a `FeeRoute(0,0,0,0)` is accepted by `_validateRoute` — the `operatorBps == 0` revert at `B4Vault.sol:82` is inside the `referrer != address(0)` branch only) so the `FeeNotRepatriated` gate at `:108` is skipped entirely and `clientShare == virtualFee` in full.
   - `_planExitStep` (`B4VaultOps.sol:194-222`) walks `pos.szi`, `pendingHarvest6`, `perpMargin6`, `coreUsdcRotatedWei`, `coreUsdcMarginWei`, `coreDirWei` — all storage-default zero on a never-synced clone — and falls straight through to `_finalizeExit()` in ONE crank. `s.free` is true, `ocx = 0`, so `ownerWad == grossWad` and `_payBucket` returns 100% of `dirEvm`.
4. The same stake funds every loop. After `reportDeadline`, `pool.claimFor(id, vault_k)` pays `nominal = Phi.mulDiv(it.bucket[i], w, wTotal)` (`B4Pool.sol:580`) to `IB4VaultOwner(vault).owner()` — the attacker — for **every asset in the basket**.

Minted weight is `K · FEE_F · Q · (lockedPx − livePx)`. Q is recyclable (so flash-loanable, and market-risk-free because deposit and exit are the same transaction), K is bounded only by gas over a 3-day window, and the price gap is a free option: if it never appears, the attacker simply does not settle and loses nothing.

**Honest bound.** No vault's principal is reachable. The books stay balanced — `sum(nominal) <= bucket[i]` holds, `balance >= liability` holds, so §2 invariants 3, 10 and 11 all survive to the wei. What breaks is the *mapping from weight to economic contribution*: the entire interval basket — 11.8034% (`Phi.EXIT_Q`) of the gross NAV of every non-free exit, carved out of those users' own capital and accumulated over ~0.94–1.5 years — is redirected to a party with zero exposure. That is a pool distribution error and a direct user-to-user transfer, both explicitly in scope.

**Two-sided harm, no attacker required.** The mirror case needs no adversary: an honest owner depositing inside the window while `livePx > lockedPx` books a phantom LOSS, and `opsSettle:114` then unconditionally re-anchors `entryLedgerWad = nav - paidVal`, silently writing their basis *down* below what they actually paid. At the next checkpoint they pay the performance fee on price recovery they never earned.

### Proof of concept — committed and passing

Unlike the rest of this report, C-1 is not left at static reasoning. `test/unit/AuditC1_JitWeight.t.sol`
runs the attack end-to-end against the real contracts through the standard `VaultTestBase`
fixture (no mocks beyond the venue shim every test uses):

1. An honest Mini vault deposits 1 BTC at $100k and holds it for the interval; spot rises to $110k.
2. The basket accrues $1,000,000. The interval materializes and `lockPrices` fixes $110k.
3. The honest vault settles on a **real** $10k gain → weight `315.59`.
4. Spot falls to $60k. A fresh clone deposits 1 BTC (entry ledger `60_000e18`, asserted) and
   settles the *same* interval → NAV is priced at the locked $110k → **$50k of profit that
   never existed** → weight `1577.97`, exactly `clientShare(FEE_F x $50k)`.
5. The clone exits in full inside the same window with **no exit penalty**, then claims.

Measured result:

| quantity | value |
|---|---|
| attacker weight / honest weight | `1577.97` / `315.59` — **5:1** |
| attacker cost (in-kind operator fee on the phantom profit) | **$676.27** |
| taken from the shared basket | **$833,333.33** of $1,000,000 |

The attack is not free — the operator's 30% cut of `FEE_F x $50k` is a real in-kind cost — but
the payoff exceeds it by **~1,230x**, from a single vault with a single BTC and zero market
exposure. The report's `K`-fold capital recycling is therefore an amplifier, not a requirement.

### Invariant / hazard broken

`spec/HAZARDS.md` B4 verbatim: *"A deposit adds its current value to the interval entry ledger **so new principal cannot read as profit**."* The implementation satisfies the letter ("current value") and inverts the purpose. `spec/SPECIFICATION.md:87` mandates the same defective wording, so this is a **spec-level** defect, not only an implementation slip. `SPECIFICATION.md` §8 (`profit = max(L−E,0)`) computes L and E on two different price bases. §9's anti-duplication rule ("repeated partial exits … MUST NOT create or duplicate reward weight") is enforced only on the vault-side accumulator and is sidestepped entirely by cloning.

No SECURITY_MODEL §2 invariant asserts weight integrity. That absence is the root cause of eight rounds of survival.

### Regression test

**None exists, and the nearest test manufactures false assurance.** `test/unit/Settle.t.sol:69 test_settle_uses_checkpoint_price_not_live` deposits BEFORE the lock and then moves the price UP — the direction that protects the protocol. Across all 40 `lockPrices` call sites in `test/`, no test deposits after the lock. `test_repeated_partial_exits_no_weight_duplication` (`Exit.t.sol:147`), the suite's only weight-minting regression, asserts on `v.rewardBaseWad()` and never touches `pool.weightOf` — it pins the wrong variable to catch this class. The stateful campaign has no `createVault` handler and no invariant that reads `weightOf`, `totalWeight`, `rewardBaseWad` or `entryLedgerWad`.

**Write:** (a) `test_postlock_deposit_earns_no_weight` — lock at 120k, deposit at 118k inside the report window, settle, assert `pool.weightOf(id, v) == 0`; (b) `test_recycled_clones_cannot_outweigh_a_full_interval_holder` — one stake through K clones vs one honest holder across a real interval; (c) `test_fully_exited_vault_holds_no_pool_weight`; (d) a campaign invariant `sum(weightOf) backed by realized profit`.

### Fix

Make the checkpoint valuation see the checkpoint composition, and qualify the weight.

1. **Price basis:** when the pool's latest interval has `lockedAt != 0` and this vault has not settled it (`intervalId + 1 > lastSettledPlusOne`), `deposit` must credit `entryLedgerWad` using `IB4PoolVault(pool).lockedPxWad(latestId, _dirAssetIndex)` instead of `_livePxWad()`. Equivalently, carry a `postLockDeltaWad` and add it to BOTH `nav` and `e` in `opsSettle` so it cancels exactly. Do **not** use the blunt "reject deposits in the window" variant — it contradicts `SPECIFICATION.md:79` ("Deposits MAY enter throughout the cycle").
2. **Participation:** require that a vault's first deposit predate the interval's `pointTime` before its weight counts, or scale reported weight by `min(1, timeInInterval / intervalLength)`. `opsSettle` already reads `lockedAt` at `B4VaultOps.sol:79` and uses it only as a boolean; the vault records no deposit timestamp at all, so this needs one new storage word.
3. **Revocation:** scale or delete `it.weightOf[id][vault]` and `it.totalWeight` when a vault fully exits before that interval's claims open — or gate `claimFor` on the vault still holding what it reported. Without this, (1) and (2) still leave the clone-recycling channel open on any future basis skew.

---

## C-2 — `_verifySpotOrder` completes on the externally-toppable destination balance

**Site:** `src/core/B4VaultEngine.sol:522` (the condition; `:521` computes the value)

```solidity
519:        uint64 curIn = _spotBal(inToken);
520:        uint64 curOut = _spotBal(outToken);
521:        uint64 inDelta = intent.snapSrcWei > curIn ? intent.snapSrcWei - curIn : 0;
522:        uint64 outDelta = curOut > intent.snapAux ? curOut - intent.snapAux : 0;
523:        if (inDelta == 0 && outDelta == 0) {
524:            if (block.timestamp < intent.createdAt + RESEND_TIMEOUT) return false;
525:            // IOC observed no fill: nothing to account; planner may issue a fresh order.
526:            emit IntentCleared(IntentKind.SpotOrder);
527:            _clearIntent();
528:            return true;
529:        }
```

*(the `if` is at :523 on disk; `outDelta` is computed at :522 — both are quoted above so the site is unambiguous.)*

`outDelta` is an **increase of the destination Core spot balance**. `spec/HAZARDS.md` A2 states the rule with the opposite sign, verbatim: *"The Core spot balance is decreased only by our action (external transfers can only ADD). A spot NET-DECREASE reliably proves our transfer executed."* `spec/SECURITY_MODEL.md` §1 lists "direct EVM or Core token transfers to the vault/account" as an untrusted capability that MUST be treated adversarially in async completion.

Because the only branch that consults `RESEND_TIMEOUT` is gated on `inDelta == 0 && outDelta == 0`, any non-zero `outDelta` with `inDelta == 0` falls into the accounting branch, which for a sell computes `capUsdWad = wmul(toWad(0), pxWad) = 0` ⇒ `capWei = 0` ⇒ `credit = min(1, 0) = 0`, does `coreDirWei -= _min64(0, coreDirWei)` (a no-op), and then `_clearIntent()` — at **any** time inside the timeout.

**This is the only completion predicate in the engine with no amount threshold.** Every sibling thresholds the unreliable direction at the full amount, which is exactly what makes the documented A11 residual "attacker-funded": `_verifyFund` requires `delta >= threshold` (`:490`); `_verifyFromPerp` requires `cur >= snapSrcWei + weiNeeded`; `_verifyToPerp` and `_verifyReturn` require a self-caused net-decrease. One wei clears this one.

### Failure scenario

The vault holds 1 BTC as `coreDirWei = 1e8`. A crank emits a sell IOC via CoreWriter; `_startSpotOrder` snapshots `snapSrcWei`/`snapAux` **before** emission, and the action sits in the venue's queue.

1. An attacker sends 1 wei of USDC to the vault's account natively on HyperCore (an L1 spot transfer, not behind the CoreWriter queue, so it lands first).
2. The attacker calls the permissionless `crank()` (`B4Vault.sol:156`, no cooldown, verify-only while an intent pends — so the attacker cannot be front-run into a different action). `_verifySpotOrder` reads `inDelta = 0, outDelta = 1`, skips the timeout branch, credits 0, clears the intent.
3. The IOC then executes. Real Core BTC → 0, real Core USDC += the proceeds, while `coreDirWei` still reads `1e8`. **Books now exceed assets** — precisely the `"dir core phantom"` condition the campaign's own `_checkBooks` asserts (`test/invariant/Protocol.invariant.t.sol:362`).

Nothing repairs it: `_reconcile` (`B4VaultEngine.sol:234-245`) writes down only `perpMargin6`; no code anywhere clamps a Core bucket to `_spotBal`; `opsRecoverCoreSpot` reverts `NothingToRecover` when `bal <= recorded`. Three consequences follow:

- **Freeze.** The next in-band repatriation (`B4VaultEngine.sol:853`) or exit (`B4VaultOps.sol:218`) calls `_startReturn(true, Generic, coreDirWei)` against a live balance of 0. `_startReturn` pins `intent.snapSrcWei = _spotBal(...) = 0`, so `decreased = cur < 0` is **structurally unsatisfiable on a uint64, forever** — and the timeout re-clamp (M-1) then pins `intent.amount = 0` and re-emits a zero-value `spotSend` every hour. `emergencyClearRecovery` rejects `ReturnDir`/`ReturnUsdc` (`B4Vault.sol:212-221`); `opsSettle`, `opsRecoverEvm`, `opsRecoverCoreSpot` and `opsRecoverPerpSurplus` all gate on idle. A later donation of real BTC does not heal it (it only raises `cur`).
- **Untaxed extraction.** Before the wedge, the real sale proceeds sit unbooked on Core and are owner-recoverable via `opsRecoverCoreSpot` → `_verifyRecoverSpot` → `d.evmToken.safeTransfer(owner, evmNeeded)` (`B4VaultEngine.sol:728`) with no fee, no `EXIT_Q` penalty and no pool callback — while the phantom `coreDirWei` is still counted in NAV.
- **Serialization break.** The intent clears while an emitted action is still live, so the "at most one live action" premise every other completion proof depends on no longer holds.

### Invariant / hazard broken

§2 invariant 17 ("Async completion/retry keys only on a reliable (self-moved) balance, never on a PnL-driven or **externally-toppable** one") and invariant 4 ("Action success never finalizes accounting; later Core state must prove execution"), plus invariant 18's "never freeze or loss". HAZARDS A2's own closing line — *"(This exact bug — keying on the [externally-toppable] balance — survived three audit rounds.)"* — describes this bug class, relocated to the one verifier that lacks the threshold.

**Not the accepted residual.** `SECURITY_MODEL` §3 accepts only "a `>= amount` external top-up fakes a signal once", bounded to be attacker-funded, recoverable, non-freeze/non-theft, leaving real assets ≥ books. This case is 1 wei against an arbitrarily large order, is not attacker-funded, leaves assets < books, and is a freeze — the negation of every clause.

### Regression test

**None, and the coverage gap is structural.** All three spot-order tests (`AsyncEngine.t.sol:283/295/309`) call `hub.setAuto(true, true, true)`, and `MockCore.enqueueAction` executes synchronously inside `_startSpotOrder`, so `inDelta > 0` always holds and `(inDelta == 0 && outDelta > 0)` is unreachable by construction. The stateful campaign has the right adversary (`advCoreTopUp`) and the right assertion (`_checkBooks`, `"dir core phantom"`) but inherits `VenueTestBase.sol:56`'s `hub.setAuto(true,true,true)` and never overrides it, so the emitted-but-unexecuted window is collapsed to zero. `test_R7_destination_topUp_fakes_completion_once_benign` — the test `INVARIANTS.md` row 17 cites for exactly this property — is a **FromPerp** test with a `>= amount` top-up, which is why its "benign, capped" conclusion is true there and does not transfer. `IntentKind.SpotOrder` has zero invariant-17 coverage.

**Write:** with `hub.setAuto(false, true, true)`: start a sell `startSpotOrder(false, 1e8)`, `hub.coreTopUp(v, USDC_CORE, 1)`, assert `verify() == false` and the intent still pending; then `executeActions()` and assert `coreDirWei == 0` and the credit measured. Add the buy-leg twin. Additionally, flip the invariant campaign to async mode for at least one profile — as configured it cannot observe the entire hazard class A exists for.

### Fix

Require a measured `inDelta > 0` before accounting **or** clearing. Fold `inDelta == 0` into the existing no-delta/timeout branch:

```solidity
if (inDelta == 0) {
    if (block.timestamp < intent.createdAt + RESEND_TIMEOUT) return false;
    emit IntentCleared(IntentKind.SpotOrder);
    _clearIntent();
    return true;
}
```

`outDelta` should be used only to cap the credit, never to prove execution. Fix M-1 alongside so no residual books>assets can ever wedge the return leg.

---

# High

## H-1 — `capturePenalty()` escrows the pool's entire unattributed balance, not the exit's receipt

**Site:** `src/core/B4Pool.sol:666-671` (the credit) · `:706-712` (`_unaccounted`) · `src/core/B4VaultOps.sol:295` (the argument-less call) · `src/core/B4Pool.sol:306-316` vs `src/core/B4Vault.sol:156` (the sleeve leak)

```solidity
665:            if (!ok) continue;
666:            uint256 delta = _unaccounted(token, bal);
667:            if (delta != 0) {
668:                if (i == 0 || i == dirAssetIndex) {
669:                    penaltyEscrow[policy][dirAssetIndex][i] += delta;
670:                    escrowHeld[token] += delta;
```

with

```solidity
706:    function _unaccounted(address token, uint256 bal) internal view returns (uint256) {
707:        uint256 claimable = liability[token];
708:        if (bal <= claimable) return 0;
709:        uint256 aboveClaimable = bal - claimable;
710:        uint256 held = escrowHeld[token];
711:        return aboveClaimable > held ? aboveClaimable - held : 0;
712:    }
```

`bal` is `_safeBalanceOf(address(this))` — the pool's **whole** balance. `_finalizeExit` computes the exact per-token `toPool` in `_payBucket` (`B4VaultOps.sol:317 _payOut(token, pool, toPool)`) and then calls `capturePenalty()` **with no arguments** (`B4VaultOps.sol:295`). The caller's identity selects only the escrow *bucket* (`policyOfVault[msg.sender]`, `dirIndexOfVault[msg.sender]`), never the *amount*.

The root cause is sharper than "missing parameter": `_unaccounted` is shared by two routes with different safety requirements, and its own comment claims *"The difference is the only safe measured receipt available for either capture route."* That equivalence is sound for `capture()`/`_captureToAccruing()`, whose destination is the common `accruing` basket and is caller-independent. It is **invalid** for `capturePenalty()`, whose destination is caller-keyed.

### The cost is zero, and the bait is reusable

`_finalizeExit` gates the capture on `if (s.poolWad > 0)` — a WAD quantity derived from the exiting vault's own NAV — while the physical transfer happens per-bucket under `_payBucket`'s `uint256 out = Phi.wmul(bucket, x); if (out == 0) return bucket;`. With a 100e6 vault and `initiateExit(1e6)` (a 1e-12 share): `grossWad > 0`, `poolWad > 0`, but `out = wmul(100e6, 1e6) = 0`, so **not one token leaves the vault** and `capturePenalty()` still fires and sweeps everything unattributed. `exitShareWad` resets to 0, so the same bait vault re-arms forever with no new deposit. Cost: gas.

### Where the unattributed balance comes from

Three real sources, and in a strict Product Pool they are the pool's *entire* distribution inflow (settle moves no tokens to the pool; only `capture()`, `capturePenalty()` and `crankSleeve` book anything):

1. **Sleeve returns finalized outside `crankSleeve`.** `crankSleeve` (`B4Pool.sol:786-787`) is the ONLY path that pairs the sleeve crank with `_captureToAccruing()`, and it captures *after* the call returns. `B4Vault.crank()` (`B4Vault.sol:156`) is `external nonReentrant` with no owner gate, so anyone can drive the sleeve to `_finalizeExit` directly. The sleeve cannot self-account: `registerSleeve` (`B4Pool.sol:306-316`) sets `isSleeve` and **never** `isVault`, so the sleeve's own `try IB4PoolVault(pool).capturePenalty() {} catch {}` always reverts `NotAVault` into the catch — and in a free-window finalize `s.poolWad == 0` so it is not even attempted. Either way the sleeve's whole realised NAV lands at the pool (`owner == pool`, per `B4ProductPoolCreator.sol:69-70`) with `liability` and `escrowHeld` untouched.
2. **Plain donations** of the settlement token or the exiting vault's own directional token. No race with anything.
3. **`claimDeferred(pool, token)` deliveries** — `opsClaimDeferred` does a bare `safeTransfer` with no capture call.

### Failure scenario (aggregate pool, mask 15)

One transaction from an attacker contract, in a non-free window (free windows are ~60 of ~1460 days, so this is ~96% of the calendar):

1. `B4Vault(proSleeve).crank()` → the Pro sleeve's `_finalizeExit` sends its whole realised NAV to `owner == pool`; its own `capturePenalty()` reverts `NotAVault` and is swallowed. The capital sits unattributed.
2. `baitVault.initiateExit(1e6); baitVault.crank()` → `_planExitStep` falls straight to `_finalizeExit` on a never-synced clone; `s.poolWad > 0` fires `pool.capturePenalty()`, which books the **whole** stranded return into `penaltyEscrow[4][dir][0]` (Pro Max — the attacker's product, chosen at `createVault`).
3. The permissionless `pool.foldPenalty(4, dir)` then deposits it into the Pro Max sleeve, which opens a φ-leveraged perp with it. (The attacker need not even call this — `Keeper.crank` runs `_crankProductSleeves` first on its next run and completes the attack.)

Both legs are in one transaction, so no keeper `capture()`/`crankSleeve()` can interleave. The donation and deferred-delivery variants need no race at all.

### Invariant / hazard broken

`spec/SECURITY_MODEL.md` §2 **invariant 19**, verbatim at `:55-59`, broken on three of its four clauses:

> *"a non-free exit's **measured penalty** can fund only its immutable matching `(product, directional asset)` sleeve. Live sleeve escrow … joins ordinary distribution only after that sleeve's free-window exit. **No caller can choose another strategy, recipient, or a live cross-product transfer.**"*

The credited quantity is not the measured penalty; capital that already completed a free-window sleeve exit is re-escrowed into a live sleeve; and a $0-cost unrelated caller performs exactly a live Pro→Pro Max transfer. The one clause that IS honored ("a different whitelisted token … is ordinary donation inventory") is precisely the only one the suite pins. Also `SPECIFICATION.md:240` ("MUST route a non-free exit's **measured pool receipt**") and `:257`/`:262` ("a donation becomes inventory"; sleeve capital joins `accruing` "only after the sleeve's free-window exit").

**Honest bound.** Not theft, not insolvency, not a permanent freeze of aggregate value. The capital stays pool-owned, `bal == liability + escrowHeld` holds exactly after every capture, existing nominal claims still pay in full (`claimFor`'s `available = bal − escrowHeld` is unaffected because both terms rise together), and every reachable `(policy, dir)` escrow key has a deployed sleeve, so `foldPenalty → free-window initiateSleeveExit → crankSleeve` always returns it to `accruing`. §2 invariants 3, 10 and 11 all survive.

What earns High: the trigger is **zero-cost and infinitely repeatable**; a $0 stranger chooses which leveraged product the common basket is committed to; and the deferral is structural rather than incidental — `capturePenalty` is reachable only when `s.free == false`, while `initiateSleeveExit` reverts `NotFreeExit` outside a free window, so **every sweep necessarily lands at a moment when the only release path is closed**. Deferral is then ~0.94–3 years per cycle and repeatable at each window. And the loss to a specific cohort is permanent: a full exit sets `rewardBaseWad` to 0 (`keep == 0`), `reportWeight` reverts `ZeroWeight`, so every claimant who exits before the deferred checkpoint forfeits their entire share of the swept basket forever. On top sits deterministic deadweight — a forced sleeve round trip at `POOL_SLIPPAGE_BPS = 100` each way plus Core fees.

### Regression test

**None, and the nearest test manufactures assurance.** `test/unit/ProductPools.t.sol:351 test_non_matching_whitelisted_token_stays_generic_inventory` mints **UETH** (`:359`, asset index 2, the NON-matching token) and asserts `penaltyEscrow(1, DIR, 2) == 0` — it exercises only the `else` branch at `:672-679`, the one that is correct. It is the sole row `INVARIANTS.md:45` cites for strict product escrow. `test_aggregate_keeps_pro_penalty_in_pro_sleeve_until_free_window_exit` asserts `penaltyEscrow(4, DIR, 0) == 0`, but drives every sleeve step through `p.crankSleeve` (the defended path) and never creates a second-product vault. Two backtest assertions have the *right oracle* — `ClosedPopulation.t.sol:275 assertLe(measuredPenaltyWad, penalty, "in-kind floor cannot exceed exit penalty")` and `PoolClaimFlow.t.sol:98` — but their harnesses call `pool.crankSleeve` on every non-free day, so unaccounted balance is always zero when a vault finalizes. The stateful campaign builds its pool with `factory.createPool(dirs)` (`VaultTestBase.sol:55`), which never calls `configurePolicies`, so `policyMask == 0` and every `capturePenalty` in the entire campaign takes the legacy `_captureToAccruing` branch. `INVARIANTS.md` has **no row 19 at all**.

**Write:** (a) `test_settlement_token_donation_stays_generic_inventory` — the exact mirror of the existing UETH test with `usdc.mint(address(p), donation)`; (b) `test_sleeve_return_via_direct_crank_joins_accruing` — drive a sleeve to finalize with `B4Vault(sleeve).crank()` and assert `accruing(0)` grew, not `penaltyEscrow`; (c) `test_dust_exit_escrows_only_its_own_receipt` — assert `penaltyEscrow` delta `== wmul(gross, EXIT_Q) − operatorCut`; (d) add a strict product pool to the invariant campaign, which today never reaches this branch.

### Fix

1. Pass the receipt. Have `_finalizeExit` hand the exact per-token `toPool` amounts to `capturePenalty(uint256 usdcAmt, uint256 dirAmt)`, credit `min(claimed, _unaccounted(token, bal))` to escrow, and route any residual through `_captureToAccruing()` in the same call.
2. Close the sleeve leak. Give sleeves a pool-side `captureSleeveReturn()` hook called from `_finalizeExit` (or route an `isSleeve` caller inside `capturePenalty` to `_captureToAccruing`), so a sleeve's realised capital is booked in the same transaction as its own finalize regardless of who cranked it. Do **not** try to make `crankSleeve` the only advancement path — `B4Vault.crank()` is permissionless by design and restricting it breaks the liveness model.
3. Gate the capture on a non-zero measured transfer, not on `s.poolWad > 0`.

---

## H-2 — A zero spot-price read re-sizes a HELD structural perp by the flat-φ rule

**Site:** `src/core/B4VaultEngine.sol:903`

```solidity
902:        // margin-control structural. `pool != 0` guards the bare engine harness (flat-φ fallback).
903:        structural = pool != address(0) && pxWad != 0 && (long ? g > Phi.WAD : perpF < 0);
904:        if (structural) {
...
918:            stopWad = perpStopWad;
919:            if (stopWad != 0) marginNeedWad = Phi.mulDiv(_navWad(pxWad), Phi.abs(perpF), g);
920:        } else {
921:            // Non-structural (flat-φ engine harness / a g ≤ 1 leg with no pool): drop any frozen
922:            // stop while flat so it can never leak into a later structural open on this side.
923:            if (szi == 0) perpStopWad = 0;
924:            uint256 ntl = Phi.wmul(v, Phi.abs(perpF));
925:            if (ntl >= MIN_ORDER_USD_WAD) {
926:                marginNeedWad = Phi.mulDiv(ntl, Phi.PHI, uint256(_dir.perpMaxLeverage) * Phi.WAD);
927:            }
928:        }
```

`pxWad != 0` is folded into the **regime selector**, so a zero spot read does not cause a hold — it swaps the sizing law of a live position. `_planPerpStep` has no `pxWad == 0` guard (`:1006` reads it and passes it straight through), unlike `_startSpotOrder` (`:329 if (pxWad == 0) return false; // spot feed down: hold, never revert-loop (H3)`) and `_startPerpOrder` (`:421 if (markWad == 0) return; // perp feed down: hold`). The mark guard at `:1039` does not fire: `perpPxWad` reads `PRECOMPILE_MARK_PX` while `_livePxWad` reads `PRECOMPILE_SPOT_PX` (`CoreReader.sol:43` vs `:51`) — genuinely independent reads on different markets.

**The flat branch is production dead code except at `pxWad == 0`.** `pool` is always set for a factory-created vault (`B4Vault.initialize` makes an external call on it); a short satisfies `perpF < 0` unconditionally; and for a long, `Calendar.decompose` makes `perpF > 0 ⟺ n > 1 ⟹ growthTarget > 1 ⟹ g > Phi.WAD`. So with a held position, the `else` arm — whose own comment calls it "the bare engine harness (flat-φ fallback)" — is reachable in production **if and only if** the spot precompile reads 0.

### Failure scenario

Pro Max mid-ramp. `Calendar.decompose` (`Calendar.sol:120-123`) sets `spot = 0` for any `|n| > 1` or `n < 0`, so the leg is pure perp and `v` (strategy value) is USDC-denominated and **not** suppressed by `pxWad == 0` — this is the load-bearing step. A residual `v > 0` is structural: in the two opening ramps `|perpF| < g` strictly, so `_fundPerpMargin` moves only `nav·|perpF|/g` into margin and the remainder sits in `usdcRotatedEvm`; any deposit or harvest credit creates it too.

One crank while `spotPx` reads 0 and the mark is live: `_planSpotStep` finds `dirValWad == targetValWad == 0` (in band, returns false), `_planPerpStep` runs, `structural = false` **purely because of the price**, `ntl = wmul(v, |perpF|) ≥ $10` so `marginNeedWad != 0`, `_fundPerpMargin` returns false (held margin ≫ flat need), and `szTarget = _szTargetFlat(mark, v, perpF)` — which has **no `absNow` floor**, unlike `_szTargetStructural`'s `if (maxSz < absNow) maxSz = absNow;` (the V8-L-4 fix). `bandUsd = max(bps(max(v, marginNeedWad), 100), $10)` collapses toward the residual, so `diffUsdWad > bandUsd` and the planner emits `_startPerpOrder(!targetLong, absNow − szTarget, true)` — a reduce-only market close of most of the position.

Damage scales **inversely** with the residual: a $500 top-up into a $161.8k Pro Max short drives it to $800 of notional. At full deployment `v == 0` ⇒ `ntl == 0` ⇒ the no-order branch holds, so the bug lives precisely in the partially-deployed state, which is the normal operating state on every calendar ramp and after every deposit.

**The round trip does not restore the position.** `perpStopWad` survives (cleared only at `szi == 0`), so on recovery `_szTargetStructural` re-adds at the live mark against the still-frozen stop: with an in-profit short, `|mark − stop| > |avgEntry − stop|`, so the same margin buys strictly fewer lots. Beyond spread and two taker fills, this permanently destroys structural exposure at an unchanged price. If the close realizes a loss while `szi != 0`, `_reconcile` cannot write `perpMargin6` down (it is strict-flatness gated), so the re-open sizes off overstated margin and the true liquidation sits **closer** to entry than the frozen stop — the over-leverage direction §7b exists to forbid.

### Invariant / hazard broken

`spec/SPECIFICATION.md` §7b: *"**Sized once, then held.** A position MUST be sized when opened or materially re-targeted (entry, deposit, calendar zone change) and MUST NOT be re-sized against a moving NAV or a moving anchor within a zone."* A transient precompile read is none of the three permitted triggers, and the flat branch is exactly the "running NAV-relative target" HAZARDS C5 records as a **rejected** design. Also §2 invariant 18 — the same read produces a HOLD at four other sites and a `revert ZeroPrice()` at three pool sites; here it produces loss. `docs/audits/AUDIT-2026-07-structural-leverage.md`'s redo requirements state that "dir-only / USDC-only degradations MUST be explicit (event or revert), not silent" — this is a silent degradation of a held position's entire sizing law with no event.

### Regression test

**None can exist in the current harness.** The two zero-spot-price planner tests — `AuditV5Fixes.t.sol:138 test_F4_halted_spot_feed_holds_then_recovers` and `V6D_VenueGaps.t.sol:169` — both run on `EngineHarness`, whose `setup()` **never assigns `pool`** (`grep -c "pool" test/utils/EngineHarness.sol` returns **0**). With `pool == address(0)` the first conjunct already forces `structural = false`, so no test in the repo has ever observed `pxWad != 0` change the value of `structural`. `test_F4` additionally sets a spot-only target, so `_planPerpStep` is never entered with a live position. The campaign cannot reach the state either: `movePrice` bounds px to `[20_000e4, 500_000e4]` (`Protocol.invariant.t.sol:86`). The V8-L-7 ghost `_checkLiqPin` is explicitly one-sided (it flags only liquidation *closer* to entry), and a forced reduce moves liquidation *further* — into the direction it deliberately ignores. `StructuralSizing.t.sol` and `V8A_Freeze.t.sol` never degrade a price read at all.

**Write:** on a REAL vault (not `EngineHarness`) mirror `V8A_Freeze.t.sol::test_V8A_held_short_ignores_peak_ratchet_mid_hold`, but set `hub.setSpotPx(SPOT_MKT, 0)` while leaving `setMarkPx` live, deposit a small residual, crank to idle, and assert `szi` and `perpStopWad` are unchanged — for a held short, a held mid-ramp long, and a held in-profit short.

### Fix

Treat a zero directional spot price as HOLD in the perp planner, mirroring `_startSpotOrder`:

```solidity
uint256 pxWad = _livePxWad();
if (pxWad == 0) return false;   // spot feed down: hold (H3)
```

immediately after `B4VaultEngine.sol:1006`, **before** `_perpTargetMargin` is consulted. Keep `pxWad != 0` inside `structural` as defense-in-depth for the flat case (it legitimately prevents freezing a garbage stop off a dead feed while `szi == 0`), but never let it select a sizing rule for a live position. A guard at `:903` alone is insufficient: `_navWad(0)` at `:919` would still misprice any vault holding directional spot.

---

## H-3 — The two ledger-WRITING consumers of `_livePxWad()` have no zero-price guard

**Sites:** `src/core/B4VaultOps.sol:240` (exit finalize) and `src/core/B4Vault.sol:130` (deposit)

```solidity
237:    function _finalizeExit() internal {
238:        uint256 x = exitShareWad;
239:        if (x == 0) revert NoExitPending();
240:        uint256 pxWad = _livePxWad(); // live oracle valuation (decision C2)
241:        uint256 nav = _navWad(pxWad);
...
273:        uint256 keep = Phi.WAD - x;
274:        entryLedgerWad = Phi.wmul(e, keep);
275:        rewardBaseWad = Phi.wmul(rewardBaseWad + Phi.wmul(clientShare, x), keep);
276:        exitShareWad = 0;
...
284:        if (s.grossWad > 0) {
285:            dirEvm = _payBucket(_dir.evmToken, dirEvm, x, s);
```

The ledger writes at `:274-279` are **unconditional and precede** the guarded payment block at `:284`.

`grep` over `src/` finds exactly five zero-price guards: `B4VaultEngine.sol:329` (spot order emission), `:421` (perp order emission), `:510` (activation allowance), and `B4Pool.sol:363`/`:403`/`:432` (`revert ZeroPrice()` on the checkpoint lock and the anchor ratchet). Every one of them guards an *order* or a *pool price*. The two sites that convert tokens into **ledger value** are the only unguarded ones.

### Failure scenario A — exit finalize (permissionless timing)

A Mini or growth-regime B4 vault holds only the directional token (`StrategyMini` is `(WAD, WAD)`; `decompose(1e18)` gives `spot = 1e18, perp = 0`, so it never rotates and `usdcRotatedEvm == usdcMarginEvm == 0` permanently). The owner calls `initiateExit(x)`. `_planExitStep` gates only on `pos.szi`, `pendingHarvest6`, `perpMargin6` and the three Core buckets — **none of which involves price** — before calling `_finalizeExit()`.

Any permissionless `crank()` in a block where the spot precompile returns 0: `nav = _navWad(0) = 0`, `s.grossWad = 0`, so the whole payment block is skipped — **not one token moves** — while `entryLedgerWad = wmul(e, keep)`, `rewardBaseWad = wmul(..., keep)` and `exitShareWad = 0` are committed. For a full exit that leaves `entryLedgerWad == 0` with the tokens still in `dirEvm`.

The `if (s.grossWad > 0)` guard exists only to dodge the `Phi.mulDiv` `DivByZero` inside `_payBucket`'s `mulDiv(out, s.ownerWad, s.grossWad)`. `git show 3a27f1b:src/core/B4VaultOps.sol` shows it present unchanged since the initial release commit — it was never a zero-price fix. It converts what would have been a revert (delayed liveness, already supported since `Keeper.crankVault` try/catches `v.crank()`) into silent consumption of the exit share with no payment.

Consequences, all irreversible: `entryLedgerWad` has exactly three writers (`B4Vault.sol:141`, `B4VaultOps.sol:114`, `:274`) and none restores a lost basis, so at the next valuation `profit = nav − 0` is entirely phantom. `_payOperatorInKind` then transfers real tokens — bounded at `FEE_F × MAX_OPERATOR_BPS = 0.045085 × 0.3819 = 1.7218%` of NAV — and `rewardBaseWad += clientShare` (the remaining 2.79% of NAV) is reported to `B4Pool.reportWeight`, which has no cap. On a $10M vault that is ~$172k to the operator plus ~$279k of unbacked weight diluting every co-resident claim. `opsRecoverEvm` cannot help: `excess = bal − min(dirEvm + deferred, bal) == 0` because the payment block never ran.

There is also a timing amplifier: if the burned crank lands inside a free-exit window and that window closes before the owner re-initiates, the owner loses the free-exit right and pays `EXIT_Q = 11.8%` on the re-exit.

### Failure scenario B — deposit (owner-timed, but weaponizable)

`valueWad += Phi.wmul(x, 0) = 0`, so a directional deposit credits `dirEvm` while `entryLedgerWad` stays flat. `B4Pool.lockPrices` reverts `ZeroPrice` (`:363`), so the checkpoint is guaranteed to lock at a healthy price — that guard is precisely what converts the gap into "profit". The next `settle` sees `profit = full NAV`.

Critically, the route is caller-chosen: `_validateRoute` (`B4Vault.sol:77-89`) accepts `FeeRoute{0,0,0,0}` (the `operatorBps == 0` revert at `:82` is inside the `referrer != address(0)` branch), and `B4Factory`/`B4ProductFactory.createVault` forward it verbatim. With `operatorBps = 0` the depositor pays **nothing** and mints the full `FEE_F = 4.5085%` of principal as permanent pool weight — versus an honest vault, which must realize actual profit to earn the same. So this is not only self-harm; it is a rational (if opportunistic) attack on the shared basket.

### Invariant / hazard broken

§2 invariant 18 ("the worst case of any async/gate path is delayed liveness, never freeze or **loss**") — a gate path the codebase elsewhere treats as HOLD here produces irreversible loss; and `SPECIFICATION.md` §9 (an exit "MUST … pay the same share of each accounted EVM token" — nothing is paid while the share is consumed) and §5 ("Every accepted deposit MUST add its **current value** to the interval entry ledger" — it adds 0 for real value). Value conservation at the vault holds (books never exceed assets, no phantom tokens); the break is redistribution — operator fee levied on principal, and pool weight minted from nothing.

**Not the accepted residual.** `SECURITY_MODEL` §3's C2 accepts valuing exit profit at the LIVE oracle, "economically inert under a deep venue" — a statement about a real market price lacking snapshot protection. It says nothing about treating a **missing** read as a price of zero, which the codebase classifies as a distinct failure mode (D1) and guards at five sites. C4 ("no oracle sanity band") names the 500/50 bps execution envelopes as the defense; those live entirely in order emission and never touch a ledger write.

### Regression test

**None.** `grep -rn "ExitFinalized\|grossWad" test/` returns **zero hits** — no test asserts anything about the exit split struct. `setSpotPx(m, 0)` appears in exactly four places (`B4Pool.t.sol:192`, `AnchorRatchet.t.sol:97`, `AuditV5Fixes.t.sol:138`, `V6D_VenueGaps.t.sol:169`); `Exit.t.sol` never sets a zero price and `grep -rn setActivationFee test/` shows every activation test uses `USDC_CORE`, which is `fixedUsd` and therefore price-independent by construction. This is exactly the incomplete-prior-fix chain: `REPORT.md` F4 → V6-L-1 → V8-L-1 walked the hold-on-zero discipline through spot emission → perp planner → perp exit flatten and stopped at emission. AUDIT-V6's V6-L-9 states the scope explicitly: *"F4 covers the only spot-order choke point."*

Note the exposed population is the suite's own canonical fixture: `Exit.t.sol`'s `_vaultWithProfit()` is `createVault(address(mini)); fundAndDeposit(v, 1e8, 0);` — dir-only, spot-only, zero USDC.

**Write:** (a) `test_exit_finalize_holds_at_zero_spot_price` — pending exit, `hub.setSpotPx(SPOT_MKT, 0)`, crank, assert `exitShareWad` and `entryLedgerWad` unchanged and no tokens moved; (b) `test_deposit_reverts_at_zero_spot_price`; (c) assert the settle-side consequence: no operator fee and `weightOf == 0` after a zero-price event.

### Fix

Read the price once and refuse to write ledger state on a zero:

- `_finalizeExit`: `uint256 pxWad = _livePxWad(); if (pxWad == 0) return;` before any mutation — and propagate the hold, so `_planExitStep` returns **false** rather than reporting progress (see L-6). The exit re-runs on the next crank at a live price: delayed liveness, the documented worst case.
- `deposit`: `uint256 px = _livePxWad(); if (dirAmount > 0) { if (px == 0) revert ZeroPrice(); … }`. Reverting is correct here — the entrypoint is owner-called and freely retryable, unlike the order-emission paths where a revert would risk a resend wedge.

Defensively, also refuse the finalize ledger writes when `nav == 0` while any of `dirEvm | usdcRotatedEvm | usdcMarginEvm` is non-zero: that combination can only mean a mispriced valuation.

---

## H-4 — The L-halving branch feeds the post-halving running low into the delta-anchor slot

**Site:** `src/core/B4VaultEngine.sol:1088`

```solidity
1080:    function _longStopWad(uint256 pxWad) internal view returns (uint256) {
1081:        (uint256 floor_, uint256 cap_) = IB4PoolAnchors(pool).anchors(_dirAssetIndex);
1082:        uint256 t = IHalvingOracle(oracle).timeSinceHalving();
1083:        Calendar.Zone zone = Calendar.zoneAt(t);
1084:        if (zone == Calendar.Zone.OpeningGrowth) {
1085:            return StructuralLeverage.longStop(pxWad, floor_, 0); // L-win: B unknown, live p, anchor Pb
1086:        }
1087:        if (t < Calendar.W && cap_ != 0) {
1088:            return StructuralLeverage.longStop(pxWad, cap_, 0); // L-halving: anchor 62-low, live p_day
1089:        }
```

`StructuralLeverage.longStop(p, Pb, B)` treats its **second** argument as the delta anchor: `a = B == 0 ? p : B; drop = 0.618·(a − Pb); return a − drop`. With `B = 0` the call is `stop = p − 0.618·(p − cap_)`.

The problem is what `cap_` holds inside `[0, W)`. `sampleAnchor`'s flip fires on the FIRST kind-0 sample of the post-halving window:

```
if (kind == 0 && a.windowTag % 2 == 0 && _confirmed(a.lowDensity)) a.floor = a.cap;   // 62-low → floor
...
a.cap = px;                                                                            // reseed to this window
```

So from the first post-halving sample onward, `floor` holds the 62-window bottom **B** — the anchor the state machine mandates — and `cap` holds the still-forming post-halving running low. The engine reads the wrong one. `anchors()` returns `_confirmed(a.lowDensity) ? a.cap : 0`, so once the reseeded post-halving low density-confirms (11 daily samples), a `cap` structurally **above** the 62-min occupies the delta-anchor slot.

`docs/design/STRUCTURAL-STATE-MACHINE.md` §3, L-halving, is explicit: *"each day's slice `stop_day = p_day − (p_day − B)/φ` (anchor `B` = the 62-min)"*, with row PM5 at `p=3000, B=850 → 1671`. `SPECIFICATION.md` §7b's long sizing row is `stop = min(p − (p − floor)/g, cap)` — `floor` is the delta anchor and `cap` is a **ceiling that can only LOWER** the stop. The engine's branch lets `cap` **raise** it.

### Failure scenario

Take the repo's own pinned post-flip state (`AnchorRatchet.t.sol:142-153`): at `t = 13 days`, `floor = 16_000e18`, `cap = 52_000e18`. A Pro Max vault that is FLAT at that instant — a fresh deposit in the post-halving free-exit window, the kept capital after any partial exit (`_finalizeExit` sets `perpStopWad = 0` at `B4VaultOps.sol:279`, so the remainder re-opens from flat), or a vault whose position was liquidated (`_reconcile` clears the stop) — cranks. `zoneAt(13d) == Growth`, so the `OpeningGrowth` branch is skipped and the `t < W` branch fires.

At `p = 60_000`: engine stop = `60_000 − 0.618·(60_000 − 52_000) = 55_056` ⇒ **L = 12.14×, liquidation 8.2% below entry**. Mandated (anchor `B = floor = 16_000`): `stop = 32_807` ⇒ **L = 2.21×, liquidation 45% below entry**.

Pro Max in Growth is pure perp (`decompose(φ)` gives `spot = 0`) and `marginNeedWad = nav·|perpF|/g = nav` — **the whole vault is margin**. The stop is then frozen for the life of the position (`_perpTargetMargin` re-derives only at `szi == 0`) and the Growth zone runs to `t ≈ 537 days`. Ordinary volatility liquidates 100% of the vault.

The safety direction is inverted from what the design claims. `HAZARDS` C5 asserts *"more sampling lowers the recorded low ⇒ lowers leverage, so the honest failure mode is under-sampling"*. Here the **unconfirmed** fallback (`longStop(p,0,0) = p/φ²`, L = 1.618×) is SAFER than the confirmed path. Performing the keeper duty §7b prescribes is what raises leverage.

`sampleAnchor` is permissionless with no shipped honest caller (L-2), so a sole sampler choosing sample instants directly selects the leverage every flat vault opens at during `t ∈ [~10d, 20d)`.

### Invariant / hazard broken

`SPECIFICATION.md` §7b's normative rule that a leveraged position's liquidation "MUST sit at a structurally confirmed price — a level the market has already printed and failed to regain", and its sizing row where `cap` may only lower the stop; `STRUCTURAL-STATE-MACHINE.md` §3/PM5; and `HAZARDS` C5's directional-safety claim. It also re-opens `REPORT.md` F1, whose own rationale was that a post-halving low *"is not a cycle bottom, which the market historically breaks"* — F1 hardened the WRITE side (`floor`), and the READ side now feeds exactly that quantity into the anchor slot.

**Honest bounds.** (a) The branch is CORRECT while the post-halving window is unsampled — `cap` then still holds the 62-min, which is exactly PM5 — and degrades **fail-safe** to flat-φ for the ~10 days between the first post-halving sample and re-confirmation. It becomes wrong only once the reseeded cap confirms. (b) The intended consumer of this branch, the halving volume-add on a HELD long, never reaches `_longStopWad` at all (the stop is re-derived only at `szi == 0`), so the only reachable consumers are fresh/flat opens, where the mandated anchor is unambiguous. (c) No theft, no cross-vault break, no freeze — the damage is total loss of an individual Pro Max vault's own capital, once per ~4-year cycle, and only if an adverse move reaches the misplaced liquidation. It is in scope because it is the engine violating its own normative sizing rule by reading the wrong pool slot, not market drawdown.

### Regression test

**The repo pins the bug as expected behavior.** `test/unit/V8A_Liquidation.t.sol:141 test_V8A_maxlev_clamped_long_liq_further_than_stop` seeds `cap = 99_000` densely inside `[0, W)`, opens a Pro Max vault at `p = 100_000`, and asserts `v.perpStopWad() == StructuralLeverage.longStop(100_000e18, 99_000e18, 0)` with leverage clamped at the venue max 40 and realized liquidation 97.5k — 2.5% below entry, whole deposit as margin. The A/B is in the same file: with nobody sampling, the same vault gets `stop = 38_196.6`, L = 1.618×, liquidation 61.8% below. **Eleven permissionless transactions convert a 1.6× vault into a 40× vault, and the suite asserts both as correct.**

`V8B_StructuralAudit.t.sol:92-98` compounds it: it asserts `longStop(usd(3000), usd(850), 0)` under the comment *"PM5 — L-halving day-1 slice, the EXACT call the engine makes (longStop(p, cap_, 0))"*. But 850 is **B**, the 62-min (cf. PM3/PM4, which use `B=850, Pb=100`). The test pins the CORRECT anchor value under the WRONG variable name — true only while the post-halving window is unsampled, false in every density-confirmed state.

**Write:** open a Pro Max long from FLAT at `t ∈ [10d, 20d)` with a density-confirmed post-halving cap and assert the realized liquidation equals `longStop(px, floor_, 0)`, not `longStop(px, cap_, 0)`. Correct the `V8B_StructuralAudit.t.sol:92` label. Re-derive `V8A_Liquidation.t.sol:141`'s expectation.

### Fix

Pass the delta anchor, not the ceiling. The complete fix must stay correct **pre**-flip, where `floor` is `Pb` rather than `B`: select tag-aware — use `floor_` when the current `windowTag` is this epoch's post-halving (odd) tag, else `cap_`. This requires `anchors()` to expose `windowTag`, exactly as the SHORT mirror already exposes `peakTag` and gates on it (`_shortStopWad` at `:1123` uses `peakTag == epoch+1` precisely to reject a wrong-provenance anchor, with the in-code justification that a stale peak "would over-lever it … **unlike the mirror low ratchet whose stale value is fail-safe**"). That justification is true for a *stale* cap in the L-post branch and false for the *fresh* cap here; the long side has no equivalent gate and today cannot build one.

---

# Medium

## M-1 — `_verifyReturn`'s post-timeout re-clamp can make the completion predicate unsatisfiable forever

**Site:** `src/core/B4VaultEngine.sol:577`

```solidity
555:        uint64 cur = _spotBal(d.coreToken);
556:        bool decreased = cur < intent.snapSrcWei;
...
560:        if (decreased && received >= evmNeeded) { ... _clearIntent(); return true; }
...
575:        // A7: once the source decreased the leg executed — wait for delivery, NEVER resend.
576:        if (!decreased && block.timestamp >= intent.createdAt + RESEND_TIMEOUT) {
577:            uint64 amount = intent.amount <= cur ? intent.amount : cur; // defensive re-clamp
578:            intent.amount = amount;
579:            intent.createdAt = uint40(block.timestamp); // one live action at a time
580:            CoreWriterLib.spotSend(CoreTypes.systemAddress(d.coreToken), d.coreToken, amount);
581:            emit IntentResent(kind, amount);
582:            return true;
583:        }
```

The sibling `_verifyRecovery` has the identical re-clamp **with** the guard this one omits:

```solidity
733:        if (!decreased && block.timestamp >= intent.createdAt + RESEND_TIMEOUT) {
734:            uint64 amount = intent.amount <= cur2 ? intent.amount : cur2;
735:            if (amount == 0) {
736:                emit IntentCleared(kind);
737:                _clearIntent();
738:                return true;
739:            }
```

`_verifyFromPerp` and `_startFromPerp` carry the same settle-to-zero-⇒-clear guard. **The Return leg is the only one of the four that re-clamps and cannot exit.**

The defect is broader than the zero re-clamp. `_startReturn` (`:369-376`) snapshots `intent.snapSrcWei = _spotBal(...)` once and never re-snapshots on resend. If that snapshot is 0 while `weiAmount > 0`, then `decreased = cur < 0` is **unsatisfiable on a uint64 for the life of the intent**, regardless of `amount`. The zero re-clamp is the degenerate case. A later Core credit makes it worse, not better: the hourly resend then ships real tokens to EVM that are credited to no bucket and cannot be swept (`opsRecoverEvm` requires `_requireIdle` for both accounted tokens).

Once wedged, every escape is gated: `crank()` returns `_verifyIntent()` before ever reaching `opsPlanStep` (`B4Vault.sol:157-159`), so `_planExitStep`/`_finalizeExit` are unreachable even after `initiateExit`; `opsSettle` (`:77`), `opsRecoverEvm` (`:333`/`:336`), `opsRecoverCoreSpot`/`opsRecoverPerpSurplus` (`:350`/`:368`) all revert; and `emergencyClearRecovery` rejects `ReturnDir`/`ReturnUsdc` with `NotRecoveryIntent`. `crank()` returns `true` (IntentResent) every hour, so keepers see "progress" and never alarm. The vault's entire steady-state custody is unreachable by owner, keeper and any permissionless path.

**Why Medium, not Critical.** The trigger requires a recorded Core bucket to exceed the real Core balance — books > assets on Core spot, which §2 invariant 3 negates. I re-derived every Core-bucket write (`B4VaultEngine.sol:88-94, 493-497, 537-545, 562-568, 592, 617-621`) and each preserves books ≤ assets: `_verifyFund` credits `min(delta, amount)` from a measured increase; `_verifySpotOrder` credits `min(outDelta, capWei)`; `_verifyToPerp` debits the full amount on any decrease; `_reclassifyUsdc` is sum-preserving. The buy-branch under-debit at `:537` is unreachable because `_startSpotOrder` sizes `sz` so `sz·limitPx <= inputWei <= coreUsdcRotatedWei` and `_quantizePx8` rounds a buy limit DOWN. External parties can only ADD to a Core spot balance, so donations cannot manufacture the precondition.

**Except via C-2**, which manufactures it exactly. This is therefore a defense-in-depth defect that converts any 1-wei Core-spot residual — from C-2, from a future code change, or from the delayed-double-execution case the docs excluded *on the explicit grounds that it is non-freeze* — into an unrecoverable total freeze. The amplification is asymmetric: the shortfall would otherwise be bounded and benign.

### Invariant / hazard broken

HAZARDS **A4** ("no recorded claim may exceed what a single later call can settle … always be able to CLEAR the residual — this was a total-fund-freeze High") together with A6's stated premise that *"with A2/A3 in place, transfer intents always progress after the timeout and never need discarding"* — the premise that justifies `emergencyClearRecovery`'s refusal of `Return*` and is elevated to a safety invariant by `INVARIANTS.md` row 13. Also §2 invariant 18. Not A3: the resend does fire, every hour, forever.

### Regression test

**None; the Return resend branch is never executed by any test.** `setDropNext` appears only at `VenueLayer.t.sol:79` and `Recovery.t.sol:87`/`:133` (both recovery legs) — never against a Return. `startReturn` appears only at `AsyncEngine.t.sol:86` and `:233`, both fully backed (300e8 against 500e8), so the re-clamp is a strict no-op in every test that touches it. `test_R4_dropped_return_self_heals_not_discardable` (`Recovery.t.sol:178-206`) is a false-assurance test in the sense the scope calls in: its name claims the dropped-return self-heal, it never calls `setDropNext`, and its own comment defers the proof to a ToPerp test and to a test that proves the resend does NOT fire. The campaign is doubly blind: `_checkBooks` early-returns on a pending intent (`Protocol.invariant.t.sol:357`), and no adversarial handler can produce an unaccounted Core-spot *decrease*. `MockCore._spotSend` already models the needed venue behavior (`if (spotBal[user][token] < weiAmount) return;`) — the harness was always capable of this test; nobody wrote it.

**Write:** `test_unbacked_return_clears_instead_of_wedging` — set books to 300e8 with a real Core balance of 0, `startReturn`, advance past 10 timeouts, assert the intent cleared and the bucket written down. Also: have the campaign assert books ≤ assets on the LAST idle observation rather than early-returning while an intent pends, and flag a vault non-idle for more than N cranks.

### Fix

In `_verifyReturn`, when the re-clamped `amount` is zero (`cur == 0` — the source provably holds nothing this leg could ever send), do not resend: clear the intent and write the recorded bucket down to the observed Core balance with an explicit measured write-down event, the same shape as `_reconcile`'s perp write-down. A6's "never discard an asset transfer" is satisfied because the source balance is 0, so nothing can be in flight out of it. Additionally, clamp at the call sites — `_min64(bucket, _spotBal(...))` at the five `_startReturn` sites (`B4VaultEngine.sol:849, 853, 1029`; `B4VaultOps.sol:210, 214, 218`) — which `opsRecoverCoreSpot` already does for its own intent and the return leg never does.

---

## M-2 — `usdcMarginEvm` has no reclassify-back path

**Site:** `src/core/B4VaultEngine.sol:1027`

```solidity
1018:        if (marginNeedWad == 0) {
...
1023:            if (pos.szi == 0 && perpMargin6 > 0) {
1024:                _startFromPerp(Purpose.Margin, perpMargin6);
1025:                return true;
1026:            }
1027:            if (coreUsdcMarginWei > 0) {
1028:                _reclassifyUsdc(false, coreUsdcMarginWei);      // <-- CORE bucket only
1029:                _startReturn(false, Purpose.Generic, coreUsdcRotatedWei);
1030:                return true;
1031:            }
1032:            return false;                                       // usdcMarginEvm never touched
1033:        }
```

`_strategyValueWad` (`:200-206`) counts only `dirEvm`, `coreDirWei`, `usdcRotatedEvm`, `coreUsdcRotatedWei` — the margin buckets are in `_marginValueWad` and enter only `_navWad`. `_planSyncStep:789` gates on `if (v > 0 && _planSpotStep(...))`. So a vault whose value sits entirely in `usdcMarginEvm` reads `v == 0`, the spot leg is skipped, and the perp branch has nothing to do: the planner returns false forever.

`_reclassifyUsdcEvm(false, ...)` exists but has exactly one call site — `:840`, inside `_planSpotStep`'s buy branch, gated on `usdcRotatedEvm < spendEvm`. With `coreUsdcRotatedWei == 0` (the documented EVM steady state), `spendUsdWad = targetVal − dirVal <= v − dirVal = usdcRotatedEvm`'s value at `spotF <= 1`, and `coreToEvm` only floors, so `spendEvm <= usdcRotatedEvm` **identically** — the guard can fire only on Core-rotated dust that `_startSpotOrder` no-ops. The EVM side has no working margin→rotation path in the sync planner at all.

### Failure scenario

`_planExitStep` mints the bucket: `_startFromPerp(Purpose.Margin, perpMargin6)` then `_startReturn(false, Purpose.Margin, coreUsdcMarginWei)` (`B4VaultOps.sol:206, 214`), and `_verifyReturn` credits `usdcMarginEvm` for `Purpose.Margin`. `_finalizeExit`'s `_payBucket` keeps the `(1−x)` remainder there.

A Pro vault (growth 1, fall −1) takes a **free** partial exit in `ClosingFall` at `|perpF| = 0.5`. Under continuous honest cranking, `_fundPerpMargin` draws only `nav·|perpF|/g`, so `nav·(1−0.5)` — half the kept NAV — stays in `usdcMarginEvm`. When `t` crosses `T + H`, `perpF` becomes 0; the wrong-sign reduce closes the short and the `marginNeedWad == 0` branch returns the perp margin and reclassifies the **Core** bucket — but `usdcMarginEvm` is untouched. Steady state: `v` excludes it, target is in band, every later crank returns false.

For Pro the zero-perp span is `[T+H, next epoch's P−H)` = 547.67 + 547.67 days ≈ **3 years**, and it is exactly the growth regime in which Pro is supposed to be 100% long spot. Pro Max is largely spared (`perpF = φ ≠ 0` in TerminalGrowth, so the strand is transient); B4 and Mini never fund perp margin.

Nothing else re-buckets it: `deposit` routes to `usdcRotatedEvm`; `opsRecoverEvm` counts `usdcMarginEvm` as accounted (`B4VaultOps.sol:337`) so `excess == 0`. The owner's levers are: wait for the next fall pivot, take an irreversible one-way upgrade to Pro Max, or exit — and outside the free window that costs `EXIT_Q = 11.8034%` of the exited gross, paid to the pool and the operator. On a $25k strand that is $5,902 of the owner's own assets moved to third parties to redeploy their own capital.

**Honest bound.** No custody loss, no accounting error: `usdcMarginEvm` is counted in `_navWad`, `_evmBasketWad` and `_payBucket`, so NAV, the operator cut, the exit split and the reported weight are all exact, and the capital is fully withdrawable at any moment. `_fundPerpMargin` (`:877-885`) does eventually consume it at the next `perpF != 0` zone, so this is very-long-delayed liveness / product-not-delivered, not a permanent freeze. The severity matches the repo's own rating of the identical class (V6-M-2, V6-M-3).

### Invariant / hazard broken

`SPECIFICATION.md:42-46` ("an unlevered long `0 ≤ n ≤ 1` is held as spot") and HAZARDS **H3**'s process standard (*"worst case must be delayed liveness, **self-healing by cranking**"*) — here cranking never heals it; only the calendar does.

**Incomplete prior fix.** AUDIT-V6 rated the identical class Medium as V6-M-2 ("USDC deposits never reach the strategy … `_strategyValueWad` excludes it and no path converts it to strategy capital"). The fix routed deposits to `usdcRotatedEvm` and added the Core-side reclassify-back at `:1027-1030`, but left the EVM-side counterpart out while `_planExitStep` remained a live producer of `usdcMarginEvm` balances.

### Regression test

**None.** Of the 44 `setBuckets(...)` call sites, only `AsyncEngine.t.sol:214/252/270` and `V3Eng_ActivationFreeze.t.sol:47/63/70/84` have a non-zero `marEvm_`, and every one calls `startFund` directly — **no test ever calls `planSync()` with `usdcMarginEvm > 0`.** Every `usdcMarginEvm == 0` assertion (`SyncMachine.t.sol:404/418`, `V8D_Adapted.t.sol:139/153`, `V6D_VenueGaps.t.sol:86`, `FindingsRegression.t.sol:494/503`) starts the margin in `perpMargin6`/`coreUsdcMarginWei` and drives the SYNC return path — i.e. they pin the branch that works. `V8A_Freeze.t.sol:203-247` does a Pro Max partial exit and passes only because Pro Max's `perpF` stays non-zero. The campaign reaches the state (it has an `initiateExit` handler and a `warpPivot` handler) but has no invariant that would notice.

**Write:** `test_exit_created_marginEvm_redeploys_after_pivot` — Pro vault, free 50% exit in `ClosingFall`, crank continuously across `T+H`, assert `usdcMarginEvm == 0` and `dirEvm > 0`. Currently it strands.

### Fix

Mirror the Core branch:

```solidity
if (usdcMarginEvm > 0) { _reclassifyUsdcEvm(false, usdcMarginEvm); return true; }
```

inside the `marginNeedWad == 0` block. One step, monotone, terminating — the same shape as `:1027-1030`. (Dropping the `v > 0` gate at `:789` and counting margin in the rotation-planning value would also work, but the explicit reclassify is smaller and matches the Core path.)

---

## M-3 — Incomplete V8-M-2: the anchor density gate counts samples but does not gate the value ratchet

**Site:** `src/core/B4Pool.sol:416`

```solidity
415:            } else {
416:                if (pxp > a.peakC) a.peakC = pxp; // ratchet the peak UP within the window
417:                _recordDistinctSample(a.peakDensity, now112);
418:            }
```

The value ratchet on `:416` has no time-gap or sanity condition. The density counter on the very next line does:

```solidity
524:    function _recordDistinctSample(Density storage d, uint112 now112) internal {
525:        if (uint256(now112) < uint256(d.last) + MIN_ANCHOR_SAMPLE_GAP) return;
526:        d.count += 1;
527:        d.last = now112;
528:    }
```

and `_confirmed` tests only count and span, never price dispersion:

```solidity
518:    function _confirmed(Density storage d) internal view returns (bool) {
519:        return d.count >= MIN_ANCHOR_SAMPLES && d.last - d.first >= Calendar.W / 2;
520:    }
```

`peaks()` returns `_confirmed(a.peakDensity) ? a.peakC : 0`, so a single print above the true window high inside an otherwise honestly-sampled window is **served, not withheld**, and is then promoted into `prevPeak` by either promotion path (`:411` lazy, `:456-458` the eager V8-L-2 halving-flip promotion — which widens the propagation rather than narrowing it).

`prevPeak` enters `shortStructStop(p, Pp, C) = a + 0.618·(a − Pp)` with a minus sign. The cheap, realistic arm is therefore **over-leverage**: a modest print above the true peak shrinks `C − prevPeak`, tightens the stop and raises next-cycle short leverage (AUDIT-V8 measured 3.58× vs an honest 1.96× on the same shape; the venue maxLeverage clamp of 40 does not engage). The expensive arm — a wick exceeding the *next* cycle's confirmed peak, making `shortStructStop` return 0 and disabling the Pro/Pro Max short for the entire Fall — is real but needs a far larger print.

**No attacker is needed.** `SPECIFICATION.md:152` specifies the peak anchor as the window's **max close**; the implementation records the max over all *calls* at arbitrary instants, because the daily-observation rule governs only the counter. An ordinary exchange wick print reaches the poisoned state on its own.

**Low-side asymmetry (scope note).** The identical pattern at `:464` (`if (px < a.cap) a.cap = px;`) is NOT exploitable: cap/floor move only DOWN, and in `longStop(p, Pb, B)` a lower `B` and a lower `Pb` both LOWER long leverage, so a wicked-low print is fail-safe in both cycles. `HAZARDS` C5 asserts *"The max ratchet has the same directional safety as the min"* — that is false across the halving flip, and the asymmetry is what makes an over-print harmful. Scope the fix to the peak side.

### Invariant / hazard broken

Incomplete prior fix. AUDIT-V8's V8-M-2 remedy was: *"same density gate as V8-M-1; consider **median-of-samples or a sanity band instead of a raw MAX**; optionally promote `prevPeak` at the halving flip."* The density gate and the eager flip promotion landed; the raw MAX and the missing sanity band — the actual defect — are unchanged. Also `HAZARDS` C5's directional-safety claim.

**Honest bound.** No custody loss, no accounting break, no freeze. One print mis-sizes the Pro Max fall product pool-wide for one asset, unrepairable in-window (the MAX is monotone up and `peakTag` is constant for the epoch), for up to a full `Calendar.CYCLE`. It self-flushes at the next flip. Medium matches AUDIT-V8's own rating.

### Regression test

**None for this case; every existing test uses a sparse window.** All three `V8C_PeakWick.t.sol` tests are named `*_sparse_window_*` and place the wick in an under-sampled window; `V9AnchorDensity.t.sol::test_single_wick_peak_not_promoted_not_fed` uses a 2-sample window. Every "FIXED: wick NEVER promoted" assertion is conditional on the wick being the sparse window's only content. Meanwhile `AnchorRatchet.t.sol:218-231 test_peak_window_ratchets_up_only` is a PASSING test that demonstrates the exact transition benignly: 11 daily samples at 40k confirm the window, then ONE further sample at 52k moves the exposed `peakC` to 52k. Substitute a wick price and that is the bug. The code comments at `B4Pool.sol:388-391` and `:502-508` claim *"a sparsely-sampled window **or a single wicked print** can never size a leveraged position"* and *"a short never anchors to a sparse print or a single wick (V8-M-1/V8-M-2)"* — both false for a dense window. That is in-scope false assurance.

**Write:** `test_wick_in_a_dense_peak_window_does_not_set_the_confirmed_peak` — 11 honest daily samples, then one high print, assert `peaks()` does not return the wick and `prevPeak` does not promote it.

### Fix

Gate the value ratchet with the same distinctness rule as the counter (move the `if (pxp > a.peakC)` update inside `_recordDistinctSample`'s accepted branch), which restores "max close" semantics against a passive bad print. That alone does not stop a determined attacker, who can sample at ≥1-day gaps — so add the dispersion remedy V8-M-2 actually recommended: require the extreme to be re-observed by at least one later distinct sample before it can set `peakC` or be promoted to `prevPeak`, or take a median-of-last-N.

---

# Low

## L-1 — Pool-owned sleeves can never execute the vault's recovery entrypoints

**Sites:** `src/core/B4ProductPoolCreator.sol:69-70` · `src/core/B4Pool.sol:18-23`

`_createSleeve` passes `poolAddr` as **both** `owner_` and `pool_`:

```solidity
69:            .initialize(
70:                poolAddr,
71:                poolAddr,
```

and the pool's complete sleeve interface is:

```solidity
18: interface IB4PoolSleeve {
19:     function deposit(uint256 dirAmount, uint256 usdcAmount) external;
20:     function crank() external returns (bool progressed);
21:     function initiateExit(uint256 shareWad) external;
22:     function exitShareWad() external view returns (uint256);
23: }
```

`grep -n "recover" src/core/B4Pool.sol src/periphery/Keeper.sol` returns nothing, and B4Pool has no generic `call`/`execute` and no fallback. So `recoverEvm` / `recoverCoreSpot` / `recoverPerpSurplus` (`B4Vault.sol:179/183/187`, all `onlyOwner`) are **structurally uncallable** for a sleeve: the only address satisfying the modifier is B4Pool, which exposes no forwarder.

Every surplus class a sleeve accrues is therefore permanently outside distribution: perp funding income beyond `_verifyPerpOrder`'s harvest bound (`add = min(measured surplus, snapshotted positive MARK PnL × reduced fraction)` — mark PnL excludes funding, and `_reconcile` writes `perpMargin6` only DOWN, and `_planExitStep` withdraws only `perpMargin6`); A11 spot overfill (`_verifySpotOrder`'s own comment: "favorable overfill stays unaccounted, recoverable surplus"); Core spot above recorded principal; Core→EVM return over-delivery (`_verifyReturn` credits `evmNeeded`, the intended amount); and plain donations. The value belongs to pool claimants.

**Honest bound.** Always surplus **above** measured principal. All sleeve principal repatriates through the ordinary free-window exit, `balance >= liability` is never broken, no attacker gains anything, and no user's capital is at risk. The realistic impact is a slow permanent accumulation of uncounted value in each sleeve. `emergencyClearRecovery` should be dropped from the list of unreachable remedies: a sleeve can never enter a `Recover*` intent in the first place, because only the unreachable entrypoints create them.

**Invariant/hazard:** HAZARDS **B6** ("recoverable to the owner, bounded to `balance − recorded`") and decision **C1** ("owner-recoverable surplus") are written for an EOA owner and simply not implemented for pool-owned vaults. This matters beyond the leak itself: `ARCHITECTURE.md:198-200` accepts the A11 top-up residual *because* "books stay ≤ real assets; excess is owner-recoverable" — for a sleeve, the premise that acceptance rests on is false.

**Regression test:** none. Every `recover*` test (`Recovery.t.sol`, `AuditRegression.t.sol:76-113`, `SyncMachine.t.sol:385`, `FindingsRegression.t.sol:456/509`) uses an owner-EOA vault; `ProductPools.t.sol:285-321` asserts only `accruing(0) > 0` after a sleeve exit, which cannot detect residue. **Write:** `test_sleeve_perp_surplus_is_recoverable_to_accruing` — add funding surplus to a sleeve, run a full free-window sleeve exit, assert nothing is left behind.

**Fix:** add permissionless pool wrappers restricted to `sleeveOf[policy][dir]` — `recoverSleeveEvm/CoreSpot/PerpSurplus(policy, dir, …)` — forwarding to the sleeve's own entrypoints (whose recipient is already hard-wired to `owner == pool`) and then running `_captureToAccruing()` so the recovered surplus becomes ordinary claim inventory. No caller discretion is introduced.

## L-2 — The shipped Keeper never calls `sampleAnchor`

**Site:** `src/periphery/Keeper.sol:20`

`grep -rn "sampleAnchor" src/` returns exactly **one** hit — its own definition at `B4Pool.sol:392`. `_anchor[i]` has no other writer. `Keeper.crank` enumerates `_crankProductSleeves` → `advance` → `lockPrices` → `sweep` → `capture` → per-vault `crankVault`/`settleVault`/`claimFor`/`retryDeferred` — and never samples. Its own NatSpec at `:7` claims *"one permissionless crank for **EVERY** protocol step (HAZARDS G2)"*; `docs/08-keeper.md` and `ARCHITECTURE.md:118-131` both omit anchor sampling too.

The low ratchet is reseed-to-first-sample then min-down, so an honest frequent sampler is monotonically safety-improving and is the only thing that contests an interested party's recorded low. None ships and none is paid. `HAZARDS` (~:195) makes it the load-bearing premise: *"the honest failure mode is under-sampling (a keeper samples each window; the pool benefits)"* — and `B4Pool.sol:376-378` repeats it in NatSpec. AUDIT-V8's V8-M-1 remedy explicitly ended *"Plus a keeper-sampling incentive"*; the density gate landed, the sampler and the incentive did not.

**Honest bound.** With **no** sampler at all the default is fail-safe: unconfirmed anchors are withheld and the engine degrades to flat-φ. This is an enabling gap for the anchor-manipulation class (it composes with H-4 and M-3), not an independent exploit. The realistic leverage inflation from sample-timing alone on a liquid asset is bounded by the window's own high-low range; the large numbers require a thin book (the V8-M-2 threat model).

**Regression test:** `test/unit/V6A_AnchorAttacks.t.sol:155-168 test_b_wickUp_reseed_neutralized_by_honest_dense_sampling` **presumes the missing sampler** ("Honest daily sampling at the fair bottom … ratchets the wick away") — false assurance about a real `src/` gap. The sparse-sampler case is pinned; the dense-adversarial-sampler case is not pinned anywhere.

**Fix:** add `try pool.sampleAnchor(i) {} catch {}` per directional asset to `Keeper.crank` (bounded by `assetCount <= MAX_DIRECTIONAL`, idempotent and window-gated pool-side; `_recordDistinctSample` ignores samples <1 day apart so a fast keeper costs at most one counted sample/day, and the C1/C4 "sampling re-trades a held position" hazard was closed by freezing the stop at open). Then either attach an on-chain incentive or add an explicit `SECURITY_MODEL` §3 residual naming anchor quality as an off-chain trust assumption with a named operator — today §3 does not mention anchors at all. Until a sampler exists, the NatSpec and HAZARDS text asserting "a keeper samples each window" are normatively false (HAZARDS G3).

## L-3 — `_perpTargetMargin` divides by a live `g` while using a frozen stop, with no `g != 0` guard on that branch

**Site:** `src/core/B4VaultEngine.sol:919`

```solidity
903:        structural = pool != address(0) && pxWad != 0 && (long ? g > Phi.WAD : perpF < 0);
...
918:            stopWad = perpStopWad;
919:            if (stopWad != 0) marginNeedWad = Phi.mulDiv(_navWad(pxWad), Phi.abs(perpF), g);
```

The short arm of the `structural` predicate is `perpF < 0` only — it never requires `g != 0`, unlike the long arm's `g > Phi.WAD`. The only `g == 0` protection is `StructuralLeverage.shortFlatStop`'s `if (g == 0) return 0;`, reachable **exclusively** from the `szi == 0` re-derive branch. With a position held, `stopWad` is the frozen non-zero value from the earlier open while `g = abs(fallTarget)` is re-read live.

In a legacy pool (`B4Factory.createPool`, permanently `policyMask == 0`, so `policyAllowedForVault` returns true unconditionally), a vault with a custom strategy `(growth = −WAD, fall = −WAD)` opens a 1× short in the Growth zone; the owner then calls `selectPolicy` to `(growth = −WAD, fall = 0)`, which `_setPolicyResolved` accepts. `B4Vault.selectPolicy` gates only on `exitShareWad == 0` — no idle check, no flatness check — and does not clear `perpStopWad`. On the next crank `perpF` is still `−WAD` (same sign, so `_planSyncStep` step 1 does not fire), `g = 0`, `structural` is true, `stopWad != 0`, and `:919` executes `Phi.mulDiv(nav, WAD, 0)` → `DivByZero`. `crank()` reverts for every caller; `Keeper.crankVault` swallows it, so the vault silently stops syncing while holding a live leveraged short.

**Honest bounds.** Not reachable in a strict Product Pool: `_isReferencePair` forces growth ∈ {WAD, φ}, both positive, so with `fall == 0` `targetAt` is never negative and step 1 flattens instead; and the only zero-fall product (B4, policy 2) sits below Pro/Pro Max, so the monotone `policy >= current` rule blocks the transition. Funds are never frozen: `initiateExit` writes `exitShareWad` with no planner call and no idle gate, and `_planExitStep` never calls `_perpTargetMargin`, so the whole exit machine still runs on permissionless cranks. The correct characterization is an owner-triggered, owner-healable, single-vault denial of the SYNC planner in a legacy pool. It breaches the letter of §2 invariant 18 for that path (permissionless cranking cannot heal it), which is what keeps it a real Low.

`SPECIFICATION.md` §3 legally admits the pair (`|b| ≤ 10·WAD`, `0 < k ≤ 10·WAD`, `|resolved| ≤ φ`), so this is an unhandled in-domain input, not a non-issue.

**Regression test:** none. `Protocol.invariant.t.sol:137-143` cycles only the four reference strategies (all growth > 0); `VaultConfig.t.sol:180-238` uses `EvilStrategy` in a legacy pool but only probes the bound checks. `V8B_StructuralAudit.t.sol:213` asserts `shortFlatStop(p, 0, 0) == 0` with a comment stating the assumption that *"No src caller passes g < 1 (engine: g = |fallTarget| in {1, phi})"* — the assumption a custom legacy-pool strategy violates. **Write:** a two-strategy `selectPolicy` regression that opens a short and then downgrades the fall leg to 0.

**Fix:** add `g != 0` to the short arm — `structural = pool != address(0) && pxWad != 0 && (long ? g > Phi.WAD : (perpF < 0 && g != 0))` — or guard `:919` as `if (stopWad != 0 && g != 0)`. Either falls through to `marginNeedWad == 0`, which the planner already handles by returning margin.

**Related, deliberately not filed:** `selectPolicy` also never clears `perpStopWad`, so a legacy vault that downgrades from a Pro Max short (frozen stop ~1.1·p, ≈10×) to a 1× fall target keeps ~10× exposure until the next sign flip. The direction is anti-conservative and it defeats an explicit owner de-risking action, but the harm class is exposure/drawdown, which this engagement excludes. Same one-line remedy.

## L-4 — The first-credit activation allowance is re-derived at the live price on every poll

**Site:** `src/core/B4VaultEngine.sol:487`

```solidity
484:        if (intent.firstCredit) {
485:            // Tolerate the activation fee on the first credit (A9), but always require a
486:            // measured non-zero credit before completing.
487:            uint64 allowance = _activationAllowanceWei(d);
488:            threshold = threshold > allowance + 1 ? threshold - allowance : 1;
489:        }
490:        if (delta < threshold) return false; // keep polling (A8): no resend, no dead zone
```

`_activationAllowanceWei` converts the fixed `ACTIVATION_FEE_USD_WAD` ($5) into token wei **at the current spot price** (`:509-512`), while the venue fee it is meant to tolerate was deducted once, in token wei, at the credit-time price. The completion predicate `delta >= amount − allowance(px_now)` is therefore not monotone in the only quantity that can still change, so a first DIR-token fund that was satisfiable at credit time becomes unsatisfiable if the directional price rises by more than `$5 / fee_usd` (5× at a $1 fee; only 1.25× at a $4 fee, which still passes the §5.3 gate).

This is on the ordinary path, not a corner: for a Pro Max/BTC vault the planner's FIRST Core action is `_startFund(true, Purpose.Generic, …)` from `_planSpotStep`'s sell branch (`spotF = 0` at target φ, `coreDirWei == 0`), so `intent.firstCredit == true` on a DIR fund. While wedged, A8 forbids resend and abandon, `crank()` short-circuits to `_verifyIntent()`, and every escape is idle-gated.

**Honest bounds.** Not permanent: the same live-price recomputation un-wedges the vault as soon as px falls back below `px_credit·($5/fee_usd)`. A second escape exists: a permissionless out-of-protocol Core spot send of `(fee − allowance)` wei of the DIR token raises the measured delta past the threshold — the identical rescue `test_V3ENG1_fee_above_allowance_is_a_funded_gate` documents for the sibling static case. And the trigger requires a **DIR-denominated** venue fee; `SECURITY_MODEL` §3 and HAZARDS A9 describe activation as a "quote-token fee", and under a USDC-only fee a DIR first credit measures `delta == amount` and completes regardless. It remains in scope because the code models the DIR-fee case (the price conversion in `_activationAllowanceWei` is dead code otherwise) and its handling of that plausible venue behavior is wrong.

What it defeats is the funded gate itself: a USD-denominated deploy-time check ("live fee ≤ $5") is insufficient for a comparison the code performs in token wei at a *later* price. It also re-opens the "no out-of-protocol rescue" standard the V3-ENG-1 fix established.

**Regression test:** none. `grep -rn setActivationFee test/` returns only `USDC_CORE` sites (`V3Eng_ActivationFreeze.t.sol:45/59/82/105`, `AsyncEngine.t.sol:268`, `VenueLayer.t.sol:100`) — USDC is `fixedUsd`, so `_activationAllowanceWei` short-circuits to `Phi.WAD` and is price-independent by construction. The DIR branch is never exercised with a non-zero fee, and no test moves the price between `_startFund` and `_verifyFund`.

**Fix:** snapshot the allowance at intent creation and compare against the snapshot. `B4VaultStorage`'s `Intent.pxWad` field is unused on Fund paths (`grep` shows it is written only at `:353` SpotOrder and `:429` PerpOrder), so store `intent.pxWad = uint256(_activationAllowanceWei(d))` in `_startFund` and read `uint64(intent.pxWad)` in `_verifyFund`. Keep the `:305` start-side refusal on the same snapshotted value so the two can never disagree.

## L-5 — `slippageBps` is validated only from above; a vault created at 0 is permanently unable to rotate

**Site:** `src/core/B4Vault.sol:65`

```solidity
65:        if (slippageBps_ > 500) revert BadSlippage();
```

No lower bound, and `grep` over `src/` shows `slippageBps` is written in exactly one place (`:66`, inside `initialize`) — there is no setter, so 0 is permanent for the vault's life. `B4FactoryVaultCreator.createVault` passes the caller-supplied value straight through.

At `slippageBps = 0` the pre-quantization limit already equals the live mid, and an IOC at the mid never crosses a spread. Quantization then pushes it decisively to the wrong side: `_quantizePx8` rounds a buy DOWN and a sell UP to the coarser of the tick grid and the 5-significant-figure grid (`:148-157`), with no clamp back toward `pxWad`. Measured over 200,000 random 4-decimal BTC-style prices, `s = 0` rounds to the strictly wrong side in 199,970 cases and lands exactly on the mid in the other 30 — no fill in 100% of cases. At `s = 1` the wrong-side count is 0/200,000 (the maximum 5-sig-fig loss is strictly under 1 bp), so `slippageBps >= 1` is provably sufficient.

The wedge is not confined to spot: `_planSyncStep:789` is `if (v > 0 && _planSpotStep(...)) return true;`, so the unfillable-IOC → 1h timeout clear → re-derive loop short-circuits the margin-funding and perp-sizing legs. The vault is inert for its whole life. Custody is unaffected — `_planExitStep` uses only perp orders at the constant `PERP_ENVELOPE_BPS` plus in-kind returns, so exit always works and §2 invariant 18 holds. The cost is capital idle until a free-exit window, or ~11.8% `EXIT_Q` to leave immediately: self-inflicted, single-vault, no cross-user impact.

**Note the quantizer is CORRECT and should not be "fixed".** Buy-down / sell-up is what keeps the executed price inside the declared envelope, and `DescriptorLib._verifyToken` pins `szDecimals` against the venue so the grid is a real tick, not a code artifact. Clamping `q` back onto the correct side of `pxWad` would emit a buy **above** the owner-declared maximum — breaking the exact guarantee the quantizer's docstring makes. The defect is one-sided input validation.

**Regression test:** none. `test/utils/VaultTestBase.sol:77` creates every vault with `100` bps; nothing in `test/` constructs a 0-bps vault. `AuditV5Fixes.t.sol` asserts the quantized price is venue-VALID and never asserts its side relative to `pxWad`.

**Fix:** reject `slippageBps_` below a minimum in `B4Vault.initialize` (≥ 1 is provably sufficient; a practical floor of 10–25 bps is better), and add the lower bound to `SPECIFICATION.md` §7, which today bounds slippage only from above.

## L-6 — The V8-L-1 zero-mark guard reports false progress

**Sites:** `src/core/B4VaultOps.sol:197` and `src/core/B4VaultEngine.sol:774`

```solidity
196:        if (pos.szi != 0) {
197:            _startPerpOrder(pos.szi < 0, uint64(Phi.abs(pos.szi)), true);
198:            return true;
199:        }
```

`_startPerpOrder` now correctly holds on a zero mark (`B4VaultEngine.sol:421 if (markWad == 0) return; // perp feed down: hold, never emit a px-0 order (V8-L-1)`), but unlike `_startFund` (`:279 returns (bool created)`) and `_startSpotOrder` (`:327 returns (bool created)`) it returns `void`, and both call sites that can reach that guard unconditionally `return true`. `B4Vault.crank()` therefore reports `progressed == true` while emitting nothing and changing nothing.

`Keeper.crankVault` breaks only on `false`, so it burns its entire `maxVaultSteps` budget on the affected vault every crank, re-reading the position and mark precompiles each iteration, for every affected vault plus every product sleeve. Any monitor reading `crank()`'s bool sees "progressing" on a vault that is held.

**Framing correction.** Calling this an "incomplete V8-L-1 fix" overstates slightly: `AUDIT-V8.md:138` specified the remediation as "mirror the zero-mark guard into `_startPerpOrder` (one line)", and that was done exactly as specified. What the fix actually did was introduce a THIRD no-op exit in an intent-creating helper without the A13 `returns (bool created)` wiring its three siblings carry.

**Scope.** Only 2 of the 4 `_startPerpOrder` call sites can produce false progress — `B4VaultEngine.sol:1062`/`:1065` are downstream of the `markWad == 0` guard at `:1039` and of the band check, so their `return true` at `:1066` is sound. The `szLots == 0` guard is dead at both affected sites (`pos.szi != 0` implies `abs(pos.szi) != 0`), so a zero mark is the only live trigger. Purely a liveness/telemetry defect — no custody, accounting or NAV effect, no state written, fully self-healing when the mark feed returns.

**Regression test:** none asserts the progress signal. `test_V6B_1_exit_flatten_held_at_dead_mark_feed_resumes_on_return` (`V6B_PerpZeroMark.t.sol:36`) calls `v.crank()` and discards the bool; `test_V9_L1_perp_order_held_at_zero_mark` (`V9Engine.t.sol:128`) calls the void harness wrapper directly. Both assert only "no px-0 order emitted". **Write:** with a live position, `perpF == 0` and `setMarkPx(PERP_MKT, 0)`, assert `crank()` returns **false** and no intent was created.

**Fix:** give `_startPerpOrder` a `returns (bool created)` (false at both early guards, true after `_snapshotBase`) and propagate it: `if (pos.szi != 0 && _startPerpOrder(...)) return true;` at both sites, falling through to the next planner leg. Apply the same shape to `_finalizeExit`'s hold in H-3 so `_planExitStep` returns false when the exit is held.

---

# What was checked and found sound

This section is specific on purpose. Each item was actively traced or executed; none is a generic reassurance. Re-deriving these is wasted effort for a future round.

**Access control / authority.** Clone init is atomic (clone + `initialize` + `registerVault`/`registerSleeve` in one creator frame — no front-run window) and the implementation self-seals with `_initialized = true` in its constructor. B4VaultOps' own `_initialized` is false, so every `onlyInitialized` entrypoint reverts on a direct call, and it does not inherit `initialize`. Storage layouts agree exactly (B4Vault adds only an immutable; the ops/creator modules add only constants), so the delegatecalls are layout-safe. `ops`, `recovery`, `vaultCreator`, `poolCreator` are constructor immutables. The vault never delegatecalls a caller-chosen selector; ops code never reads `msg.sender` (verified by grep over `src/`). `owner`, `route`, `pool`, `oracle`, `factory` have no setters. A rogue self-deployed clone can initialize against a real pool but gains nothing — `reportWeight`, `capturePenalty` and `setVaultPolicy` all gate on the pool's own `isVault`, and `claimFor` needs a non-zero reported weight. The two factories keep separate `isPool` registries. **Superseded by the 2026-07-25 refactor:** `B4Pool.factory` is now a constructor parameter that `B4PoolDeployer` fills with its own caller, so it is SELF-DECLARED — an impostor pool may name a real factory. That is decorative and grants nothing, because authority flows only from a factory's own `isPool` registry, written solely for pools that factory created; `B4Pool.factory()` must never be used as a provenance check. Pinned by `test_impostor_pool_may_name_the_real_factory_and_gains_nothing`. A mutable strategy contract is neutralized: `_isReferencePair` is re-read and re-validated on both `createVault` and `selectPolicy`, closing the TOCTOU. Keeper holds no funds and no authority; its self-call wrappers are `require(msg.sender == address(this))` guarded and `v.settle(id)` uses the vault's OWN pool, not the keeper's argument.

**Async engine.** The complement structure of ToPerp (`:589` vs `:598`), FromPerp (`:614` vs `:628`) and Recovery (`:726` vs `:733`) is exact — completion and resend predicates are literal negations on the same reads, with no both-true/both-false window. `_verifyIntent` dispatch is total over `IntentKind`, and no verifier accepts another kind's state. `_clearIntent()` is `delete intent`, and every `_snapshotBase` is preceded by a clear or the crank-level idle check, so no stale `claim6`/`snapEvm`/`pxWad`/`isBuy` leaks across intents. Purpose→bucket routing is consistent on both debit and credit for all four transfer families; `_startToPerp`'s amount is floored via `_weiToUsd6` so `_verifyToPerp`'s debit cannot exceed the recorded margin bucket. A9's `_startFund` refusal correctly prevents the zero-credit poll-forever wedge, and `evmToCore`/`coreToEvm` is non-expanding in both decimal directions so `dirEvm -= evmAmount` cannot underflow. A4/A5: `pendingHarvest6` is zeroed inside `_startFromPerp` before any early return and both create- and resend-time paths clamp to `min(claim, available)`. `opsRecoverEvm`'s `_requireIdle` blocks siphoning an in-flight Return mid-delivery. No ping-pong between `_planSpotStep`'s in-band repatriation and `_fundPerpMargin`: `Calendar.decompose` guarantees `spotF > 0 ⇒ perpF == 0`.

**Accounting.** Exit-waterfall conservation is exact: at `_finalizeExit` the Core side is provably empty, so `nav == value(dirEvm, usdcRotatedEvm, usdcMarginEvm)` and `ownerWad + operatorWad + poolWad == grossWad` in both branches. `_payBucket` splits every bucket by the same scale-free ratios, all three `mulDiv` floor, and the dust stays with the vault — no bucket can pay out more than `x` of itself. `_finalizeExit` cannot run twice or mid-intent. **Reward-weight duplication over repeated/dust partial exits is genuinely bounded:** `R' = (R + C·x)(1−x)` with `profit → profit(1−x)`; the continuous limit `R(τ) = e^{−τ}(R₀ + Cτ)` caps total added weight at `C/e ≈ 0.368C`, strictly below a single settle, and re-depositing between exits does not restore `profit`. Loss reconciliation is strict-flatness-gated, idempotent, and every caller runs at an idle engine, so an in-flight self-transfer can never be written down as loss. No double-spend across spot/margin/perp ledgers: reclassify is same-token and NAV-neutral, and intent amounts are pinned at creation to bucket levels that cannot change while an intent pends. Harvest accumulation across multiple partial fills is re-clamped to `min(claim, wd − perpMargin6)` at `_startFromPerp`. Rounding is uniformly floored toward the protocol; the only mis-directed dust is `toPool` flooring (≤1 wei/bucket/exit).

**Pool (outside H-1 and C-1).** D2 `balance >= liability + escrowHeld` is preserved by every path — `capture`/`capturePenalty` set it by construction, `claimFor` reduces both sides together, `foldPenalty` decrements escrow and balance by the same amount. D3 order independence is exact: the ratio `available/liab` is invariant across a claim, drifting only slightly UP for later claimants (the documented B5 direction). D4: `sweep` touches only `remaining → accruing`, never liability; the claim gate `id + 1 < intervalCount` is the exact complement of sweep's condition, so no interval is simultaneously unclaimable and unsweepable. D1's lock is genuinely all-or-nothing (`lockedAt` set only after the whole loop). D5: `_safeBalanceOf`'s 100k gas cap and `SafeTransfer`'s 500k cap plus return-bomb caps bound the worst case at 9 assets. Reentrancy between sibling pool functions: the shared `_entered` covers every fund-moving entrypoint, and the three unguarded ones (`reportWeight`, `lockPrices`, `sampleAnchor`) are window-disjoint from `claimFor`'s payout or idempotent. `MAX_DIRECTIONAL` is enforced in the constructor with duplicate `evmToken`/`coreToken` rejected, so no index aliasing.

**Oracle / cross-chain.** Path binding is complete (`msg.sender == endpoint`, `origin.srcEid`, `origin.sender`, all immutable, re-applied in `allowInitializePath`). Replay/reordering/conflict handling is exhaustive: `height <= halvingHeight` ⇒ hash-idempotency or `ConflictingFact`; `height != halvingHeight + 210000` ⇒ `NotNextHeight`; `ts <= halvingTs` ⇒ `NonMonotonicTimestamp`; `ts > block.timestamp` ⇒ `FutureTimestamp`. Because `nextNonce` returns 0 (unordered), a permanently-reverting packet does not block later nonces, so spamming old-height publications is self-funded griefing. `BtcHeader.hash` is a correct dSHA256 over 80 bytes and `timestamp` reads the correct LE uint32 at offset 68. `renounceDelegate` is genuinely one-shot with no setter and no arbitrary-call surface on either side. An ultra-fast epoch cannot wedge `nextSettlementPoint`: that would require `newTs <= oldTs`, which strict monotonicity forbids. E4: `timeSinceHalving()` reverts pre-bootstrap and cannot underflow after; both factories gate pool creation on `halvingHeight() != 0`, and `B4Pool`'s constructor sets `lastPointTime = block.timestamp`, so no pool can mint a stale genesis interval. The new bootstrap rewrite (genesis anchor moved out of the constructor into a proven LZ message) was re-verified end to end.

**Calendar.** `targetAt` boundary arithmetic is exact and continuous at `P−W, P−H, P, T, T+H, T+W` on both branches, with no underflow (each `t − …` is reached only after the corresponding guard) and truncation toward zero, so an interpolated value can never leave `[min, max]` or change sign. Invariant 9 holds at both levels: `decompose` yields `sign(perp) ∈ {0, sign(n)}`, and `_planSyncStep` step 1 issues a reduce-only full close before any opposite-side order. `intervalKey` continuity holds — ids are a strict counter, `lastPointTime` is only written together with an interval creation, and `nextSettlementPoint` returns strictly-greater points. Settling exactly AT a point is safe (`perpF == 0` ⇒ strict flatness required). The free-exit zones, `POST_FACT_FREE_EXIT`, and the three anchor sampling windows are mutually consistent, and the density gate (10 daily samples spanning ≥ W/2) fits inside every 20-day window.

**Math.** `Phi.mulDiv` is a faithful FullMath port (512-bit product, `twos` factoring, seed `(3d)²` + 6 Newton iterations = 256 correct bits); the intermediate-product bound ~1.9e77 is unreachable. Unit algebra is consistent end to end: lots = `tokens·10^szDec`, the 1e8 writer convention, read-convention perp px, `_positivePnl6` landing in 1e6 USD, and every sizing/valuation/payout expression checked dimensionally. Every `10 ** (a − b)` exponent is guarded at descriptor binding. A full division-by-zero sweep found every `mulDiv` divisor either constant, a `10**dec`, or explicitly guarded — with the single exception reported as L-3. Narrowing casts: V6-I-4/V8-I-7 is genuinely fixed with the clamp at `:160`; the remaining raw casts require a sub-$1e-6 asset or a >$1e11 position, and the two spot-order caps are separately bounded by the measured delta so even a wrapped value cannot credit unmeasured value. Settle and exit waterfalls were re-derived numerically: a single 100% exit and two sequential 50% exits produce identical total fee and penalty, so partial-exit sequencing extracts nothing.

**Venue.** Action encoding verified field by field against both the writer and the reader: `abi.encodePacked(version=1, actionId, args)`, ids 1/6/7, `TIF_IOC = 3`, the limit-order tuple order, spot asset id `10000 + spotMarket`, `systemAddress = 0x2000…00 + coreToken`. The writer/reader unit asymmetry is exactly inverted by `_lotsToSz8` and `_quantizePx8`'s step, and spot vs perp szDecimals families are never crossed. Sign/reduce-only handling is correct at every emission site. Quantize-to-zero is unreachable for any venue-assigned szDecimals; a rejected order is indistinguishable from an unfilled IOC and clears after the timeout, so no rejection leaves an intent live forever. `CoreReader._read` reverts on `!ok` and `abi.decode` reverts on a short buffer for every shape used, so a codeless/absent precompile fails **closed** — it does not decode as a flat position. The `NO_MARKET` sentinel is fully fenced. Descriptor binding checks every field, including the HIP-3 `perpMarket <= uint16.max` rejection and the tokenInfo cross-checks.

**Structural leverage (outside H-2 and H-4).** The freeze lifecycle itself is correct: `perpStopWad` is written only inside `if (szi == 0)` and read otherwise, `_reconcile` clears it on an adverse close, `_finalizeExit` clears it, and a partial fill / no-fill clear / resend never re-derives it while held. The margin-control algebra is sound — `backing = |szi|·|avgEntry − stop|` is exactly the isolated-liquidation margin; adds at the mark keep the increment's own liquidation on the stop; reduces at the frozen avg entry keep the remainder on it. `_avgEntryWad`'s unit conversion is right (`entryNtl` is absolute). The short-side zone+freshness gate (`peakTag == epoch+1 && zone == Fall`) and both `prevPeak` promotions are idempotent and confirmation-gated. Peak-max manipulation is bounded by reality within a cycle (a higher `peakC` moves the stop FURTHER post-pivot); 62-window cap manipulation by sampling only at daily highs is low-impact post-pivot (`d(MinStop)/d(cap) = 0.382`; a 20% cap error moved L only 1.37× → 1.44×). The density gate is not inflatable by same-block or compressed sampling.

**External calls.** `SafeTransfer._call` handles no-return / false-return / short-buffer / return-bomb / gas-cap correctly, and `tryTransfer` is genuinely revert-free; every call site's success/failure branch is consistent. `foldPenalty`'s escrow-decrement-before-transfer window is genuinely closed by the shared guard. Read-only reentrancy: the only pool views a vault trusts are never stale during an external call. All three delegatecall targets are constructor-immutable with matching storage prefixes.

**Also confirmed as genuinely fixed from prior rounds (not re-reported):** the V8-M-1 density gate is present and correctly applied on both sides including the eager halving-flip promotion (V8-L-2); the V8-L-3 `claimFor` latest-only gate is intended; V8-L-4's `maxSz >= absNow` floor is in place; `opsRecoverPerpSurplus` reserves `perpMargin6 + pendingHarvest6` (the prior fix is complete); the V6-M-2 `_reclassifyUsdc` fix works on the sync path; the V6-I-4/V8-I-7 quantizer clamp is real; and the settle-requires-idle hardening (RAW-A-001) is correct for the class it targets.

---

# Residual risk and what this audit cannot establish

**Funded release gates remain funded gates.** Nothing here proves CoreWriter atomicity, fresh-account activation semantics, precompile behavior, IOC fill semantics, or `usdClassTransfer` atomicity. Where a finding depends on venue behavior I said so explicitly (L-4 in particular fires only under a DIR-denominated activation fee).

**Specific things I could not rule out, ranked by what a deeper pass should do first:**

1. **`CoreTypes.Position` field ORDER is unverified against the live precompile, and the tests are circular.** All five members are static, so a swapped `entryNtl`/`leverage` would silently corrupt `_avgEntryWad` and therefore every structural add/reduce sizing decision. `MockCore` constructs the struct directly, so no local test can detect it. This needs an off-chain byte-level ABI diff, not more Solidity reading. It is nominally release gate §5.5, but field order is a **code fact**, not a semantics fact.
2. **Settlement-token identity is never asserted.** `DescriptorLib.verifySettlement` never checks that the settlement descriptor IS venue USDC (core token index 0), yet `usdClassTransfer` unconditionally moves USDC. A factory deployed with a non-USDC settlement token that has a linked ERC20 passes every check, after which `_startToPerp` watches the wrong balance ⇒ resend-forever ⇒ unhealable freeze. I did not file it (it is a deployer act and `SECURITY_MODEL` §3 plausibly covers descriptor trust), but the failure mode is a **freeze**, which is worse than that residual's framing, and a one-line `s.coreToken == 0` check closes it.
3. **`_startReturn` has no whole-EVM-unit normalization** (asymmetric with `_startFund`, which explicitly normalizes "so nothing is stranded by flooring") and no `coreToEvm(amount) == 0` guard. Whether a sub-dust `spotSend` truncates or is **rejected** by the venue is a funded gate; the rejected branch is an unhealable resend loop of exactly the M-1 shape.
4. **Manipulability of `CoreReader.spotPx`** on the pool's directional market. `deposit` credits `entryLedgerWad` at a single unguarded read with no envelope; C4 declines an oracle sanity band on the grounds that "the 500/50 bps execution envelopes are the defense", which does not cover a ledger credit. Sizing this needs HyperCore spot-book depth data I could not obtain offline.
5. **`B4Pool.foldPenalty` calls `sleeve.deposit(...)` and `sleeve.crank()` with no try/catch**, and `penaltyEscrow`/`escrowHeld` are excluded from both `liability` and `_unaccounted`. A permanently-reverting sleeve deposit (settlement-USDC blacklisting of a sleeve address — explicitly IN scope per `SECURITY_MODEL` §4's "settlement USDC excepted") would strand the escrowed penalty with no admin and no recovery path. Reachability depends on an external issuer action.
6. **Permissionless-crank timing as an MEV surface.** A caller choosing the exact moment `foldPenalty` opens a leveraged sleeve position, or the moment any vault's IOC is emitted, is real and currently undocumented. I treated it as the keeper-timing residual rather than a finding, but it is not listed in `SECURITY_MODEL` §3 and should be.
7. **`script/Deploy.s.sol` never deploys `B4ProductFactory` or `Keeper`** — the entire strict-product path under audit is absent from the deployment script, and `renounceDelegate()` is left as a manual post-deploy step. Process/completeness, no runtime custody impact, but it means the audited configuration has never been deployed even locally.
8. **Gas:** an 8-directional aggregate pool deploys 32 sleeve clones with venue verification in a single `createProductPool` transaction; I did not measure whether that fits a realistic block gas limit. Nor did I measure live HyperEVM USDC transfer cost against `SafeTransfer`'s 500k cap and `_safeBalanceOf`'s 100k cap — a live cost above the cap silently converts a real transfer into a deferred payout.

**Systemic observations that are not findings but should change process:**

- **The invariant campaign is structurally blind to most of what this round found.** It runs against a LEGACY pool (`VaultTestBase.sol:55`), so `policyMask == 0` and the entire strict-escrow branch is never fuzzed. It runs `hub.setAuto(true,true,true)`, so the emitted-but-unexecuted window that all of HAZARDS class A exists for is collapsed to zero. `movePrice` bounds px to `[20_000e4, 500_000e4]`, so no zero-price state is reachable. No handler models an unaccounted Core-spot *decrease*. And no invariant reads `entryLedgerWad`, `rewardBaseWad`, `weightOf` or `totalWeight`. Four of the six highest findings are invisible to it by construction, not by omission.
- **`INVARIANTS.md`'s traceability table stops at row 18** while `SECURITY_MODEL` §2 now has 19 invariants. Invariant 19 — the one governing the entire new product-sleeve subsystem — has no row, no test mapping and no campaign.
- **`invariant_crank_never_reverts` is a revert proxy**, cited as the campaign coverage for invariant 18's "worst case is delayed liveness, never freeze or loss". It tests the freeze half and is structurally incapable of testing the loss half: several findings above produce a crank that succeeds and destroys value.
- **`ARCHITECTURE.md` and `spec/HAZARDS.md` contain zero occurrences of "sleeve", "escrow" or "product pool".** The whole subsystem has no entry in the A1..A12 discipline map and no documented ordering resolution to appeal to.

**External audit is still required**, and this code is not ready for one. Fix C-1 and C-2 first — both are permissionless, capital-recyclable drains on the shared basket, and C-1 requires a spec amendment (`SPECIFICATION.md:87` and HAZARDS B4 encode the defective rule), not just a code change. Add an invariant covering weight integrity and a row for invariant 19. Then re-run the campaign with a strict product pool, async venue execution, and an unbounded price handler; several findings here would have been caught by the existing assertions under those settings.

---

# Appendix — raised and killed

Findings that were raised during this round and refuted. Recorded so a future round does not re-spend the effort.

| id | claim | why it died |
|---|---|---|
| `postfact-freeexit-anchored-to-header-ts` | The post-fact free-exit window is anchored to the Bitcoin header timestamp, not to fact acceptance, so transport latency shortens it and can close it entirely. | All evidence real (`Calendar.sol:41,125-133`; `HalvingOracle.sol` has no `acceptedAt`), but it is a correct and deliberate design: the calendar is anchored to the fact, not to its transport. Latency shortening a window is delayed liveness in the documented direction, not loss. |
| `advance-gap-no-drain-path` | Between an epoch's second settlement point and the next epoch's first, `advance()` returns false for 954–1095 days, so captured pool inventory has no drain path. | The arithmetic is true but the defect framing is refuted on four counts; the evidence citation to `capturePenalty` was wrong for a configured Product Pool. The one true residue is an out-of-scope prose nit about the documented deferral length (which IS understated — see `Calendar.sol:64` — but that is documentation, not custody). |
| `dca-add-unbounded-toward-frozen-stop` | The DCA add site bounds the increment only by `denomMark == 0` and the venue max-leverage clamp, so a price moving toward the frozen stop pins the whole position's liquidation at that stop at up to venue-max leverage. | Evidence verbatim-accurate and the state is reachable, but the behavior is the *intended* margin-control invariant: the combined liquidation staying pinned to the frozen stop is the design's central promise, and the venue clamp is the documented ceiling. This is exposure economics, which the engagement excludes. |
| `weight-survives-capital-loss` | `rewardBaseWad` is never written down by a loss, so a zero-NAV vault keeps a permanent capital-free claim on every future pool basket. | Mechanism accurate and the code quotes are verbatim, but this is the specified behavior: weight is cumulative earned client share, deliberately not marked to market. `SPECIFICATION.md` §8 defines it that way and the exit scaling is the only intended decay. Not a defect without a spec change. (Note H-1's cohort-forfeiture consequence rides on the *same* property in the opposite direction.) |
| `exit-penalty-decided-at-finalize` | Free-exit status is evaluated at `_finalizeExit`, not at `initiateExit`, so the same owner action costs 0 or 11.8% depending on third-party crank timing. | `B4VaultOps.sol:251` does evaluate at finalize and `initiateExit` latches nothing, but the claimed harm does not exist: `crank()` is unrestricted so the OWNER drives their own exit, and the operator and the pool both have a standing financial incentive to finalize. Documented design, not a defect. |
| `pool-lockprices-dead-coasset` | One co-listed directional asset whose spot price stops resolving permanently disables `lockPrices` for the whole pool, making the reward basket undistributable forever. | Code quotes accurate (the all-or-nothing D1 loop is real), but "forever" is false: `sweep(id)` requires only `id + 1 < intervalCount` with no lock requirement, so an unlockable interval's inventory rolls forward into `accruing`. Delayed liveness with a documented drain path, and the all-or-nothing lock is the deliberate D1 remedy. |

Also folded rather than killed: 12 of the 28 raised candidates were duplicates of six underlying defects (four separate reports of the `capturePenalty` over-sweep, four of the JIT weight mint, three of the zero-px regime flip, four of the unguarded `_livePxWad`). They are merged above under H-1, C-1, H-2 and H-3 respectively.
