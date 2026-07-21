# Historical demo: the calendar and structural leverage over real BTC data

What the four products would have produced across the completed Bitcoin cycles — run through
the **protocol's own libraries** (`Calendar` for the regime, `StructuralLeverage` for the
leverage), not a re-implementation.

> [!IMPORTANT]
> **Illustration of the mechanism, not evidence of edge, and not a forecast.** Three
> completed cycles is not a statistical sample — and never can be: only about thirty halvings
> will ever occur ([whitepaper](../spec/WHITEPAPER.md) §5). Leveraged multiples are
> *arithmetic under perfect timing* — entry at the halving, infinite depth at any size, no
> slippage or market impact — not outcomes.

## How to run it

```bash
forge test --match-path 'test/backtest/*' -vv
```

Source: [`test/backtest/Backtest.t.sol`](../test/backtest/Backtest.t.sol) ·
leverage: [`src/libraries/StructuralLeverage.sol`](../src/libraries/StructuralLeverage.sol) ·
data: [`data/btcusd_daily.csv`](../data/btcusd_daily.csv)

## What the model does

- **Sized once per regime, then held.** A position is sized when the calendar rotates and
  then held at **fixed units** — equity is *linear* in price (`eq·(1 + dir·L·(px/entry − 1))`),
  not daily-compounded. This matches the shipped mechanic ([SPECIFICATION §7b](../spec/SPECIFICATION.md))
  and removes the volatility drag of a daily rebalance. It also means there is no explosive
  compounding: the numbers are what fixed leverage actually returns over a move.
- **Leverage from the protocol's own function.** Pro Max's long leverage is
  `StructuralLeverage.leverageWad(entry, φ, floor, cap)` — the exact function the engine will
  call. A Python re-implementation could silently drift; this cannot.
- **Structural anchors from the data.** `floor` and `cap` are the two ratcheted structural
  lows: the previous cycle's 62-window bottom and this cycle's post-halving-window low. They
  are read from the same daily series, so the demo and the mechanism see the same lows.

Only the portfolio bookkeeping (funding, fee, Pool credit, drawdown) lives in the test.

## Results, per cycle

Each cycle restarts at `1.0x`, deposit assumed at the halving. `max DD` is peak-to-trough;
`vs dep` is the worst the equity ever fell **below the deposit** — the number that actually
matters.

**Cycle 1 — 2012 → 2016**

| | Return | max DD | vs dep | entry L |
|---|---:|---:|---:|---:|
| Mini | 47.8x | 84.7 % | −0.3 % | 1.0× |
| B4 | 132.2x | 73.9 % | −0.3 % | 1.0× |
| Pro | 176.6x | 73.9 % | −0.3 % | 1.0× |
| Pro Max | 432.4x | 75.5 % | −0.6 % | 1.6× |
| *HODL* | *52.3x* | *84.2 %* | | |

**Cycle 2 — 2016 → 2020**

| | Return | max DD | vs dep | entry L |
|---|---:|---:|---:|---:|
| Mini | 12.5x | 83.6 % | −13.2 % | 1.0× |
| B4 | 36.8x | 64.2 % | −13.2 % | 1.0× |
| Pro | 49.7x | 64.2 % | −13.2 % | 1.0× |
| Pro Max | 192.7x | 67.9 % | **−33.6 %** | 2.5× |
| *HODL* | *13.6x* | *83.2 %* | | |

**Cycle 3 — 2020 → 2024**

| | Return | max DD | vs dep | entry L |
|---|---:|---:|---:|---:|
| Mini | 6.9x | 77.3 % | −0.1 % | 1.0× |
| B4 | 19.7x | 53.1 % | −0.1 % | 1.0× |
| Pro | 26.5x | 53.1 % | −0.1 % | 1.0× |
| Pro Max | 139.0x | 58.9 % | −1.0 % | 2.7× |
| *HODL* | *7.3x* | *76.5 %* | | |

**Cycle 4 — 2024 → 2026-07-20 (in progress, one settlement)**

