# Design record: structural sizing — leverage bounded by confirmed extremes

**Status (2026-07-22): mechanism fully specified for BOTH sides (spec §7b) and verified on
all completed cycles; pure math + low-side ratchet shipped; engine sizing is flat-`φ` pending
the §7b redo.** A first engine wiring was written, passed a shallow test set, was reported
done — then a dedicated post-implementation adversarial audit (see
[`AUDIT-2026-07-structural-leverage.md`](AUDIT-2026-07-structural-leverage.md)) found it unsafe
and it was reverted. Two independent Critical/High clusters:

1. **The safety half was never implemented (audit C6).** The engine kept the pre-mechanism
   flat reserve `margin = notional·φ/maxLev` and only *amplified the size*. `StructuralLeverage`
   changed how big the position is, never where it liquidates — so the venue liquidation stayed
   ~4 % below entry, not at the structural stop. Every "survives COVID / survives May-2021"
   claim below holds for the **math library only**, never for the shipped sizing. `stopWad` was
   dead code. This is worse than not shipping: a bigger position at the same tight liquidation.
2. **Frozen price × live anchors detonate a held position (audit C1/C4).** `_perpMultiplier`
   read the live anchors every crank but the sizing price was frozen at entry; the two are only
   valid captured together. At the halving flip a permissionless `sampleAnchor` raised `floor`
   just below the frozen entry, the delta collapsed, computed leverage exploded to ~25×, and the
   engine force-bought into the held position — near-instant liquidation of the whole reserve.

The engine is back to flat-`φ` sizing (safe). The full mechanism — margin `= notional/L`, whole
deposit deployed, frozen price captured *with* its anchors, refusal → spot-only — is a dedicated
future round (spec §7b already describes the target; the wiring must match it and carry the
mandated regressions). Pre-mainnet, unaudited, funded-gate caveats of the whole protocol still
apply on top.

All design decisions are settled — see **Decisions (settled by the owner)** below. The short
side is symmetric (confirmed-high anchors), superseding the original "shorts flat `φ`"
scoping.

## Problem being fixed

Two defects in the shipped sizing, both in `B4VaultEngine._planPerpStep` / `_planSpotStep`:

1. **Continuous NAV-rebalancing.** Target notional is `wmul(currentNAV, |perpF|)` recomputed
   every crank with a 1% tolerance band, so the position is retraded toward a NAV-relative
   target roughly daily. The intended behaviour is **set once at entry, then left untouched
   until the calendar rotates**. The calendar *is* the rebalance schedule.
2. **No structural risk bound.** Leverage is a flat multiple with no relation to where the
   cycle's confirmed support sits, so a leveraged entry has no floor beneath it except the
   venue liquidation price.

## The mechanism

### Anchors — two confirmed structural lows, ratcheted up

The protocol already has two windows per cycle where a structural low forms. The minimum
of each is recorded on-chain by a permissionless ratchet (any caller submits; the recorded
value only moves **down** within its own window. Note the direction, corrected after the
design review: the recorded minimum is an *upper bound* on the true low, so **more sampling
lowers the anchor and lowers leverage** — under-sampling is not fail-safe on its own, and an
unsampled window installs no cap (a leveraged product falls back to the flat base `g`). A
keeper samples each window; the pool benefits from a lower, more accurate low):

- **62-window** `[T, T+W]` — the cycle bottom (bear low). Verified: 222 (2015), 3504 (2019),
  16499 (2022).
- **Post-halving window** `[halving, halving+W]` — the post-halving consolidation low.
  This window already exists as `POST_FACT_FREE_EXIT = W`. Verified: 8790 (2020).

At any moment two anchors are live: `floor` (the delta anchor) and `cap` (the stop ceiling).
They ratchet up at each structural event:

| Segment of the long phase | `floor` (delta anchor) | `cap` (stop ceiling) |
|---|---|---|
| `[T(N-1) .. halving(N)]` — recovery from the last bottom | bottom of cycle **N-2** | bottom of cycle **N-1** |
| `[halving(N) .. P(N)]` — post-halving rise to the top | bottom of cycle **N-1** | post-halving-window low |

