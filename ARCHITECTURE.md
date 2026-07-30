# B4 — implementation architecture & design decisions

Clean-room implementation of the specification package now in [`spec/`](spec/) — see
[`docs/design/CLEANROOM-HANDOFF.md`](docs/design/CLEANROOM-HANDOFF.md) for the terms the build
was handed over on. This document is
normative for the implementation (HAZARDS G3): every place the package left freedom — or
contradicted itself — the resolution is recorded here, in the same change as the code.

## Contract map

| Contract | Role |
|---|---|
| `HalvingOracle` | Immutable LayerZero receiver of the proven halving fact (E1–E4); genesis fact anchored in the constructor; one-shot delegate renounce. |
| `HalvingProver` (Citrea side) | Permissionless publisher: verifies `dSHA256(header)` against the Citrea light client, sends `(height, header)`. |
| `B4Factory` | Permissionless pool creation + atomic vault clone/init (F3). Holds the settlement descriptor; no funds, no owner. |
| `B4ProductFactory` | The strict-product deployment path, on the same terms (no owner, no post-deployment control). `createProductPool` refuses to run before the oracle carries a proven halving fact, and creates the pool, its one-shot policy configuration and **every** sleeve in one transaction. |
| `B4ProductPoolCreator` | Delegatecall module of `B4ProductFactory` (shared `B4FactoryStorage` prefix): verifies each directional descriptor, deploys the pool via `B4PoolDeployer`, calls `configurePolicies`, then clones and registers one sleeve per (enabled product × directional asset). Admits only masks 1/2/4/8/15. |
| `B4FactoryVaultCreator` | Delegatecall module shared by both factories (same storage prefix): the common validate/clone/init/register path for a user vault. |
| `B4Pool` | Shared reward basket: interval materialization from the calendar, the report-window marker (`lockPrices` — informational prices only since C-1, D1), liability discipline (D2–D5), weights, claims/forfeits, sweep, capture. In a strict Product Pool it additionally holds the second escrow book (`penaltyEscrow`/`escrowHeld`, D6) and the write-once sleeve registry (D7). |
| Product **sleeve** (clone) | A pool-owned `B4Vault` clone, one per (product, directional asset), created only by `B4ProductPoolCreator`. Its `owner` **and** its `pool` are the pool itself; scale 1, the canonical `(growth, fall)` pair, 100 bps slippage, empty fee route. Registered `isSleeve` and deliberately **not** `isVault`, so it can never report or forfeit weight, or capture a penalty. |
| `B4Vault` (clone) | Isolated per-user vault. Its address **is** the Core execution identity. Deposits, policy, crank entry, intent verification, emergency clear. |
| `B4VaultEngine` | The async engine (abstract base): intent creation/verification per HAZARDS A, sync planner, reconcile. |
| `B4VaultOps` | Delegatecall module (immutable address in the implementation): planners' step dispatch, settle, exit finalize. Code organization for EIP-170 — **not** an upgrade path; nothing can repoint it. |
| `B4VaultRecovery` | Second delegatecall module on the same terms: the cold path — owner surplus recovery and deferred-payout retry. Split out of `B4VaultOps` when that contract fell to ~90 spare bytes. |
| `B4PoolDeployer` | Holds `B4Pool`'s creation code **once**. Both factory paths call it instead of running `new B4Pool(...)` inline, which used to embed ~18 KB in each. Deployed once, passed to the factories by address; no owner, no state. |
| `Keeper` | One permissionless crank for every step (G2). |
| `ReferenceStrategies` | Mini / B4 / Pro / Pro Max as `(growth, fall)` pairs. |

Custody model: steady-state custody is on the EVM side; Core holds only perp margin and
in-flight amounts. Every spot trade round-trips EVM→Core→EVM with every arrow proven
(SPEC §7).

## Async discipline (HAZARDS A) — where each rule lives

- **A1 prove-then-credit** — all completion in `B4VaultEngine._verify*`; only measured
  deltas are credited.
- **A2 reliable balance** — completion keys: spot net-decrease (`ToPerp`), spot
  net-increase ≥ amount (`FromPerp`), net-decrease + EVM receipt (`Return*`). The perp
  `withdrawable` is used **only** to size clamps, never as a completion/retry counter.
- **A3 exact complement** — every resend condition is `!completion ∧ timeout` on the same
  reads; resend re-arms the timeout so at most one emitted action is live.
