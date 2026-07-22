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
  product) — see [Pool yield](#pool-yield--the-penalties-ride-the-halving-cycle) below.

## Three complete cycles, compounded (2012-11-28 → 2024-04-20)

Re-deposited each cycle. **B4/Pro/Pro Max return a multiple of `HODL` while drawing down less;**
Mini holds `HODL`'s exposure by design, so it tracks `HODL`'s drawdown (its edge is the pool).

| Strategy | Total return | Worst drawdown | Worst vs deposit |
|---|---:|---:|---:|
| `HODL` buy & hold | 5,214x | 84.2 % | −13.2 % |
| Mini | 4,809x | 84.5 % | −13.2 % |
| **B4** | **114,693x** | **73.9 %** | −13.2 % |
| **Pro** | **425,918x** | **73.9 %** | −13.2 % |
| **Pro Max** | **22,542,031x** | **75.5 %** | −33.6 % |

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

## Pool yield — the penalties ride the halving cycle

Exits outside free windows pay `q = 11.8 %` into the shared pool, redistributed to holders
pro-rata by weight. The pool is **not** a flat percentage — it holds the penalty **in kind**
(BTC through the growth regime, USDC through the fall) and distributes it at the three
settlement points (`P−H`, `T+H`, the cycle boundary), so penalties accrued when BTC is cheap
and realized near the cycle peak **appreciate with the halving**. Modelled daily on the real
series (`test_pool_economics`), a `$100/day` cohort marking `r` of each day's inflow as penalty:

| Cycle | BTC (halving → next) | penalty in (10 % / 20 %) | distributed (10 % / 20 %) | yield |
|---|---|---:|---:|---:|
| 2012→2016 | $12 → $642 | $13,190 / $26,380 | $56,890 / $113,781 | **4.31×** |
| 2016→2020 | $642 → $8,759 | $14,020 / $28,040 | $69,561 / $139,123 | **4.96×** |
| 2020→2024 | $8,759 → $64,895 | $14,400 / $28,800 | $21,121 / $42,243 | **1.46×** |

The multiple is **rate-independent** — 10 % → 20 % doubles the dollars distributed, not the
yield (the yield is the BTC appreciation on the accrued inventory, which the earlier flat
`+2.95 %/cycle` figure entirely missed). With the designed fall-short
([tranches](../PROPOSAL-pool-tranches.md)) the fall-regime penalties also gain, adding `+2…7 %`
(cycles 1/2/3). The yield collapses toward `1×` in a flat market — which is when the
*redistribution* matters most (a Mini stayer's product return then merely tracks `HODL`, so the
pool is the entire edge). **Model caveat:** this earmarks `r` of daily inflow as penalty held in kind
from accrual to distribution; the exact realized yield depends on the exit timing distribution,
which the model idealizes.

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
| Pool yield | modelled separately (`test_pool_economics`): `r` of a $100/day cohort's inflow is penalty inventory held in kind; 10 % and 20 % shown (behavioural) |

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