The `cap` is always the **most recent** confirmed structural low; the `floor` is the one
before it. At the halving the previous cap becomes the new floor (the "flip"), and the
post-halving low becomes the new cap.

### Sizing

For a long entered at price `P`:

```
stop = min( floor + (P − floor) / φ² ,  cap )
L    = P / (P − stop)
notional = deposit · L
```

- The stop sits at **38.2% of the delta `(P − floor)` above the floor** — the same golden
  ratio as the calendar pivots, so the position survives a 61.8%-of-delta retrace toward
  the structural low. Zero new tuned parameters.
- **`cap` limits maximum leverage, not the right to enter.** Any `P > floor` may open; the
  `min(…, cap)` only prevents the stop from rising above the last confirmed low, so a
  position entered high enough is capped to a lower leverage. A price that has fallen back
  toward the floor simply gets a lower stop and a *structurally justified* higher leverage —
  which is correct, not dangerous.
- **Only `P ≤ floor` is refused** (no positive delta). By the user's black-swan argument,
  a fall to the absolute prior floor is Bitcoin-scam-level and warrants no leverage.

### The stop is realized by margin size, not a stop order

The protocol places no stop orders. Under a target notional `N` at leverage `L`, the perp
margin posted is exactly `N/L = deposit`, so the venue's own liquidation sits at `stop`.
Consequences, both deliberate:

- **The whole deposit is deployed.** A `1000 USDC` Pro Max deposit goes entirely into the
  position (spot + perp margin per the exposure decomposition); there is **no split-out
  reserve flow**, and none should exist.
- **On a stop, only perp margin is consumed.** The spot leg survives, so the position
  degrades to spot-only (≈ B4) with `stop/P` of the directional still held — the owner is
  left with value, not zero.

### Position is fixed at entry until the calendar rotates

Once opened, notional is **not** recomputed against NAV. The next resize happens only when
the calendar moves the target (a new zone, a deposit, or a policy change). This is the
"set-and-forget within a zone" behaviour and the fix for defect 1.

### Genesis and scope

- **Shorts are structural too** — the symmetric top-side mechanism, derived and verified
  2026-07-22, is specified in its own section below (this supersedes the original
  "shorts flat `φ`, long-only for now" scoping).
- **Genesis (first cycle): `floor = 0`, no `cap`** until the first window closes → the
  formula degrades exactly to the flat behaviour. No special-case code path. Mirrored on the
  short side: no confirmed `prevPeak` → flat base.
- **Scope: the multiplier is a property of the leveraged products** (base `> 1`, i.e.
  Pro Max on both sides). Mini/B4 never carry a perp; Pro's base is `1` on both sides and
  stays flat. The operator's route sets the base; the structural anchors set where it is
  *applicable* — together they bound realized risk.

## Verification against real data (already run)

| Scenario | Entry `P` | floor | cap | stop | `L` | Outcome |
|---|---:|---:|---:|---:|---:|---|
| June 2019 (seg 1) | 13 838 | 222 | 3 504 | 3 504 | 1.34 | survives COVID (low 3 850) |
| Feb 2020 (seg 1) | 10 360 | 222 | 3 504 | 3 504 | 1.51 | **survives COVID** |
| At 2020 halving (seg 2) | 8 759 | 3 504 | 8 790 | 5 511 | 2.70 | survives (low 8 472) |
| Apr-2021 peak (seg 2, late) | 63 044 | 3 504 | 8 790 | 8 790 | 1.16 | survives May-2021 (low 28 600) |
| Feb-2019 dip below fresh low | 3 359 | 222 | 3 504 | 1 421 | 1.73 | entry open, φ-formula |

The single raw-φ formula (no cap) would have been **liquidated in COVID** (stop 4095–5423 vs
low 3850); the cap is what saves it. This makes **"COVID-2020 survives"** and
**"May-2021 survives"** mandatory regressions.

## Decisions (settled by the owner)