- **A4/A5 harvest quota** — `pendingHarvest6` gates nothing; settlement is
  `min(claim, available-now)` and always clears the whole claim; the residual becomes
  recoverable surplus.
- **A6** — `emergencyClearRecovery` accepts only `Recover*` intents.
- **A7** — `Return*` legs never resend once the source decreased.
- **A8** — `Fund*` legs poll forever; no resend, no abandon.
- **A9** — first-credit completion threshold is `amount − activation allowance` (constant
  `ACTIVATION_FEE_USD_WAD = $5`; exact live fee is a funded gate).
- **A10** — margin return, exit realization, loss reconciliation all require raw
  `szi == 0`; the epsilon band applies only to non-zero rebalance targets.
- **A11** — credits capped at intended amount and price envelope both directions;
  favorable overfill and donations stay unaccounted and recoverable.
- **A12** — timeouts only schedule measurement/resend; no accounting is ever finalized by
  time.
- **Sleeves inherit all of it.** A product sleeve is an ordinary `B4Vault` clone running the
  ordinary engine, so every rule above applies to it unchanged, through the same code. The
  pool-side steps around it (`beginPenalty`, `capturePenalty`, `foldPenalty`, `crankSleeve`)
  are synchronous ERC-20 movements measured by receipt (B1/D2/D6/D7) — no venue action, so no
  async completion key exists on that side. See the strict-product section below.

## Deliberate spec resolutions (applied to the package)

Both resolutions below were confirmed by the product owner and applied to the package on
2026-07-18 (SPECIFICATION.md §4/§9, WHITEPAPER.md §4, TEST_PLAN.md §3b) — the package and
the code now state the same behavior (HAZARDS G3).

1. **Same-sign target interpolation (SPEC §4 vs REQUIREMENTS §2 Mini).** The literal
   piecewise `growth→0→fall` interpolation would force Mini (1,1) to sell everything and
   buy back at every transition, contradicting "markets used: none after deposit" and the
   whitepaper's "hold spot, no trade". The normative *purpose* of the zero split is that a
   **derivative sign change** always passes through a verified zero. Resolution: pairs
   with strictly the same sign interpolate directly `growth→fall` across the full
   transition (Mini ⇒ constant, zero trades); pairs with opposite signs or a zero
   endpoint use the piecewise split at zero exactly at the settlement points.
   (`Calendar.targetAt`; `testFuzz_sameSign_direct_interpolation`.)

2. **Exit reward-base C (SPEC §9).**
   `nextRewardBase = (R+C)·(1−x)` with C read as the
   *full-vault* client share lets repeated dust exits mint unbounded weight
   (x→0 ⇒ R += C each time), contradicting §9's own "repeated partial exits MUST NOT
   create or duplicate reward weight". Resolution: C is the **exiting share's** client
   share (`clientShare·x`), symmetric with the "proportional operator cut" in the same
   sentence. The remaining share's open profit settles at the next checkpoint — each
   share's profit earns client-share exactly once.
   (`B4VaultOps._finalizeExit`; `test_repeated_partial_exits_no_weight_duplication`.)

   **The order-dependence, and the trigger that replaced it.** The defect was real: `settle`-then-`exit` kept the pool-side claim (the pool is never notified of
   an exit) while `exit`-then-`settle` never reported one — the same economic event with
   opposite outcomes by call order, and the loser was whoever did not know the order. The first
   attempted fix lifted the realised share out from under `keep`
   (`nextRewardBase = R·(1−x) + C·x`), converging the two orders on **keeping** the weight.
   That was reverted. It inverts the product's own model — the basket is funded by leavers for
   the benefit of stayers, so a vault holding no capital must not hold a claim on it — and
   "weight survives a full exit" re-opens the clone-recycling shape of C-1. The ledger formula
   is therefore the strict contraction `nextRewardBase = (R + C·x)·(1−x)`, and the two orders
   are converged on the **pool** side instead: `B4VaultOps._finalizeExit` calls
   `B4Pool.scaleWeight(id, keep)`, lowering the already-reported weight and `totalWeight` by the
   same amount. Two properties it is built to preserve, both
   load-bearing: it is confined to `block.timestamp <= reportDeadline(id)` — exactly the window
   in which `reportWeight` is allowed and in which `claimFor` still reverts `ReportWindowOpen`,
   so the two windows are strictly disjoint and `totalWeight` never moves while claims are open
   (D2/D3); and every non-applicable case is a silent `return`, never a revert, because it sits
   on the permissionless crank path and there is no admin to unstick a freeze (H3, F1).

   **The trigger must not be a boundary (AUDIT-2026-07-29 F1).** An exact-equality test on
   `keep == 0` reads a number the vault owner supplies, so
   `initiateExit(WAD − 1)` paid out every unit of the position but flooring dust and kept **100%**
   of the reported claim — a departed vault collecting a full pro-rata share of a basket funded by
   other participants' penalties, with every stayer diluted by exactly that amount. It now scales
   by `keep` on **every** exit, so reported weight tracks the capital still standing behind it and
   a full exit is the endpoint of a ramp rather than a distinct rule. Two things this deliberately
   is *not*: a threshold (every threshold has its own "just above", so relocating the boundary
   changes nothing), and a measure taken from the post-exit base (`(R + C·x)·keep` is re-inflated
   by the exiting share's own unsettled profit, whose timing the owner controls — measured: a
   vault paid out 99.2% of its holdings and retained 100% of its weight). Repeated exits compound
   multiplicatively, because each call re-reads the live weight, so splitting cannot dodge it.
   This reverses the recorded decision that "a partial exit forfeits nothing": a partial exit now
   surrenders exactly the share it withdrew.

   Still bounded: the accrual is a contraction, so no exit pattern accrues more than one
   settle's client share. Two residuals are asserted rather than hidden — a vault that settles
   AFTER emptying itself has `entryLedgerWad == 0`, so the flooring dust the exit waterfall
   left behind reads as profit and reports a dust weight, pinned below one part per million of
   a real participant's share; and an exit finalized past `reportDeadline` scales nothing, since
   the window confinement above takes precedence, so the rule holds inside the report window
   rather than forever. (`AuditHalfB_ExitWeightOrder.t.sol` ×6, `Exit.t.sol`,
   `V6B_ExitFairness.t.sol`; `INVARIANTS.md` rows 21–22.)

