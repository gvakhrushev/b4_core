# Benchmark: the calendar + structural sizing over real BTC data

Every product against buy-and-hold across the completed Bitcoin cycles — run through the
**protocol's own libraries** (`Calendar` for the regime, `StructuralLeverage` for both sides
of the leverage), not a re-implementation.

```bash
forge test --match-path 'test/backtest/*' -vv
```

Source: [`test/backtest/Backtest.t.sol`](../test/backtest/Backtest.t.sol) ·
math: [`src/libraries/StructuralLeverage.sol`](../src/libraries/StructuralLeverage.sol) ·
data: [`data/btcusd_daily.csv`](../data/btcusd_daily.csv)

## What is being measured

The protocol's claim is a **safety** claim: the calendar removes the bear, and structural
stops make leverage survivable. The benchmark therefore reads on three axes at once —
return, drawdown, and survival — always against the same baseline, `HODL` (raw buy-and-hold,
no pool, no protocol):

- **Sized once per regime, then held.** Fixed units; equity is linear in price
  (`eq·(1 + dir·L·(px/entry − 1))`) — no daily-rebalance volatility drag, no compounding
  artifacts. This is the shipped "held" mechanic (SPECIFICATION §7b).
- **Leverage from the protocol's own function, both sides.** Longs:
  `StructuralLeverage.leverageWad(entry, φ, floor, cap)` off the confirmed lows. Shorts:
  `StructuralLeverage.shortLeverageWad(entry, φ, prevPeak, C)` off the confirmed highs
  (post-pivot regime — the peak window has just closed at the fall entry). Genesis anchors
  degrade to flat `φ` with no special path.
- **Anchors as the on-chain ratchets hold them.** Long side: `floor` = previous cycle's
  62-window bottom; `cap` = post-halving-window low for the halving-entry long, the
  62-window low for the recovery long. Short side: `C` = max of the 20-day window ending at
  the 38.2 % pivot; `prevPeak` = the previous cycle's. All read from the same daily series.