1. **Structural `L` replaces the flat sizing** for leveraged products; the venue
   `maxLeverage` remains the hard technical ceiling on top (near an anchor, where the
   formula gives large `L`, the venue's limit binds first). *(2026-07-20)*
2. **The `cap` ratchets up only** — a lower low across cycles does not raise leverage.
   *(2026-07-20)*
3. **Only base `> 1` products use the multiplier** — Pro (`{1, −1}`) stays flat on both
   sides; the ladder is `{1,1}, {1,0}, {1,−1}, {φ,−φ}`. *(2026-07-21)*
4. **The short side is symmetric** (section below): confirmed-high anchors, monotone
   de-levering with depth, sub-`1×` deep entries kept (they are the safety), no far-future
   leverage cap beyond the venue max — a new contract version ships per cycle. *(2026-07-22)*
5. **Window entries are DCA slices** — one order per day across the opening half-window;
   the calendar knows *when*, not *at what price*, so the entry is the window average, never
   a limit order waiting for an extreme that may not print. *(2026-07-22)*

## Symmetric short side (added 2026-07-22, owner-derived & verified)

The short side is no longer flat `φ`. It mirrors the long: bounded by the cycle's confirmed
structural **highs** instead of lows. Owner-derived, verified on all four cycles.

### Anchors and the window

- `prevPeak` — the previous cycle's confirmed peak. `C` — this cycle's confirmed peak = the max
  over the 20-day window ending at the 38.2% pivot.
- **The 20-day window is structural, not tuned.** Width `= q² = (φ⁻³/2)²` of the cycle ≈ 20.3
  days, where `q = φ⁻³/2 = 0.118034` is the same quantum that places the 38.2/61.8 pivots
  (`0.5 ± q`). The cycle peak forms at `0.382 − q² ≈ 0.368`; verified on cycle 4 (base
  2024-04-19/20): the 38.2% pivot lands ~2025-10-26/30 and the window max is the real ATH region.

### The two regimes (because `C` is unknown until the window closes)

Let `θ = φ − 1 = 1/φ = 0.618`.

- **Opening window (days 11–20 of the peak window; longs close days 1–10, shorts open days
  11–20 by daily DCA; `C` unknown).** Each slice at price `p`:
  `stop = p + (p − prevPeak)·θ`, so `L = φ·p/(p − prevPeak)`. Anchor is `prevPeak` (known). The
  last slice (`p ≈ C`) lands on `MaxStop`, joining the next regime.
- **After 38.2 (`C` confirmed).** `MaxStop = C + (C − prevPeak)·θ`;
  `stop = max( p + (MaxStop − p)·θ,  C )`. Leverage **decreases monotonically** as the entry
  falls, exceeds `φ` only for an entry above `C`, and pins to `C` (the min stop) for deep
  entries. (An earlier draft used the window formula here and produced a spurious mid-fall
  leverage peak — corrected: the post-pivot anchor is `MaxStop` from above, not `prevPeak`.)

Worked (cycle 4, `prevPeak = 67k`, `C = 115k`, `MaxStop = 144.7k`): entry 120k → `L 7.87×`
(above `C`); 108k → `4.77×`; 97k → stop 126k, `3.29×`; 80k → `2.00×`; 60k → pinned `C`, `1.09×`;
50k → `0.77×`. Per-cycle peak-entry boost over `φ` = `C/(C − prevPeak)`: +4% / +33% / +143%
(cycles 2/3/4) — it grows as BTC matures (peak-over-peak growth shrinks). No far-future cap is
specced: the venue `maxLeverage` is the technical ceiling, and a new contract version ships per
cycle (owner decision, 2026-07-22).

### Why it is sound — two verified facts

1. **The structural stop is never hit.** Across all four cycles the fall's price never returns
   to `C` (post-pivot max is 2–23% below `C`). So the short survives the entire fall (−49…−81%
   price decline captured) with a stop that is never touched.
2. **Flat-`φ` would be liquidated; the structural stop is why deep shorts de-lever.** The
   biggest bear-market rally inside the fall was **+103%** (cycle 1, $152→$310) and **+99%**
   (cycle 2, $5,921→$11,780) — both past the `+61.8%` that liquidates a flat-`φ` short. A deep
   short pinned to the far `C` survives (cycle-1 $152 entry: `0.27×`, stop $712, the +103% bounce
   costs only ~28% of margin). So a deep entry MUST de-lever below `φ` (and below `1×`); the
   small size with a distant stop is the safety, not a defect. This retires the earlier
   "refuse `L<1`" question — `L<1` is the mechanism, kept.

### Symmetry / redo scope

The long side (§7b top) is currently the *window* regime only (anchor `floor`, bounded by
`cap`). The redo generalises **both** sides to the window + post-pivot pair above, so top and
bottom are one reflected mechanism. The long's post-pivot regime uses `MinStop = B − (B −
prevBottom)·θ` and `stop = min(p − (p − MinStop)·θ, B)` — the exact reflection.

**Bottom side verified empirically (2026-07-22), mirror holds with one caveat:**

| cycle | bottom `B` | frac of cycle | struct stop at `B` hit? | biggest recovery pullback | flat-`φ` long |
|---|---:|---:|:--:|---:|---|
| 1 | $181 | 0.532 | never | −48% | survives |
| 2 | $3,153 | 0.608 | never | **−64%** (COVID) | **liquidated** |
| 3 | $15,954 | 0.632 | never | −28% | survives |

- **Clean mirror of the top, where it matters:** the recovery **never returns below the
  confirmed bottom `B`** in any cycle (post-bottom low +1.1…+9.8% above `B`) — so the structural
  long stop is never hit, exactly as the fall never returns to `C`. And the COVID −64% crash
  (cycle 2) **liquidates a flat-`φ` long** ($13,838→$4,953) while the structural stop at `B`
  ($3,153 < $4,953) survives — the mirror of the short's +99–103% bear-rally case.
- **`B` is the min of the 62-window `[0.618, 0.632]`, not a single bar** — the mirror of `C` as
  the max of the peak window. This yields the canonical structural lows exactly:
  `B = $222 / $3,504 / $16,499` (cycles 1/2/3), the same lows used throughout the spec/demo.
- **Catching the exact bottom does NOT matter — what matters is post-62 survival.** With
  `B` from the window, the structural long stop `0.382·B = $85 / $1,339 / $6,303` sits ~62%
  below `B`, and after the window price dips only **−3% to −4%** below `B` — leaving the low
  **+151% to +154% above the stop**. A `φ` opening survives with enormous margin regardless of
  whether the window pins the exact low; a window off by a few percent moves a stop already ~62%
  away. Entering *below* the window low simply boosts leverage (`≈ 1.65×`), the mirror of the
  short entering above `C`. So the design metric is post-62 drawdown + `φ`-survival (both
  confirmed and remarkably uniform across cycles), not exact-extreme capture — identical to the
  top. (For reference the true bottoms land at `0.532 / 0.608 / 0.632`, converging to
  `0.632 = 0.618 + q²`, the reflection of the peak at `0.368`; not load-bearing.)

## State of execution

Done: spec §7b (both sides) + HAZARDS §C5; `StructuralLeverage` pure math for long AND short
(`test/unit/StructuralLeverage.t.sol`, `StructuralLeverageShort.t.sol`); the low-side
on-chain ratchet (`B4Pool.sampleAnchor`, `AnchorRatchet.t.sol`); the benchmark rebuilt on the
held mechanic with structural sizing on both sides (`test/backtest/Backtest.t.sol`,
`docs/11-backtest.md`).

Remaining — the §7b engine redo, requirements bound by
[`AUDIT-2026-07-structural-leverage.md`](AUDIT-2026-07-structural-leverage.md):

1. `margin = notional/L`; assert the venue liquidation equals `stopWad`/`shortStopWad`
   (regression on the *liquidation price*, not order size).
2. Sizing price captured **with** its anchors, both frozen for the position's life; a
   calendar zone change re-derives, never a silent re-lever at a stale price.
3. Refusals: long `p ≤ floor` → spot-only; short `p ≥ MaxStop` → flat base; unconfirmed
   anchors → flat base. Whole deposit deployed (no idle reserve); degradations explicit.
4. The high-side ratchet (peak-window max, mirror of `sampleAnchor`).
5. Tests MUST cross a halving with a held position and sample anchors mid-hold.
6. A fresh post-implementation adversarial round before merge.