## Structural anchors: which window feeds which stop (AUDIT-2026-07-25 H-4 / M-3)

Two corrections, both about the anchor a leveraged position is sized against.

**H-4 — the L-halving long anchors on `floor`, not `cap`.** STRUCTURAL-STATE-MACHINE §3 is
normative: `stop_day = p_day − (p_day − B)/φ` with `B` = the 62-min, worked as
`[p=3000, B=850 → 1671]` (row PM5). The 62-min is what the halving flip promotes into
`floor`; `cap` inside `[0, W)` holds the still-forming minimum of the CURRENT post-halving
window. Passing `cap` put a near-price value in the delta slot — `p − cap` is small by
construction, since both come from the same window — and because `L = p/(p − stop)`, that
drove leverage to the venue clamp at any price at all. The density gate did not catch it: it
confirms only that the window's own minimum was sampled enough, never that the minimum is a
structural bottom. Regression asserts the realized LIQUIDATION PRICE, not the order size.

**M-3 / F2 — the PEAK anchor is the max over daily CLOSES, corroborated; the LOW is deliberately
not mirrored.** The density gate counted days but the peak's value ratchet ran on every call, so a
caller could wait for a wick and move a confirmed peak for free. The harm lands a full cycle
later: `peakC` is promoted to `prevPeak`, the short's delta anchor, and an inflated `Pp` shrinks
`(C − Pp)`, pulling the stop toward `C` and RAISING leverage.

The first remedy tied the peak's VALUE to the density counter's daily slot — and that created the
opposite finding. The slot is claimed by whoever calls first after `last + 1 day`, so a squatter
taking every slot at an intraday low had every honest observation of the true high refused while
their own samples kept the count growing: `peaks()` served a density-CONFIRMED but SUPPRESSED
peak, and a suppressed `C` pulls the stop toward the price and raises leverage *this* cycle
(AUDIT-2026-07-29 F2). The peak side is therefore exposed in both directions, which is exactly
what the low side is not.

Both halves now exist, and they are separate mechanisms on purpose. **Density counting** stays
daily and answers only "was this window observed?". **Value binding** is confined to a daily
CLOSE window on a grid anchored to the sampling window's own opening — a fixed, public instant,
which is the one discriminator neither the caller's identity nor the gap since the last sample
provides — and a level must be reached at **two distinct close-days** before it is served or
promoted. The close window is what makes suppression impossible and kills the off-close wick;
corroboration is what makes a single at-close print worthless. This is the dispersion remedy the
audit prescribed twice and that was never built (REVIEW-2026-07-25 item 11); leaving it unbuilt
is what turned an unfinished defence into a new finding. The costs are stated in
`SPECIFICATION.md` §7b: a top printing at exactly one close is served one close late, and a fixed
instant is predictable. Both understate `C`, which lowers leverage — the conservative direction.
The low side is NOT the mirror of this, because the two anchors fail in opposite directions. A
lower recorded `cap` moves a long's stop FURTHER from price and LOWERS leverage, so the low
ratchets on EVERY observation, exactly as `sampleAnchor`'s own contract states ("sampling MORE
lowers the recorded low and therefore lowers leverage; the pool benefits from an accurate low").
Gating it daily would let a real intraday crash go unrecorded and keep structural longs levered
against a low the market had already broken. Only the density COUNT stays daily on both sides —
that gates confirmation, not value.

