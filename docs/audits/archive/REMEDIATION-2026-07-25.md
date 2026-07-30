# REMEDIATION-2026-07-25 — fixes for the full security audit

Companion to [`AUDIT-2026-07-25-full-security.md`](AUDIT-2026-07-25-full-security.md).
Suite: **380 → 412 passing, 0 failing**. Every fix carries a fail-before/pass-after regression.
No fix was accepted on reasoning alone where a test could be written.

## What landed

| id | sev | fix | regression |
|---|---|---|---|
| C-1 | Critical | settle values the vault at the **live price of the settlement instant** | `AuditC1_JitWeight.t.sol` ×4 |
| C-2 | Critical | spot-order completion requires a measured **input debit**; an out-token increase is not a completion | `AuditC2M1_AsyncCompletion.t.sol` ×2 |
| H-2 | High | dead spot feed ⇒ **hold**, as an early return in `_planPerpStep` | covered by the existing structural suites |
| H-3 | High | zero-price guards on both ledger-writing paths, exit **defers** rather than reverts, `cancelExit` escape | `AuditH3_ZeroPrice.t.sol` ×8 |
| M-1 | Medium | a zero re-clamp on a `Return` leg **clears** instead of wedging both predicates forever | `test_M1_zero_reclamp_...` |
| M-2 | Medium | added the missing `usdcMarginEvm` counterpart in the zero-margin branch | existing suites |
| L-3 | Low | `g != 0` guard on the frozen-stop branch | existing suites |
| L-5 | Low | `MIN_SLIPPAGE_BPS` floor — an immutable 0 bricked the vault permanently | existing suites |
| H-1 | High | `capturePenalty` escrows only the exit's **measured receipt** (transient-storage before/after via `beginPenalty`), not the pool's whole unattributed balance | `AuditH1_PenaltyReceipt.t.sol` |
| H-4 | High | L-halving long anchors on the promoted 62-min (`floor`), not the current window's running low; regression asserts the LIQUIDATION PRICE | `AuditH4M3_Anchors.t.sol` |
| M-3 | Medium | window anchors ratchet on DAILY observations, both sides — an intraday wick can no longer move a confirmed anchor | `AuditH4M3_Anchors.t.sol` ×3 |
| half B | product | the realised exit share is added, not scaled away — call order no longer decides whether an earned fee survives | `AuditHalfB_ExitWeightOrder.t.sol` ×3 |
| L-6 | Low (partial) | `_finalizeExit` returns `bool`; `_planExitStep` propagates it | `test_H3_exit_defers_...` |
| — | — | EIP-170 guard over **every** deployed contract, printing headroom | `Eip170Sizes.t.sol` |

## C-1 — the fix is not the one the audit proposed

The audit framed C-1 as a stale *lock* and proposed a deposit-side rule (book a directional
deposit at the checkpoint price). That plan was written, reviewed by three independent critics,
and **refuted by measurement**. With the plan's patch applied in a scratch copy:

| probe | with the plan's patch | without |
|---|---|---|
| USDC deposit → permissionless crank rotates it into BTC → settle | weight **1562** (honest 316) | 1562 — untouched |
| deposit before `lockPrices`, then lock at a chosen price | weight **1578** — full original payoff | 1578 — untouched |
| checkpoint basis + live-priced `_finalizeExit`, looped | weight **225**, zero cost, repeatable | **0** |

The third row is the verdict: the proposed fix **created** a cheaper attack than the one it closed.

### Actual root cause

`_navWad` reads the vault's composition **at call time**; the price was fixed **earlier**.
Therefore *any* composition change inside the report window is measured against a stale
reference, and the gap reads as interval profit no capital earned. And the window is exactly
when the calendar **mandates** a change: `Calendar.targetAt` is 0 at the settlement point and
ramps immediately after, so a flattening product sells and a spot product buys, both at live
prices. `deposit` and the permissionless `crank` both reach that window, and the crank never
touches the entry ledger — so **no deposit-side rule can close it**.

### The fix

One line of behavior: `opsSettle` values at `_livePxWad()`. Entry ledger and the NAV it is
subtracted from are now always on the same basis, so measured profit is exactly

```
profit = Σ qᵢ · (P_settle − pᵢ)
```

— the real P&L of the actual holdings over their actual holding periods. There is no price in
the system that a caller can select and that the capital did not experience.

It closes the whole class rather than one member (deposit, spot rotation, harvest, margin
return), it makes settle and exit agree — while they disagreed, the gap between them was itself
harvestable — and it **removes** bytecode, which mattered (see below).

`lockPrices` is retained only as the marker that opens an interval for reporting; the recorded
`lockedPxWad` no longer feeds any valuation.

### Verified

| | before | after |
|---|---|---|
| committed exploit (deposit BTC after the lock) | weight 1578, took **$833,333** of a $1,000,000 basket for $676 | **0**, and `claimFor` reverts `NothingToClaim` |
| USDC deposit → crank rotation | weight 1562 | **0** |
| deposit → free-exit loop | 225 at zero cost | **0** |
| honest vault holding a real move | 316 | **316 — unchanged** |

