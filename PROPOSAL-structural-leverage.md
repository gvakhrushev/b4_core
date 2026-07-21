# Proposal: structural leverage floor (v2 mechanism)

**Status (2026-07-21): specified, wired, and tested.** The mechanism is normative
(`spec/SPECIFICATION.md` §7b + §3, `spec/HAZARDS.md` §C5) and fully implemented: the pure math
(`src/libraries/StructuralLeverage.sol`), the on-chain anchor ratchet (`B4Pool.sampleAnchor`),
and the engine sizing (`B4VaultEngine._planPerpStep` — sized once at the frozen price, held).
230/230 green, B4Vault unchanged at 24,195 B, deep campaign 8/8, slither exit 0. This file is
the design record; `REPORT.md` lists the residual items for the external audit. It still
carries the pre-mainnet, unaudited, funded-gate caveats of the whole protocol.

**Decisions on the three open questions:** (1) structural `L` replaces the flat sizing for
leveraged products, with the venue `maxLeverage` a hard technical ceiling on top; (2) the
ratchet moves **up only** — a lower low across cycles does not raise leverage; (3) only
Pro Max (base growth `> 1`) uses the multiplier — Pro's growth is `1` (plain spot) and shorts
stay flat `φ`.

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

### Shorts, genesis, scope

- **Shorts (fall regime): flat `φ`, no multiplier** in this version — there is no structural
  ceiling above a short, so the floor mechanism is long-only for now.
- **Genesis (first cycle): `floor = 0`, no `cap`** until the first window closes → the
  formula degrades exactly to the current flat behaviour. No special-case code path.
- **Scope: the multiplier is a property of the leveraged, perp-bearing products** (Pro Max;
  Pro optionally). Mini/B4 never carry a perp and are untouched. The operator's route sets
  the multiplier ceiling; the floor mechanism sets where it is *applicable* — together they
  bound realized risk (the two-part framing).

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

## Open implementation questions (need your call — not re-opening the design)

1. **Reconciling with the existing safety reserve.** The shipped code sizes margin from a
   fixed ratio: `notional ≤ margin·maxLeverage/φ`. The new mechanism sizes margin from the
   stop distance. Proposal: the structural leverage `L` **replaces** the flat sizing for
   leveraged products, and the venue `maxLeverage` remains a hard technical ceiling on top
   (so near the floor, where the formula would give huge `L`, the venue's 50×/200× binds
   first — your point 2). Confirm this is the intended relationship.

2. **Monotonic ratchet guard.** If a cycle prints a structural low *below* the previous one
   (a deeper bear than last cycle), the `cap` would move **down**. Safe default: the cap
   ratchets **up only** — a lower new low does not raise leverage, it just isn't adopted as a
   higher cap. Confirm, or specify that a lower low genuinely lowers the cap (also safe, just
   different).

3. **Does `Pro` (not just `Pro Max`) get the multiplier?** Pro's growth target is `1`
   (no leverage in growth) and its fall target is `−1/φ` (short). Under "shorts flat φ,
   long-only multiplier," Pro is effectively untouched. Confirm Pro is out of scope and only
   Pro Max (and any future `>1` growth product) uses it.

## Execution plan on approval

1. `spec/SPECIFICATION.md` §7 + `spec/HAZARDS.md` new §C5 — the normative text above.
2. Sizing bug fix: event-driven resize (entry / deposit / zone change), no NAV tracking.
3. On-chain min-ratchet for the two windows; the structural-leverage sizing on top.
4. Regressions: `COVID-2020 survives`, `May-2021 survives`, `entry-below-fresh-low opens`,
   `position not resized mid-zone`, `stop realized by margin`, `genesis degrades to flat`.
5. Rebuild `test/backtest/Backtest.t.sol` on the real mechanic (fixed-notional within a zone
   removes the daily-rebalance volatility drag — the 2013 trough becomes ~8x of deposit, not
   the ~3x the current daily-rebalanced model shows).
6. Update `docs/11-backtest.md` and the whitepaper's risk framing.
