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

## Leaderboard — 3 complete cycles, compounded (2012-11-28 → 2024-04-20)

Re-deposited each cycle. More return **and** less drawdown than holding.

| Strategy | Total return | Worst drawdown | Worst vs deposit | Pool income |
|---|---:|---:|---:|---:|
| `HODL` buy & hold | 5,214x | 84.2 % | −13.2 % | — |
| Mini | 5,415x | 84.5 % | −13.2 % | ×1.09 |
| **B4** | **125,149x** | **73.9 %** | −13.2 % | ×1.09 |
| **Pro** | **300,473x** | **73.9 %** | −13.2 % | ×1.09 |
| Pro Max | 14,893,463x | 75.5 % | −33.6 % | ×1.09 |

## Results, per cycle

Each cycle restarts at `1.0x`, deposit assumed at the halving. `HODL` is raw buy-and-hold —
no pool, no protocol, the benchmark to beat, shown as the first row. `max DD` is peak-to-trough
and **`zone`** is the calendar phase that drawdown landed in (`GROWTH` `[0,P]` / `FALL` `[P,T]`
/ `RECOV` `[T,end]`); `vs dep` is the worst the equity ever fell **below the deposit** — the
number that actually matters. `pool` is how much of that strategy's profit came from the
penalised leavers. `entry L` is the structural leverage at the cycle's first long.

**Cycle 1 — 2012-11-28 → 2016-07-09**

| | Return | max DD | worst DD on | zone | vs dep | pool | entry L |
|---|---:|---:|---|---|---:|---:|---:|
| `HODL` | 52.3x | 84.2 % | 2015-01-14 | `FALL` | −0.3 % | — | — |
| Mini | 52.9x | 84.5 % | 2015-01-14 | `FALL` | −0.3 % | 2.9 % | 1.0× |
| **B4** | **145.1x** | **73.9 %** | 2013-04-11 | `GROWTH` | −0.3 % | 2.8 % | 1.0× |
| **Pro** | **193.1x** | **73.9 %** | 2013-04-11 | `GROWTH` | −0.3 % | 2.8 % | 1.0× |
| Pro Max | 471.0x | 75.5 % | 2013-04-11 | `GROWTH` | −0.6 % | 2.8 % | 1.6× |

**Cycle 2 — 2016-07-09 → 2020-05-11**

| | Return | max DD | worst DD on | zone | vs dep | pool | entry L |
|---|---:|---:|---|---|---:|---:|---:|
| `HODL` | 13.6x | 83.2 % | 2018-12-15 | `FALL` | −13.2 % | — | — |
| Mini | 13.8x | 83.4 % | 2018-12-15 | `FALL` | −13.2 % | 3.0 % | 1.0× |
| **B4** | **40.3x** | **64.2 %** | 2020-03-16 | `RECOV` | −13.2 % | 2.9 % | 1.0× |
| **Pro** | **54.2x** | **64.2 %** | 2020-03-16 | `RECOV` | −13.2 % | 2.9 % | 1.0× |
| Pro Max | 209.9x | 67.9 % | 2020-03-16 | `RECOV` | **−33.6 %** | 2.8 % | 2.5× |

**Cycle 3 — 2020-05-11 → 2024-04-20**

| | Return | max DD | worst DD on | zone | vs dep | pool | entry L |
|---|---:|---:|---|---|---:|---:|---:|
| `HODL` | 7.3x | 76.5 % | 2022-11-21 | `RECOV` | −0.1 % | — | — |
| Mini | 7.4x | 76.8 % | 2022-11-21 | `RECOV` | −0.1 % | 3.3 % | 1.0× |
| **B4** | **21.4x** | **53.1 %** | 2021-07-20 | `GROWTH` | −0.1 % | 3.0 % | 1.0× |
| **Pro** | **28.7x** | **53.1 %** | 2021-07-20 | `GROWTH` | −0.1 % | 2.9 % | 1.0× |
| Pro Max | 150.6x | 58.9 % | 2021-07-20 | `GROWTH` | −1.0 % | 2.8 % | 2.7× |

**Cycle 4 — 2024-04-20 → 2026-07-20 (in progress)**

| | Return | max DD | worst DD on | zone | vs dep | pool | entry L |
|---|---:|---:|---|---|---:|---:|---:|
| `HODL` | 1.00x | 53.0 % | 2026-06-30 | `FALL` | −17.1 % | — | — |
| Mini | 1.03x | 53.3 % | 2026-06-30 | `FALL` | −17.1 % | **92.9 %** | 1.0× |
| **B4** | **1.71x** | **28.2 %** | 2025-04-08 | `GROWTH` | −17.1 % | 6.8 % | 1.0× |
| **Pro** | **2.05x** | **28.2 %** | 2025-04-08 | `GROWTH` | −17.1 % | 5.5 % | 1.0× |
| Pro Max | 3.71x | 51.9 % | 2024-09-06 | `GROWTH` | **−41.7 %** | 3.9 % | 2.2× |

### Where the drawdown comes from — and why it is not the bear