| | Return | max DD | vs dep | entry L |
|---|---:|---:|---:|---:|
| Mini | 1.0x | 53.2 % | −17.1 % | 1.0× |
| B4 | 1.7x | 28.2 % | −17.1 % | 1.0× |
| Pro | 2.0x | 28.2 % | −17.1 % | 1.0× |
| Pro Max | 3.6x | 51.9 % | **−41.7 %** | 2.2× |
| *HODL* | *1.0x* | *53.0 %* | | |

## Reading it honestly

- **`max DD` and `vs dep` are different risks — read both.** Mini shows ~85 % peak-to-trough
  in cycle 1 yet only −0.3 % vs the deposit: the swing gives back accumulated *profit*, not
  principal, for a holder who entered at the halving. A mid-cycle entrant faces the full
  peak-to-trough instead.
- **Pro Max carries real downside, and the demo shows it.** −33.6 % (cycle 2) and −41.7 %
  (cycle 4) below deposit. Leverage cuts both ways; the structural floor bounds the *long's*
  liquidation, but the short side and interim dips are genuine risk. The structural mechanism
  is what keeps these numbers survivable (see below) — not what removes the risk.
- **Structural leverage, not a flat multiple.** Pro Max's entry leverage is 1.6× / 2.5× /
  2.7× / 2.2× across the cycles — set by proximity to the confirmed structural low, capped by
  the last one. In cycle 1 the anchors barely exist (`floor = 0`), so it opens near the base
  `φ ≈ 1.6×`; in later cycles the delta from the previous bottom lifts it toward ~2.7×.
- **Why the cap matters — the survival test.** Without it, a φ-leverage long opened in
  2019–2020 liquidates in the −53 % March-2020 day (its stop would sit at ~4 100–5 400, above
  the 3 850 intraday low). With the cap pinned to the 2019 bottom (3 504), the stop is below
  the low and it survives. This is pinned as a unit test
  ([`test/unit/StructuralLeverage.t.sol`](../test/unit/StructuralLeverage.t.sol),
  `test_covid_survival_cap_binds`).
- **Mini ≈ HODL.** It never trades; it pays the fee on interval profit and earns it back as
  Pool income, landing near HODL. The small gap is fee/Pool-assumption noise, not signal.
- **B4 < Pro < Pro Max in return, by construction** — each adds one interior move (a USDC
  rotation, a hedge, leverage). B4 and Pro share a drawdown because both hold `n = 1` through
  the growth regime where the drawdown occurs.

## Model and assumptions

| | |
|---|---|
| Data | Daily closes, 2012-01-01 → 2026-07-20; simulation starts at the first halving in range |
| Halvings | Real block timestamps; `840000` matches the genesis anchor used across the suite |
| Regime | `Calendar` pivots `P`, `T`; three held segments per cycle (long → fall → long) |
| Leverage | `StructuralLeverage.leverageWad` for Pro Max's long; flat `|target|` otherwise |
| Timing | Position sized once per regime, held; deposit at the halving; no lookahead |
| Performance fee | `Phi.FEE_F` on profit over the deposit at each rotation |
| Funding | Flat **10 %/yr** on the absolute perp leg (assumption) |
| Pool income | **20 % of a cohort exits penalised per cycle** (behavioural assumption) |

**Not modelled:** slippage, market impact, trading fees, liquidation mechanics, the rebalance
dead-band, and the async execution delay. The full fee is charged even though its client share
returns to users as reward weight (conservative). Mini and B4 never carry a perp
(`perp = n − clamp(n,0,1) = 0` for `n ∈ {0,1}`), so funding does not touch them.

The two **assumption** lines (funding, Pool income) are guesses about the market and about
user behaviour; every other line is the protocol's own arithmetic. They are stated separately
so they can be argued with.

## Data provenance

`data/btcusd_daily.csv` — daily BTC/USD closes, 2012-01-01 → 2026-07-20. History through
2026-05-06 from the project's existing dataset; extended from Binance `BTCUSDT` daily klines.
The two sources agree to within 0.02 % across their six-day overlap; the original file's final
partial bar was dropped before splicing. Early-period pricing (2012–2013) comes from thin,
fragmented venues and is indicative.