- **Costs modelled:** funding 10 %/yr on the full perp leg (a short is all-perp, fraction
  `L`; a leveraged long's perp leg is `L−1`); the operator performance fee exactly as the
  shipped contract charges it (≤ 38.19 % of the 4.5 % virtual fee, baseline re-anchored to
  NAV every settlement — **no high-water mark**, so a bear round-trip is charged again on
  recovery). Pool yield is modelled separately (it applies to every stayer regardless of
  product) — see [Pool yield](#pool-yield--a-transfer-not-a-btc-multiple) below.

## Three complete cycles, compounded (2012-11-28 → 2024-04-20)

Re-deposited each cycle. A stayer's return has **two parts kept separate** so nothing is
double-counted: **① the strategy** (the product's own mechanics) and **② the pool** (the
redistributed penalties — a flat `×1.091` on equity over the three cycles at 20 % penalized
exits, `×1.040` at 10 %; see [Pool yield](#pool-yield--a-transfer-not-a-btc-multiple)).
**Total = ① × ②.** B4/Pro/Pro Max return a multiple of `HODL` on the strategy alone while
drawing down less; Mini holds `HODL`'s exposure by design, so its strategy tracks `HODL` and the
pool is its whole edge.

| Strategy | ① Strategy return | ② Pool | **Total** | Worst drawdown | Worst vs deposit |
|---|---:|---:|---:|---:|---:|
| `HODL` buy & hold | 5,214x | — | 5,214x | 84.2 % | −13.2 % |
| Mini | 4,809x | ×1.091 | **5,247x** | 84.5 % | −13.2 % |
| **B4** | 114,693x | ×1.091 | **125,130x** | **73.9 %** | −13.2 % |
| **Pro** | 425,918x | ×1.091 | **464,677x** | **73.9 %** | −13.2 % |
| **Pro Max** | 22,542,031x | ×1.091 | **24,593,356x** | **75.5 %** | −33.6 % |

## Per cycle

`vs dep` = the worst the equity ever fell below the deposit — the number that separates a
drawdown (giving back profit) from a loss of principal. Returns are **product mechanics only**
(no pool credit); the pool is the separate yield below.

**Cycle 1 — 2012-11-28 → 2016-07-09** · structural leverage: long 1.61×, short 1.61× (genesis)

| | Return | max DD | vs dep |
|---|---:|---:|---:|
| `HODL` | 52.3x | 84.2 % | −0.3 % |
| Mini | 50.9x | 84.5 % | −0.3 % |
| **B4** | **140.9x** | **73.9 %** | −0.3 % |
| **Pro** | **216.4x** | **73.9 %** | −0.3 % |
| **Pro Max** | **576.8x** | 75.5 % | −0.6 % |

**Cycle 2 — 2016-07-09 → 2020-05-11** · structural leverage: long 2.46×, short 1.17×

| | Return | max DD | vs dep |
|---|---:|---:|---:|
| `HODL` | 13.6x | 83.2 % | −13.2 % |
| Mini | 13.2x | 83.4 % | −13.2 % |
| **B4** | **39.1x** | **64.2 %** | −13.2 % |
| **Pro** | **61.0x** | **64.2 %** | −13.2 % |
| **Pro Max** | **209.2x** | 74.0 % | **−33.6 %** |

**Cycle 3 — 2020-05-11 → 2024-04-20** · structural leverage: long 2.68×, short 2.42×

| | Return | max DD | vs dep |
|---|---:|---:|---:|
| `HODL` | 7.3x | 76.5 % | −0.1 % |
| Mini | 7.1x | 76.8 % | −0.1 % |
| **B4** | **20.8x** | **53.1 %** | −0.1 % |
| **Pro** | **32.3x** | **53.1 %** | −0.1 % |
| **Pro Max** | **186.8x** | 58.9 % | −1.0 % |

**Cycle 4 — 2024-04-20 → 2026-07-20 (in progress)** · structural leverage: long 2.17×, short 4.82×

| | Return | max DD | vs dep |
|---|---:|---:|---:|
| `HODL` | 1.00x | 53.0 % | −17.1 % |
| Mini | 1.00x | 53.3 % | −17.1 % |
| **B4** | **1.66x** | **28.2 %** | −17.1 % |
| **Pro** | **2.20x** | **28.2 %** | −17.1 % |
| **Pro Max** | **5.78x** | 51.9 % | −41.7 % |

## Reading the drawdown correctly

- **B4/Pro's drawdown is not the bear.** They sit in USDC (B4) or short (Pro) through the
  fall, so the cycle bear — where `HODL` takes its −76…−84 % — contributes nothing. Their
  remaining drawdown is intra-bull volatility (April-2013, COVID, May-2021), and it gives
  back accumulated *profit*, not principal: B4 swings ~74 % peak-to-trough in cycle 1 yet
  ends −0.3 % vs the deposit.
- **Cycle-by-cycle, the ordering never breaks:** B4/Pro draw down 10–25 pp less than `HODL`
  in every cycle, while returning a multiple of it.
- **Pro Max carries real leveraged downside and the table shows it** (−33.6 % / −41.7 % vs
  deposit in cycles 2/4). Its *drawdown* still stays below `HODL`'s in every cycle — the
  structural stops keep the leverage survivable (next section).

## The survival record — the safety mechanism, measured

| Event (real data) | Flat-`φ` position | Structural position |
|---|---|---|
| Bear rally +103 % (2015: $152 → $310) | **liquidated** | survives |
| Bear rally +99 % (2018: $5,921 → $11,780) | **liquidated** | survives — stop above the confirmed peak region |
| COVID crash −64 % (2020: $13,838 → $4,953) | **liquidated** | survives — stop below the confirmed 2019 bottom |
| All cycles, post-38.2 % | — | price never returned to the confirmed peak `C` (stayed 1–23 % below): **short stop never touched** |
| All cycles, post-62 % | — | price never broke the confirmed bottom (low +150 % above the long stop): **long stop never touched** |

This is the point of structural sizing: the stop sits at a price the market has already
proven it cannot regain, so the position rides the whole regime move (−49…−81 % falls,
multi-x recoveries) without its stop ever being in play. Deep entries deliberately de-lever
(a short entered far below the peak sizes below 1×) — the small position with the far stop
is what survives; pinned as unit tests in
[`StructuralLeverageShort.t.sol`](../test/unit/StructuralLeverageShort.t.sol) and
[`StructuralLeverage.t.sol`](../test/unit/StructuralLeverage.t.sol).

## Pool yield — a transfer, not a BTC multiple

Exits outside free windows forfeit `q = 11.8 %` of their position into the shared pool,
redistributed to the stayers pro-rata by weight. The pool holds it **in kind** (BTC through the
growth regimes, a short in the fall) — **but so does every stayer's own book**, so BTC's
appreciation is on *both sides* of the ratio and cancels. The pool return is therefore a pure
**transfer**, `r·q/(1−r)` of a stayer's equity per cycle, independent of how far BTC ran.
Modelled daily on the real series (`test_pool_economics`, a `$100/day` DCA book), the per-cycle
boost is **identical** across three cycles that grew 52×, 14× and 7× — the proof that it does
not ride BTC:

| Penalized exits (per cycle) | Pool return / cycle | Over three cycles |
|---|---:|---:|
| 10 % | +1.31 % | **×1.040** |
| 20 % | +2.95 % | **×1.091** |

The designed fall-short ([tranches](../PROPOSAL-pool-tranches.md)) lets the fall-regime
penalties gain instead of sitting flat — a small addition on top; this transfer is the floor.
The yield is modest **by construction**: it is a redistribution *among* holders, not new BTC
exposure. It matters most in a flat market, where a Mini stayer's strategy return merely tracks
`HODL` (both ≈ 1.0× in the cycle in progress), so the pool is the entire edge. **Model caveat:**
the transfer takes `r` as the fraction of the standing book that exits penalized per cycle; the
realized figure depends on the exit-timing distribution, which the model idealizes.

> **Correction.** An earlier version of this section reported a "4–5× pool yield," modelling the
> penalty as accrued at daily cost and distributed grown. That double-counted the halving
> appreciation a stayer's own book already captures — the two sides of the transfer both ride
> BTC, so the relative boost cannot be a BTC multiple. The honest figure is the transfer above.

## Model and assumptions

| | |
|---|---|
| Data | Daily closes, 2012-01-01 → 2026-07-20; simulation starts at the first halving in range |
| Halvings | Real block timestamps |
| Regime | `Calendar` pivots `P`, `T`; three held segments per cycle (long → fall → long) |
| Leverage | `StructuralLeverage`, both sides; genesis/unconfirmed anchors → flat base |
| Timing | Sized once per regime at the pivot price, held. The long-side `cap` anchor is the min of a 20-day window that can extend a few days past the entry — a small look-ahead the demo accepts (the on-chain ratchet samples in real time, so live sizing has none); it only tightens leverage, never loosens it |
| Fee | Operator's cut of `Phi.FEE_F` (≤ 38.19 % of 4.5 %) on profit, baseline re-anchored to NAV each settlement, matching `opsSettle` |
| Funding | 10 %/yr on the full perp leg (assumption) |
| Pool yield | modelled separately (`test_pool_economics`): a transfer of `q = 11.8 %` of a penalized exit's position to the stayers, `r·q/(1−r)` of equity per cycle; `r` = 10 % / 20 % of the standing book exiting penalized (behavioural) |

**Not modelled:** slippage, market impact, trading fees, async execution delay, the DCA
window averaging of live entries (the demo enters at the pivot price in one order). Perps
were not liquid before ~2016, so Pro/Pro Max in cycles 1–2 are historical hypotheticals.
Three completed cycles is not a statistical sample and never can be (~32 halvings will ever
exist). The `StructuralLeverage` math is shipped and tested; the vault-engine sizing runs
flat-`φ` until the §7b redo lands ([audit record](../AUDIT-2026-07-structural-leverage.md)).

## Data provenance

`data/btcusd_daily.csv` — daily BTC/USD closes, 2012-01-01 → 2026-07-20. History through
2026-05-06 from the project's existing dataset; extended from Binance `BTCUSDT` daily klines.
The two sources agree to within 0.02 % across their six-day overlap.