A natural objection: *if B4 is in USDC (or short) through the fall, where does a 74 % drawdown
come from?* It **cannot** come from the fall — B4's equity is constant in USDC there, so the
`FALL` zone contributes exactly zero drawdown. Every B4/Pro drawdown above lands in `GROWTH`
or `RECOV`: violent **intra-bull** crashes. `HODL`'s worst days land in the phase B4 sits out:

| Cycle | `HODL` worst day | | B4 worst day | |
|---|---|---|---|---|
| 2012→2016 | 2015-01-14 | `FALL` — bear bottom | 2013-04-11 | `GROWTH` — April-2013 crash ($260→$60) |
| 2016→2020 | 2018-12-15 | `FALL` — bear bottom | 2020-03-16 | `RECOV` — COVID |
| 2020→2024 | 2022-11-21 | `RECOV` — FTX | 2021-07-20 | `GROWTH` — May-2021 crash |

So the calendar does exactly what it claims — it removes the *bear*. It does not, and does not
claim to, remove sharp corrections inside a bull run.

### Pool income — the protocol's core value capture

Every product's return **already includes** it: the behavioural assumption is that **20 % of
the cohort exits through the `q = 11.8 %` penalty door each cycle**, and that forfeited penalty
is redistributed to the ~80 % who stay — **+0.25·q ≈ +2.95 % per cycle to every stayer**,
compounding if held across cycles (×1.09 over the three complete cycles). It is the mechanism
by which stayers are paid by leavers.

It is visible **in isolation**: Mini holds `1×` long always — exactly `HODL`'s exposure — so
the Mini − `HODL` gap is nothing but the Pool income net of the operator fee.

| Cycle | Mini | `HODL` | Pool share of Mini's profit |
|---|---:|---:|---:|
| 2012→2016 | 52.9x | 52.3x | 2.9 % |
| 2016→2020 | 13.8x | 13.6x | 3.0 % |
| 2020→2024 | 7.4x | 7.3x | 3.3 % |
| 2024→now (flat cycle) | 1.03x | 1.00x | **92.9 %** |

In a bull cycle the pool is a ~3 % bonus on top of price. In a **flat cycle it is essentially
the entire return** — the protocol pays stayers when the market does not. That asymmetry, not
the bull-cycle multiple, is the point of the mechanism.

## Reading it honestly

- **Less drawdown than holding — compare the `max DD` rows against the `HODL` row.** HODL eats
  a 53–84 % top-to-bottom crash every cycle. B4 and Pro cut **10–25 pp** off that: they hold
  spot only through the *rise* and sit in **USDC through the fall**, so their drawdown is
  intra-bull volatility, not the cycle bear — see the `zone` column and the section above.
  Mini stays `1×` long through the bear (like HODL), so its drawdown tracks HODL's — that is
  the price of the simplest product. The real strategies step aside.
- **`max DD` and `vs dep` are different risks — read both.** B4 shows ~74 % peak-to-trough in
  cycle 1 yet only −0.3 % vs the deposit: the swing gives back accumulated *profit*, not
  principal, for a holder who entered at the halving. A mid-cycle entrant faces the full
  peak-to-trough instead.
- **Pro Max carries real downside, and the demo shows it.** −33.6 % (cycle 2) and −41.7 %
  (cycle 4) below deposit, and a drawdown near HODL's despite the lower cycle bear — that is
  the leverage on the *interim* dips. The structural floor bounds the *long's* liquidation, but
  the short side and interim dips are genuine risk. The mechanism keeps these numbers
  survivable (see below) — it does not remove the risk.
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
- **Mini edges out HODL — and the gap is the pool.** Mini never changes exposure, so before
  fees it *is* HODL. It pays a small operator performance fee on interval profit and receives
  the Pool income; the income wins, so Mini lands just **above** HODL (52.9x vs 52.3x). The
  gap is the redistributed exit penalty — small per cycle, structural over many.
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
| Performance fee | Operator's cut of `Phi.FEE_F`: ≤ 38.19 % of a 4.5 % fee on new profit above the high-water mark ⇒ **≤ ~1.72 % of profit** actually leaves NAV |
| Funding | Flat **10 %/yr** on the absolute perp leg (assumption) |
| Pool income | **20 % of a cohort exits penalised per cycle** at `q = 11.8 %`, redistributed to stayers ⇒ **+0.25·q ≈ +2.95 %/cycle** (behavioural assumption) |

**Fee model, corrected.** `Phi.FEE_F` (4.5 %) is a *virtual* fee: only the operator's route
share — capped at 38.19 % — is ever paid out in kind, so a holder loses at most ~1.72 % of
profit; the rest is pool-weight accounting and never leaves NAV. An earlier version of this
demo removed the full 4.5 % three times on *cumulative* profit, which pushed Mini below plain
hold — a modelling artefact, now fixed (charged once per settlement, on new profit above the
high-water mark, at the operator rate).

**Not modelled:** slippage, market impact, trading fees, liquidation mechanics, the rebalance
dead-band, and the async execution delay. Mini and B4 never carry a perp
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
