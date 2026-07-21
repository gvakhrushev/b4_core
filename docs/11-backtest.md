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

Each cycle restarts at `1.0x`, deposit assumed at the halving. `HODL` is raw buy-and-hold —
no pool, no protocol, the benchmark to beat. `max DD` is peak-to-trough; **`DD-HODL`** is how
much *less* (negative) the product drew down than holding; `vs dep` is the worst the equity
ever fell **below the deposit** — the number that actually matters. Returns include the Pool
income (see below); `entry L` is the structural leverage at the cycle's first long.

**Cycle 1 — 2012 → 2016** · *HODL 52.3x, 84.2 % max DD*

| | Return | max DD | DD-HODL | vs dep | entry L |
|---|---:|---:|---:|---:|---:|
| Mini | 52.9x | 84.5 % | +0.2 pp | −0.3 % | 1.0× |
| B4 | 145.1x | 73.9 % | **−10.3 pp** | −0.3 % | 1.0× |
| Pro | 193.1x | 73.9 % | **−10.3 pp** | −0.3 % | 1.0× |
| Pro Max | 471.0x | 75.5 % | −8.7 pp | −0.6 % | 1.6× |

**Cycle 2 — 2016 → 2020** · *HODL 13.6x, 83.2 % max DD*

| | Return | max DD | DD-HODL | vs dep | entry L |
|---|---:|---:|---:|---:|---:|
| Mini | 13.8x | 83.4 % | +0.2 pp | −13.2 % | 1.0× |
| B4 | 40.3x | 64.2 % | **−18.9 pp** | −13.2 % | 1.0× |
| Pro | 54.2x | 64.2 % | **−18.9 pp** | −13.2 % | 1.0× |
| Pro Max | 209.9x | 67.9 % | −15.2 pp | **−33.6 %** | 2.5× |

**Cycle 3 — 2020 → 2024** · *HODL 7.3x, 76.5 % max DD*

| | Return | max DD | DD-HODL | vs dep | entry L |
|---|---:|---:|---:|---:|---:|
| Mini | 7.4x | 76.8 % | +0.3 pp | −0.1 % | 1.0× |
| B4 | 21.4x | 53.1 % | **−23.4 pp** | −0.1 % | 1.0× |
| Pro | 28.7x | 53.1 % | **−23.4 pp** | −0.1 % | 1.0× |
| Pro Max | 150.6x | 58.9 % | −17.5 pp | −1.0 % | 2.7× |

**Cycle 4 — 2024 → 2026-07-20 (in progress, one settlement)** · *HODL 1.0x, 53.0 % max DD*

| | Return | max DD | DD-HODL | vs dep | entry L |
|---|---:|---:|---:|---:|---:|
| Mini | 1.0x | 53.3 % | +0.3 pp | −17.1 % | 1.0× |
| B4 | 1.7x | 28.2 % | **−24.7 pp** | −17.1 % | 1.0× |
| Pro | 2.1x | 28.2 % | **−24.7 pp** | −17.1 % | 1.0× |
| Pro Max | 3.7x | 51.9 % | −1.0 pp | **−41.7 %** | 2.2× |

### Pool income — the protocol's core value capture

Every product's return **already includes** the Pool income: the behavioural assumption is
that **20 % of the cohort exits through the `q = 11.8 %` penalty door each cycle**, and that
forfeited penalty is redistributed to the ~80 % who stay — **+0.25·q ≈ +2.95 % per cycle to
every stayer**, compounding if held across cycles. It is the mechanism by which stayers are
paid by leavers.

You can *see* it isolated in the demo's footnote: Mini holds `1×` long always — exactly HODL's
exposure — so **Mini minus HODL is nothing but the Pool income net of the operator fee**
(cycle 1: 52.9x vs 52.3x). Every other product carries the same credit on top of its strategy.

## Reading it honestly

- **Less drawdown than holding — the `DD-HODL` column.** HODL eats a 53–84 % top-to-bottom
  crash every cycle. B4 and Pro cut **10–25 pp** off that: they hold spot only through the
  *rise* and sit in **USDC through the fall**, so their drawdown is intra-bull volatility, not
  the cycle bear. Mini stays `1×` long through the bear (like HODL), so its drawdown tracks
  HODL's — that is the price of the simplest product. The real strategies step aside.
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
