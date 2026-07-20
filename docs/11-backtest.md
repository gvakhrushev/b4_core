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

| | Return | Max drawdown |
|---|---:|---:|
| Mini | 49.56x | 84.88 % |
| B4 | 122.74x | 73.85 % |
| Pro | 171.25x | 73.85 % |
| Pro Max | 374.42x | **96.74 %** |
| *HODL* | *51.85x* | *84.18 %* |

**Cycle 2 — 2016-07-10 → 2020-05-11**

| | Return | Max drawdown |
|---|---:|---:|
| Mini | 12.94x | 83.89 % |
| B4 | 52.80x | 64.20 % |
| Pro | 72.83x | 64.20 % |
| Pro Max | 292.11x | 85.71 % |
| *HODL* | *13.52x* | *83.16 %* |

**Cycle 3 — 2020-05-12 → 2024-04-20**

| | Return | Max drawdown |
|---|---:|---:|
| Mini | 7.08x | 77.37 % |
| B4 | 27.10x | 53.05 % |
| Pro | 41.35x | 53.05 % |
| Pro Max | 226.47x | 74.17 % |
| *HODL* | *7.37x* | *76.45 %* |

**Cycle 4 — 2024-04-21 → 2026-07-20 (in progress, one settlement so far)**

| | Return | Max drawdown |
|---|---:|---:|
| Mini | 0.99x | 53.87 % |
| B4 | 1.68x | 28.19 % |
| Pro | 2.06x | 28.19 % |
| Pro Max | 2.76x | 45.54 % |
| *HODL* | *1.00x* | *52.99 %* |

## Reading the table honestly

- **Mini ≈ HODL minus fees, by construction.** It holds spot in both regimes and never
  trades, so it *must* land slightly below HODL — it still pays the performance fee on
  interval profit. That is a correctness check on the model, not a result. Mini's actual
  return is Pool inventory, which this model does **not** credit, so Mini is understated here.
- **B4 and Pro share a drawdown** in every completed cycle (73.85 / 64.20 / 53.05 %) because
  the drawdown happens in the growth regime, where both hold `n = 1`. They differ only in the
  fall regime.
- **Pro Max's 96.74 % drawdown in cycle 1 is a liquidation, not a return.** A leveraged
  position through that path would have been closed out long before the cycle ended. The
  model has no liquidation engine, so its Pro Max figures for the early cycles are
  arithmetic, not outcomes.
- **Perpetual futures did not exist in liquid form before ~2016.** Pro and Pro Max in cycles
  1–2 are therefore counterfactual: the instrument the strategy requires was not available.
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

**Not modelled:** slippage, trading fees, liquidation, the exit penalty, Pool income, the
rebalance dead-band, and the asynchronous execution delay. The full fee is charged as a cost
even though its client share returns to users as Pool reward weight — a conservative choice.

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