That last row is the point of the positive control: the fix must not silence honest measurement.

### Accepted residual

With no frozen reference, whoever calls the permissionless `settle` inside the report window
picks the instant and so the price. Bounded, and recorded in `SECURITY_MODEL.md` §3: the keeper
settles promptly, and the basket is distributed pro rata, so a uniform shift cancels and only
*differential* timing has any effect. It is a relative-weight fairness question, never a mint.
The alternative — freezing the price — is what produced the exploit.

## Two audit findings withdrawn

- **A zero operator rate is not a defect.** The virtual fee is still computed; `operatorBps` only
  splits it between cash and retained weight. Understating profit is self-punishing at any rate,
  and *strictly more so* at 0. It was never the anti-manipulation mechanism — the real defence is
  that profit cannot be fabricated, which C-1's fix establishes.
- **Time-in-interval weighting is not a missing control.** It would contradict REQUIREMENTS §5.6
  ("profitable participants") by rewarding tenure over performance: a long holder who lost money
  would earn weight and someone who caught the move would be penalised. Profit is already
  time-weighted by construction — a late entrant captures only the late part of the move and gets
  weight proportional to exactly that. Holding time does not guarantee profit; profit does.

## Half B — downgraded

A vault that settled an interval and then fully exits keeps that interval's claim, because the
pool is never told about the exit while `_finalizeExit` zeroes the vault-side accumulator. With
C-1 closed this is not cheap: it needs real capital, real exposure and real profit across a real
interval (0.94–1.5 years). What remains is an **ordering inconsistency** — `settle`-then-exit
keeps the weight, exit-without-`settle` destroys it — which is a product decision, recorded in
`SECURITY_MODEL.md` §3 and scheduled separately.

## The EIP-170 wall, and the refactor that removed it

H-1 was written, tested, and then had to be **reverted** — not because it was wrong, but because
it put `B4VaultOps` 13 bytes and `B4ProductPoolCreator` 343 bytes over EIP-170. That exposed two
structural facts nothing had recorded:

- `B4Vault` and `B4VaultOps` **both** inherit `B4VaultEngine`, so engine bytes are paid twice.
- `B4Pool`'s creation code was embedded in **both** `B4Factory` and `B4ProductPoolCreator`,
  because each ran `new B4Pool(...)` inline. So `B4Pool`'s apparent 8 KB of headroom was
  **illusory** — every pool-side byte consumed the creator's 38.

Two splits fixed it:

- **`B4PoolDeployer`** holds `B4Pool`'s creation code once; both factories call it. `B4Pool`
  gained an explicit `factory_` constructor parameter, which the deployer fills with its own
  caller — the same value `msg.sender` produced before, so the trust model is unchanged.
- **`B4VaultRecovery`** takes the cold path (`opsRecoverEvm`, `opsRecoverCoreSpot`,
  `opsRecoverPerpSurplus`, `opsClaimDeferred`) out of `B4VaultOps`. `B4Vault` gained a second
  immutable module address and a shared `_delegateTo`.

| contract | before | after |
|---|---|---|
| `B4VaultOps` | 92 | 1,991 |
| `B4ProductPoolCreator` | 38 | 18,158 |
| `B4Factory` | 326 | 18,473 |
| `B4Pool` | 8,393 (illusory) | 8,025 (real) |
| `B4Vault` | 515 | 313 ← now the tightest |

`Eip170Sizes.t.sol` guards all nine deployed contracts and prints headroom, so the next overflow
fails legibly instead of killing the suite at fixture setup.

**H-1 then re-landed.** Fail-before/pass-after is decisive: without the fix the escrow takes
**61,803,398** sats — a co-resident 50,000,000 donation *plus* the real 11,803,398 penalty
(`EXIT_Q x 1e8`); with it, only the penalty, and the donation stays claimable inventory.

All of them then landed: **M-3**, **L-2** and **H-1** above.

**L-1 was withdrawn by the product owner**, correctly. Its premise was a sleeve address landing
on the USDC block-list; recovering funds lost to a block-list is not this protocol's problem to
solve, and `foldPenalty`'s atomic revert is already the right behaviour for a transient failure.
Adding a catch-and-divert would have been strictly worse: `sleeve.deposit` also reverts for
transient reasons — a pending sleeve exit, or (after the H-3 guard) a zero price read — so a
short oracle outage would have permanently rerouted penalties away from their product sleeve.

## Deferred on judgement, not capacity

- **H-4 — resolved, not deferred.** `STRUCTURAL-STATE-MACHINE.md` §3 settles it normatively:
  `stop_day = p_day − (p_day − B)/φ` with `B` = the 62-min, worked as `[p=3000, B=850 → 1671]`
  (row PM5). The 62-min is what the halving flip promotes into `floor`, so `floor` is the
  anchor. Two existing tests had ENCODED the defect — `V8A` documented "stop = 100k −
  (100k−99k)/phi → raw L = 161x" in its own comment, i.e. a liquidation 0.6% below entry — and
  were re-seeded through the correct anchor so they still exercise the venue clamp.
