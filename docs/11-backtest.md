# Historical demo: the calendar over real BTC data

What the four products' exposure path would have produced across the completed Bitcoin
cycles — run through the **protocol's own `Calendar` library**, not a re-implementation.

> [!IMPORTANT]
> **This is an illustration of the mechanism, not evidence of edge, and not a forecast.**
> Three completed cycles is not a statistical sample — and never can be: only about thirty
> halvings will ever occur, which the [whitepaper](../spec/WHITEPAPER.md) §5 states as a
> structural limit of the design rather than a gap to be filled with more data.

## How to run it

```bash
forge test --match-path 'test/backtest/*' -vv
```

Source: [`test/backtest/Backtest.t.sol`](../test/backtest/Backtest.t.sol) ·
data: [`data/btcusd_daily.csv`](../data/btcusd_daily.csv)

## Why it runs in Foundry rather than a notebook

The exposure path comes from **`Calendar.targetAt` — the same function the vaults call**.
A Python re-implementation of the calendar could silently drift from the deployed
arithmetic and produce a demo that flatters a protocol it no longer describes. Here, if the
calendar changes, this output changes with it.

Only the portfolio bookkeeping — compounding a daily return at the given exposure — lives in
the test. That is market simulation, not protocol logic.

## Results, per cycle

Each cycle restarts at `1.0x`. Cumulative compounding since 2012 is deliberately **not**
reported: it would be dominated by the earliest, least liquid period and would say more about
a \$12 starting price than about the design.

**Cycle 1 — 2012-11-29 → 2016-07-09**

| | Return | Max DD | DD at day | Regime |
|---|---:|---:|---:|---|
| Mini | 51.03x | 84.65 % | 775 | fall |
| B4 | 126.31x | 73.85 % | 132 | growth |
| Pro | 176.26x | 73.85 % | 132 | growth |
| Pro Max | 385.40x | **96.74 %** | 218 | growth |
| *HODL* | *51.85x* | *84.18 %* | | |

**Cycle 2 — 2016-07-10 → 2020-05-11**

| | Return | Max DD | DD at day | Regime |
|---|---:|---:|---:|---|
| Mini | 13.32x | 83.65 % | 887 | fall |
| B4 | 54.34x | 64.20 % | 1344 | terminal growth |
| Pro | 74.96x | 64.20 % | 1344 | terminal growth |
| Pro Max | 300.65x | 85.71 % | 1344 | terminal growth |
| *HODL* | *13.52x* | *83.16 %* | | |

**Cycle 3 — 2020-05-12 → 2024-04-20**

| | Return | Max DD | DD at day | Regime |
|---|---:|---:|---:|---|
| Mini | 7.29x | 76.70 % | 922 | transition |
| B4 | 27.89x | 53.05 % | 433 | growth |
| Pro | 42.56x | 53.05 % | 433 | growth |
| Pro Max | 233.14x | 74.17 % | 433 | growth |
| *HODL* | *7.37x* | *76.45 %* | | |

**Cycle 4 — 2024-04-21 → 2026-07-20 (in progress, one settlement)**

| | Return | Max DD | DD at day | Regime |
|---|---:|---:|---:|---|
| Mini | 1.00x | 53.19 % | 799 | fall |
| B4 | 1.70x | 28.19 % | 351 | growth |
| Pro | 2.09x | 28.19 % | 351 | growth |
| Pro Max | 2.80x | 45.54 % | 748 | fall |
| *HODL* | *1.00x* | *52.99 %* | | |

## Where the drawdowns happen — and why it is not a rotation artefact

A natural suspicion is that the drawdowns come from rotating on a single settlement price,
and that closing in slices would smooth them away. The `DD at day` column tests that
directly, and the answer is no.

`Calendar.targetAt` already interpolates **continuously across the full 20-day transition** —
the model rotates in daily slices and averages its prices by construction:

| Day of cycle | 535 | 538 | 542 | 547 | 548 | 552 | 557 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Pro Max target `n` | +1.618 | +1.565 | +0.917 | +0.108 | −0.053 | −0.701 | −1.510 |