## Strict Product Pools: escrow, sleeves, and the ordering that attributes a receipt

The strict-product subsystem — `B4ProductFactory` → `B4ProductPoolCreator` → the pool's second
escrow book (`penaltyEscrow` / `escrowHeld`) and its per-product **sleeves** — implements SPEC §9's
penalty routing and §10's escrow separation. It shipped without any entry in this document; the
resolutions the code actually enforces are recorded here, and the two design requirements it
exists to satisfy are now `HAZARDS.md` D6 (escrow is not liability) and D7 (attribute a MEASURED
receipt).

**What a sleeve is.** One pool-owned `B4Vault` clone per (enabled product × directional asset),
created in the same transaction as the pool. `owner` and `pool` are both the pool address, scale
is `1`, the `(growth, fall)` pair is that product's canonical reference pair, slippage is 100 bps
and the fee route is empty. It is registered `isSleeve` and deliberately **not** `isVault`, so it
can never `reportWeight`, `scaleWeight`, `beginPenalty` or `capturePenalty` — a sleeve is
capital being carried, not a participant with a claim. It runs the ordinary engine at the
ordinary live price against the ordinary confirmed anchors, so a Pro/Pro Max sleeve is
indistinguishable from a client vault opened at that moment; it is not an operator-chosen trade.

**Creation ordering — atomic, and only at deployment.** `createProductPool` refuses to run before
the oracle carries a proven halving fact. The mask must be one of the five product choices
(1/2/4/8 isolated, 15 aggregate; a partial mixed mask would be an unspecified sixth economics and
is rejected). Every directional descriptor is verified against the venue *before* the pool
exists. `configurePolicies` is one-shot and checks that each enabled policy's strategy is
non-zero, not already bound, and returns exactly that product's canonical pair. Only then is one
sleeve per (policy, directional asset) cloned and registered. `registerSleeve` is factory-only
and refuses an already-occupied slot, so `sleeveOf[policy][dir]` is **write-once**: no caller,
ever, can repoint where a penalty goes.

**Attribution ordering on a non-free exit (audit H-1).** `_finalizeExit` runs, in this order:

1. `pool.beginPenalty()` — snapshots the pool's balance of every whitelisted asset into
   **transient** storage as `balance + 1` (so `0` means "no snapshot"), immediately before any
   token moves;
2. `_payBucket` pays owner / operator / pool in kind, so the pool's share physically arrives;
3. `pool.capturePenalty()` — per asset: `delta = balance − liability − escrowHeld` (the only
   genuinely unattributed amount), `received = balance + 1 − snapshot` (this exit's **measured**
   increase), and `escrowable = min(delta, received)`. The snapshot slot is **cleared as it is
   read**, so a missing or re-used snapshot yields `received = 0` and the whole amount falls
   through to claim inventory — the safe direction — by construction rather than by discipline at
   the one paired call site.

Eligibility is the exiting vault's own immutable key: only asset `0` (settlement) and
`dirIndexOfVault[vault]` may become `penaltyEscrow[policy][dir][i]`. Whatever is left over — a
co-listed donation, another vault's uncaptured penalty, returned sleeve capital — becomes
ordinary claim inventory (`accruing` + `liability`), because every recorded balance must keep a
reachable drain path (`test_non_matching_whitelisted_token_stays_generic_inventory`). Both
pool-side calls are `try`/`catch`ed from the vault: a pool-side failure can never freeze an exit
(H3), and the tokens are already in the pool for a later `capture()`. A **free**-window exit has
`poolWad == 0`, so neither call is made and no sleeve trade is created — including throughout the
20-day post-halving window (SPEC §9).