- **Reinvest (audit Part 3) — withdrawn by the product owner.** Pool income stays a payout to
  the owner's wallet; the client decides whether to put it back. Simpler than a hook, and it
  avoids turning free cash into penalty-bearing principal.
- **L-4 — fixed.** The activation allowance is pinned into the intent at creation instead of
  being re-derived at the live price on every poll. A `Fund` leg polls forever by design, and
  the allowance is denominated in tokens, so a price rise used to lift the completion
  threshold above a credit whose fee had already been deducted at the older price — a
  permanent stall. Kept the funded-gate caveat: it only bites under a DIR-denominated fee.
- **Settlement-token identity — fixed.** Binding now rejects a settlement descriptor that is
  not the venue quote asset. The audit flagged this in its residual list rather than as a
  finding, but its failure mode is an unhealable freeze on every perp-bearing vault, not a
  mispricing, so it is closed here.
- **`lockPrices` zero-price refusal — dropped.** Nothing consumes the recorded price since
  C-1, so the all-or-nothing refusal protected nothing while letting one dead co-listed feed
  block reporting and claiming for the whole pool.
- (superseded) **L-4** — the activation allowance re-derived at the live price fires only under a
  DIR-denominated activation fee, which is a funded gate.

## Documents updated

`spec/HAZARDS.md` (B4 rewritten to the valuation-side rule), `spec/SPECIFICATION.md` (§5 single
price basis + zero-price rule; §8 `profit` on one basis), `spec/REQUIREMENTS.md` (§5 lifecycle
step 5), `spec/SECURITY_MODEL.md` (§3: settlement-instant discretion, weight finality, contract
size), `ARCHITECTURE.md` (new "Settlement valuation" section), `INVARIANTS.md` (invariants 19 and
20 — **weight integrity had no row at all**, which is why C-1 survived eight rounds — plus five
regression rows), `docs/02-core-concepts.md`, `docs/03-contracts.md`, `docs/04-integration.md`,
`docs/08-keeper.md`.

## Adversarial review of the refactor

The refactor was reviewed by four independent lenses (delegatecall/storage layout, factory
authority and registry integrity, the H-1 transient-storage fix, and what the green suite does
NOT cover), each finding then put through a refuter. **16 raised, 9 survived: one low, eight
info. Verdict: safe to keep, nothing blocking.**

The two things that could have been catastrophic were verified directly rather than argued:
compiler-emitted storage layouts are byte-identical across the whole factory delegatecall
family (`_settlement` 0-1, `isPool` 2, `isVault` 3, `poolDeployer` 4) and across
`B4Vault`/`B4VaultOps`/`B4VaultRecovery` (31 slots); and `msg.sender` at the deployer is the
factory under both the direct call and the delegatecall frame, so `B4Pool.factory` is exactly
what inline `new B4Pool(...)` produced.

Everything actionable was then closed:

| item | action |
|---|---|
| transient slots never cleared | `capturePenalty` now zeroes each slot as it consumes it, so a missing or already-used snapshot reads 0 and the value falls through to claim inventory — fail-safe **by construction**, not by call-site discipline |
| `ops_ == recovery_` accepted | rejected; equal modules would have bricked every cold-path dispatch on an implementation that cannot be redeployed for existing clones |
| dead `_requireIdleFlat` in `B4VaultOps`; duplicated `IB4PoolVault` in `B4VaultRecovery` that had **already diverged** | both deleted, with the unused imports |
| `poolDeployer` had no getter | made `public` — it is the one trust input the split introduced, so it must be verifiable on-chain |
| deploy script omitted `B4ProductFactory`, logged nothing, asserted nothing | both factories now deployed in one frame from the **same** deployer, with wiring assertions and address logs |
| `ZeroOps`, `ZeroPoolDeployer`, `NotDelegated` had zero hits in `test/` | `RefactorGuards.t.sol` — 8 tests |
| `B4Pool.factory` is now self-declared | pinned by `test_impostor_pool_may_name_the_real_factory_and_gains_nothing`; the stale "each pool's factory is its creator" claim corrected in the audit report and flagged in `docs/04-integration.md` |

One residual accepted and recorded in `SECURITY_MODEL.md` §3: the begin→capture window is not
atomic, so a callback-bearing basket token could have unrelated value counted as an exit's
receipt. Out of the honest-ERC20 model, bounded to moving value between a sleeve and claim
inventory, never out of the pool.

## Process note

The audit's own recommendation for its highest finding was wrong, and only measurement caught it.
Two things generalise:

1. **A C-1-class regression must crank between the deposit and the settle.** The originally
   planned tests did not, and would have gone green while the exploit was live — the same
   false-assurance pattern the audit criticises elsewhere.
2. **The invariant campaign is structurally blind here**: it runs a legacy pool
   (`policyMask == 0`), sets `setAuto(true,true,true)` (collapsing the async window that all of
   HAZARDS A exists for), bounds price away from zero, and reads none of `entryLedgerWad`,
   `rewardBaseWad`, `weightOf` or `totalWeight`. Four of the six top findings are invisible to it
   by construction. Fixing that is a prerequisite for trusting the next round, not a follow-up.