And for **every rotating product** (B4, Pro, Pro Max) the worst drawdown lands *inside a
regime*, never in a transition window (which begins on day 538). Pro Max's cycle-1 figure is
the April 2013 crash — BTC `229.50 → 65.65`, **−70.4 %** — which at φ leverage compounds to
roughly −86 % arithmetically and −96.7 % with the volatility drag of daily rebalancing. It
occurred **319 days before** the growth→fall pivot.

**The calendar rotates at the pivots; it does not protect against a drawdown inside a
regime.** For a leveraged product that is amplified. This is a property of the products, not
a defect in the simulation — and it is the single most important thing to understand before
reading the return column.

(Mini is the one entry that lands in a transition, in cycle 3. Mini never rotates — `n = 1`
throughout — so its drawdown simply tracks HODL and the timing is incidental.)

## Reading the table honestly

- **Mini ≈ HODL, by construction.** It holds spot in both regimes and never trades: it pays
  the performance fee on interval profit and earns it back as Pool income, landing just under
  HODL. The test asserts this within a tolerance — a correctness check on the model, not a
  result. The Pool side rests on the behavioural assumption below, so treat the small
  remaining gap as noise, not signal.
- **B4 and Pro share a drawdown** in every completed cycle (73.85 / 64.20 / 53.05 %) because
  the drawdown happens in the growth regime, where both hold `n = 1`. They differ only in the
  fall regime.
- **Pro Max's 96.74 % drawdown in cycle 1 is a liquidation, not a return.** A leveraged
  position through that path would have been closed out long before the cycle ended. The
  model has no liquidation engine, so its Pro Max figures for the early cycles are
  arithmetic, not outcomes.
- **Perps were not liquid before ~2016**, so Pro/Pro Max in the early cycles are historical
  hypotheticals. This limits how far back the comparison reaches; it says nothing about the
  design, and the instrument is amply liquid today.
- **Cycle 4 is not finished.** One settlement has occurred; BTC is roughly flat over the
  window, so the separation shown is the fall-regime rotation, not a full-cycle result.

## Model and its assumptions

| | |
|---|---|
| Data | Daily closes. 2012-01-01 → 2026-07-20; the simulation starts at the first halving in range |
| Halvings | Real block timestamps (210000 / 420000 / 630000 / 840000); 840000 matches the genesis anchor used throughout the test suite |
| Exposure | `Calendar.targetAt` — the protocol's own function |
| Timing | Yesterday's calendar position drives today's return, so there is **no lookahead** |
| Rebalancing | Daily to target |
| Performance fee | `Phi.FEE_F` on interval profit at each settlement point, entry ledger re-anchored — mirroring `opsSettle` |
| Funding | Flat **10 %/yr** charged on the absolute perp leg |
| Pool income | Assumes **20 % of a cohort exits penalised per cycle**; uplift `share·q/(1−share)` credited in halves at the two settlement points |

**Not modelled:** slippage, trading fees, liquidation, the rebalance dead-band, and the
asynchronous execution delay.

The Pool-income line is the one **behavioural** assumption in the file — a guess about how
users behave, not protocol arithmetic. Everything else is either the protocol's own code or a
stated market parameter. It is set out separately so it can be argued with: at 20 % exiting
penalised, the uplift is `0.20 × q / 0.80 ≈ 2.95 %` per cycle, which roughly offsets the
performance fee for a non-trading product. Lower the assumption and Mini drifts below HODL;
raise it and Mini rises above.

Note that **Mini and B4 never carry a perp leg** (`perp = n − clamp(n, 0, 1) = 0` for
`n ∈ {0, 1}`), so the funding assumption does not touch them. It applies only to Pro and
Pro Max, and a flat rate is a crude stand-in for a path-dependent cost that this dataset does
not contain.

## Data provenance

`data/btcusd_daily.csv` — daily BTC/USD OHLCV, 2012-01-01 → 2026-07-20. History through
2026-05-06 from the project's existing dataset; extended to 2026-07-20 from Binance
`BTCUSDT` daily klines. The two sources agree to within 0.02 % across their six-day overlap;
the original file's final row was a partial bar and was dropped before splicing.

Early-period pricing (2012–2013) comes from thin, fragmented venues and should be treated as
indicative.