**Escrow is a second book, not liability.** `escrowHeld[token]` and `liability[token]` are
disjoint; `_unaccounted` subtracts both, and `claimFor` computes its shortfall against
`balance − escrowHeld`. Without that split a live Pro Max sleeve would haircut an unrelated Mini
claim in the same pool for capital that is merely in flight (SPEC §10). The pool-wide invariant
is `balance ≥ liability + escrowHeld`.

**Fold and return ordering.** `foldPenalty(policy, dir)` is permissionless but takes only the
**key** — never an address, route or recipient. Effects first: zero `penaltyEscrow`, decrement
`escrowHeld`, then approve → `sleeve.deposit` → reset the approval to `0` → `sleeve.crank()`. Any
failure reverts the whole call and restores the escrow atomically, and `escrowHeld` falls exactly
with the physical transfer, so claimants' shortfall ratio is unchanged across the fold.
`initiateSleeveExit` is admitted only inside `Calendar.freeExit`, which is what keeps a sleeve's
own exit penalty-free and non-recursive; because the sleeve's owner **is** the pool, its realised
capital is paid back to the pool, and `crankSleeve` captures it into ordinary claim inventory
only after it has physically arrived (measured receipt, D2). `Keeper._crankProductSleeves` drives
fold → sleeve-exit → crank for every (policy, dir), each isolated in `try`/`catch` and bounded by
4 × `MAX_DIRECTIONAL`.

**The one discretion this leaves is timing.** `foldPenalty` opens a real leveraged position at
whatever price the block it lands in carries, and the structural stop is re-derived there — see
the crank-timing residual in `SECURITY_MODEL.md` §3.

## Contract size is a design constraint, not an afterthought

Two structural facts, both discovered the hard way when accepted audit fixes would not fit:

- `B4Vault` and `B4VaultOps` **both** inherit `B4VaultEngine`, so every byte added to the
  engine is paid twice.
- `B4Pool`'s creation code was embedded in **both** `B4Factory` and `B4ProductPoolCreator`,
  which meant the pool's own ~8 KB of apparent headroom was unusable: any byte added to the
  pool overflowed the creator instead. Nothing recorded this anywhere.

Both are now split (`B4PoolDeployer`, `B4VaultRecovery`), and `Eip170Sizes.t.sol` guards every
deployed contract and prints headroom, so the next overflow fails legibly instead of killing
the suite at fixture setup. Before/after, bytes free:

| contract | before | after |
|---|---|---|
| `B4VaultOps` | 92 | 1,991 |
| `B4ProductPoolCreator` | 38 | 18,158 |
| `B4Factory` | 326 | 18,473 |
| `B4Pool` | 8,393 (unusable) | 8,025 (real) |
| `B4Vault` | 515 | 313 |

`B4Vault` is now the tightest and is the one to watch.

## Settlement valuation: one price basis (AUDIT-2026-07-25 C-1), at one instant (F4)

Settlement values the vault's composition and its price **together, at one instant**, not at the
interval's locked checkpoint price. This is a **correction**, not a preference.

`_navWad` reads the vault's composition at call time. Pairing that with a price fixed up to
three days earlier meant every composition change inside the report window was measured against
a stale reference, and the gap read as interval profit that no capital earned. The window is
precisely when the calendar *requires* composition to change — `Calendar.targetAt` is exactly 0
at the settlement point and ramps immediately after, so a flattening product sells and a spot
product buys, both at live prices. `deposit` and the permissionless `crank` both reach that
window; the crank never touches the entry ledger, so no deposit-side rule can close it. Only a
shared basis can. `_finalizeExit` already valued at the live price (decision C2), so this also
removes a second harvestable gap between settle and exit.

**Which instant, though, was left to whoever called `settle` — and that was AUDIT-2026-07-29 F4.**
The C-1 fix answered *what* to pair; it left *when* open, anywhere in the three-day report window.
Because the interval is one-shot (`lastSettledPlusOne`), a third party could settle every other
vault in the pool at a local trough, pinning each victim's minted weight at a minimum with no
second attempt, and settle their own at a peak. The mitigation the `Calendar` docstring records
for `lockPrices` — the harmed party calls it at `pointTime` and removes all discretion — no longer
transferred, precisely because C-1 had stripped the locked price of any valuation role.

The instant is now its own act: `B4Vault.snapshotNav(id)` captures the NAV and the price it was
measured at, one-shot per interval, permissionless, confined to `Calendar.SNAPSHOT_WINDOW`. Settle
values off that capture and refuses (`NavNotSnapshotted`) rather than substituting a later price.
Three properties make this affordable. The owner pre-empts by capturing at `pointTime`, which is
the `lockPrices` argument restored verbatim. Reporting liveness is untouched — the weight report
still has until `reportDeadline`, and settle captures the instant itself when it runs inside the
window, so the ordinary keeper path is still one call. And the stored price is what the in-kind
operator cut values the basket on, so a settle running a day after the capture does not pay a fee
computed from one price against a NAV computed from another — the C-1 mismatch in miniature.

What was deliberately not done: freezing a shared per-interval price (that *is* C-1, and it
measures at 83.3% of the basket mis-minted), and restricting the settle *caller* instead of the
instant (an owner-preferred window destroys the uniformity that makes a keeper's single pass
harmless, and hands every owner a repeatable, unpreemptable slice to pick their own peak).
The residual, rated LOW: inside the settlement day an un-pre-empted vault's instant is still
whoever-calls-first, costing one interval's *increment* rather than the standing base.

`lockPrices` is retained solely as the marker that opens an interval for reporting
(`lockedAt` gates `reportWeight`, `scaleWeight`, `claimFor` and settle's window); the recorded
`lockedPxWad` no longer feeds any valuation. That queued cleanup is now **done**: because nothing
consumes the record, the lock no longer refuses a zero read. It writes the settlement price as
the fixed `1 USD` (C3), writes whatever each directional asset resolves to — a dead feed simply
records `0` — and commits `lockedAt` unconditionally inside the snapshot window. The
all-or-nothing rule it replaced defended a valuation that no longer exists, while costing the
WHOLE pool its report and claim window whenever ONE co-listed asset's feed blinked
(`test_checkpointPrice_zero_on_one_asset_cannot_block_the_pool`). `HAZARDS.md` D1 now states the
rewritten requirement: the lock marks an interval reportable, and MUST NOT be a valuation basis.

Accepted residual, recorded in `SECURITY_MODEL.md` §3 as **settle-timing discretion**: with no
frozen reference, whoever calls the permissionless `settle` picks the instant and so the price.
The bound is the settle window itself — from the interval's `pointTime` to
`reportDeadline = pointTime + 24h snapshot + 2d report`, i.e. at most three days, and never
earlier than the `lockPrices` that opens it. Two vaults holding the same directional asset that
settle at different moments of that window therefore report different weight for the same
interval; the owner accepts this, because mark-to-market on a real holding is real profit. It is
bounded further in practice: the keeper settles every vault of a pool in one pass (one block, one
price), and the basket is distributed pro rata, so a uniform shift cancels and only *differential*
timing has any effect. A relative-weight fairness question, never a mint — measured profit is
always the vault's real P&L against what it actually paid.

## Settlement cadence (derived, then fixed)

Settlement points are the two fixed, product-independent instants per epoch: `t = P−H`
and `t = T+H`. Derivation: for sign-changing pairs (opposite signs or a zero endpoint)
these are the target zero-crossings — SPEC §8's "reject a still-wrong-sign perp" and the
*realized*-profit measurement are exact precisely where the previous regime's derivative
exposure has unwound through the verified zero. Same-sign pairs (resolution 1 above)
never visit zero: they pass through the same instants with their right-sign exposure
legitimately open — the wrong-sign gate passes (sign matches the current target), the
valuation uses recorded principal (B3), and the fee is taken in kind on interval profit.
The interval that starts at `T+H` spans the epoch boundary and ends at the next epoch's
`P−H` (E4). A superseded epoch's unreached points are skipped by construction
(`lastPointTime` monotonic; zones follow the latest fact); a missed point degrades to an
unreportable interval whose inventory sweeps forward — delayed liveness, never a freeze
(H3).

## Fixed windows and constants (chosen where the package gave none)

| Constant | Value | Source |
|---|---|---|
| Snapshot window | 24 hours (the settlement day) | chosen; SPEC §6 requires a fixed window. Since C-1 the lock feeds no valuation, so the width is a **pure liveness** choice, not a price-discretion one: the point recurs only once every ~1–1.5 years, and an hour leaves no room to recover from a dead cron, an unfunded gas wallet or an RPC outage. Missing it defers settlement, never destroys it (`SnapshotWindow.t.sol`). Since F4 this window also bounds the settlement VALUATION instant, because `snapshotNav` is confined to it — see settle-timing discretion above |
| Report window | 2 days after snapshot | chosen; liveness-only |
| Distribution window | until the next interval materializes; then single sweep | chosen (D4) |
| Post-halving free-exit window | 20 days (= W) | chosen ("a fixed window", SPEC §4) |
| `RESEND_TIMEOUT` | 1 hour | chosen; venue drops unexecuted actions far sooner (funded gate) |
| `EMERGENCY_TIMEOUT` | 3 days | chosen (A6) |
| Rebalance dead-band | max(1% of strategy value, $10) | chosen; venue min order $10 (SPEC §7) |
| Perp envelope | 50 bps of mark | SPEC §7 (given) |
| Spot slippage cap | ≤ 500 bps, per-vault | SPEC §7 (given) |
| Activation-fee allowance | $5 on the first credit | chosen (A9); funded gate |

## Economic decisions (HAZARDS §C — resolved with the product owner, 2026-07-18)

- **C1**: positive funding is **not** taxed. Harvest credit is bounded by snapshotted
  mark-PnL, so funding surplus never enters the realized ledger; it is owner-recoverable
  surplus. Funding losses are still borne — documented asymmetry.
- **C2**: mid-interval exit profit **does** earn pool weight (unified fee mechanism;
  client share per resolution 2 above; penalty is separate logic on top). Valued at the
  live oracle — by design not snapshot-protected; economically inert under a deep venue.
- **C3**: fixed `USDC = 1 USD`; no depeg cross-check (no second trust dependency, no
  halt path).
- **C4**: no independent oracle sanity band; the 500/50 bps execution envelopes are the
  defense; the venue oracle is a disclosed trusted dependency.

## Keeper runbook (G2)

`Keeper.crank(pool, vaults, maxVaultSteps)` performs, in order: `pool.advance()` (all
passed points), `lockPrices(latest)`, a bounded `sweep` catch-up window (`SWEEP_LOOKBACK`),
`capture()`, then per vault via self-guarded external wrappers: `crankVault()` (intent
verify / sync step / exit step / finalize, ×N), `settleVault(reportable)`,
`claimFor(latest interval only)` (older intervals are swept forward before they fall behind,
so claiming `count−2` is a no-op — V3-VENUE-5), and `retryDeferred()`. Each per-vault call is
wrapped in `try this.crankVault/settleVault/retryDeferred` so a malformed or **codeless**
`vaults[]` entry is isolated and never rolls back the pool steps or other vaults (V4-VENUE-1).
Run it on a schedule (minutes-level during transitions, and always promptly after each
settlement point to hit the 24h snapshot window — lock early, at `pointTime` where possible).
Every call is permissionless; a stalled
step never blocks the others.

## Payout liveness and settlement valuation (hardening, 2026-07-18)

- **Pay-or-defer.** Every settle/exit payout (owner, operator, referrer, pool) is
  try-transferred; on failure (e.g. a USDC-blacklisted recipient — blacklistable
  settlement is in-model, SECURITY_MODEL §4) the amount is recorded as a deferred payout
  instead of reverting: a recipient's transfer failure can never freeze the vault (H3).
  `claimDeferred(recipient, token)` is a permissionless retry paying only the recorded
  recipient (F2); the keeper retries it each crank. Deferred amounts stay accounted and
  are excluded from unaccounted-EVM recovery.
- **In-flight funding at settlement.** An EVM→Core Fund leg is the only intent whose value
  is in neither bucket mid-flight (EVM debited at send, Core credited at proof). An earlier
  design valued this in-flight amount explicitly at settlement (a `_inFlightFundWad`
  helper). That approach was **superseded** by the settle-requires-idle hardening below
  (RAW-A-001): `opsSettle` now reverts `IntentPending` while any intent is in flight, so a
  valuation never runs mid-Fund — there is no in-flight amount to value and no
  `_inFlightFundWad` symbol in the code. The mid-flight "phantom profit" concern is
  therefore prevented structurally (by never valuing a non-idle engine) rather than by a
  special-case correction, and the later Core credit is still capped at the sent amount
  (A11) so it can never double-count. Regression: `test_settle_requires_idle_then_no_phantom_profit`.

## Discovery-report hardening (2026-07-18, see `docs/audits/REGISTRY.md` adjudication)

- **Settle requires an idle engine; reconcile only ever runs at idle.** `opsSettle`
  irreversibly pays the operator fee in kind and reports pool weight, so it must value a
  settled ledger — it reverts `IntentPending` if any intent is in flight. Since every
  valuation caller (settle, exit-finalize, the sync/exit planners, recovery) is idle,
  `_reconcile` is a plain flat-check: at idle the withdrawable moves only for real reasons
  (an order's realized PnL / liquidation), never for a transfer of our own, so the B2
  write-down is always a genuine loss and can never reclassify returning principal as
  fee-bearing profit (finding RAW-A-001, and the adversarial coincident-loss race). The
  report window (>2 days) dwarfs intent completion (~1h resend), so requiring idle costs
  nothing in practice; only an ecosystem venue failure could stall an intent past the
  window (documented liveness residual, H3). Spot-only vaults skip reconcile entirely (no
  perp principal, no perp precompile read).
- **Order sizes clamp, and funding respects the Core-balance ceiling.** The fixed-1e8 writer
  size field is uint64; a micro-priced asset held in the tens of millions of USD would
  overflow `lots·10^(8−szDec)`. The sell/fund sizing clamps to `uint64.max` instead of
  wrapping (V3-ACCT-2) — the delta-measured engine re-derives and chunks the move across
  cranks, so a reduce-only flatten still reaches raw zero (A10). A Core **spot balance** is
  itself uint64, so the chunked fund must also respect that ceiling: `_startFund`
  headroom-caps every EVM→Core credit by the live Core balance
  (`headroom = uint64.max − _spotBal(coreToken)`; zero headroom ⇒ the Core side is full and
  is sold down first, no deadlock), covering the sell/buy/margin legs symmetrically
  (V4-ENG-1 — the completion of V3-ACCT-2, which had funded a second `uint64.max` chunk on
  top of a sub-lot residue and overflowed). Binding also rejects `spotSzDecimals > 8`,
  `perpSzDecimals > 6`, `spotSzDecimals > coreWeiDecimals`, a wei/EVM decimal spread `> 30`,
  `coreToken > uint32.max`, and nonzero perp fields on a NO_MARKET descriptor (latent
  exponent-underflow / id-alias traps).
- **CoreWriter units.** Order `limitPx`/`sz` are emitted in fixed-1e8 (human × 10⁸) —
  deliberately different from the szDecimals read conventions; the mock enforces the same
  asymmetry and exact-calldata regressions pin the emitted bytes. Funded gates §5.4–5.
- **Spot-only vaults.** The NO_MARKET sentinel never reaches the position precompile;
  such a vault is permanently, strictly flat, supports spot products (Mini/B4), and a
  perp-bearing policy degrades to its spot component (disclosed).
- **Extended perp ids.** `perpMarket > uint16.max` (HIP-3 style) is rejected at binding —
  the legacy uint16 position read would alias an unrelated market. Supporting them needs
  the wide position read confirmed on the funded venue.
- **SafeTransfer.** Return data parsed manually; `tryTransfer` cannot revert on malformed
  bytes — the D5 fail-soft claim path and pay-or-defer survive grief tokens.
- **Shortfall flooring (accepted).** Pro-rata haircuts floor per claim; later claimants
  may pick up prior claims' sub-unit dust (bounded by ~1 wei per claim per token,
  protocol-favoring per B5). Order-independence holds to ±1 unit — not a defect.

## Known-accepted residuals (mirror of SECURITY_MODEL §3)

- A ≥-amount external top-up can fake one balance signal once; always attacker-funded,
  never freeze/theft; books stay ≤ real assets; excess is owner-recoverable
  (`test_R7_*`). Full closure needs a venue action receipt/nonce (funded).
- A permanently dropped EVM→Core bridge credit stalls that vault's engine (A8) — an
  ecosystem-wide venue failure by assumption, not a B4-specific state.
- Unreconciled market losses transiently overstate recorded perp margin until the next
  flat valuation (B2); self-heals on one crank (`reconcileHeals` invariant handler).
- **Settle-timing discretion.** Narrowed to the settlement day and pre-emptable (F4): the
  valuation instant is the one-shot `snapshotNav` capture, so a caller picks it only within
  `SNAPSHOT_WINDOW` and only until the owner takes it at `pointTime`. Two vaults on the same asset
  can still report different weight for the same interval if neither owner pre-empts. Real P&L
  either way — a relative-weight fairness question, never a mint.
- **Crank-timing MEV.** Every order-emitting step is permissionless and prices off the live
  venue read, so its caller picks the block and therefore the price an IOC is quoted at and the
  price a leveraged position (a vault's, or a sleeve's opened by `foldPenalty`) is sized and
  stopped against. Target, market, direction, size rule, sleeve and recipients are all fixed;
  only the moment is chosen. Envelope-bounded; worst case is a worse fill or entry — market
  risk, never custody, and the crank pays its caller nothing.
