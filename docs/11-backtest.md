# Benchmark: every product driven through the real contracts

Every figure here is `B4Vault.navWad()` read off the **actual deployed contracts** — the real
`B4Vault`/`B4VaultOps`/`B4Pool`/`HalvingOracle` and the reference `Strategy*` — cranked day by
day across the real halving epochs, rotating and settling exactly as the on-chain keeper would.
It is **not** a parallel spreadsheet model. (An earlier hand-rolled equity calculator that this
replaces overstated Pro Max by ~36× and mis-stated every product; see the note at the end.)

```bash
forge test --match-path 'test/backtest/BacktestReal.t.sol' -vv
```

Source: [`test/backtest/BacktestReal.t.sol`](../test/backtest/BacktestReal.t.sol) ·
data: [`data/btcusd_daily.csv`](../data/btcusd_daily.csv)

## What is being measured

The protocol's claim is a **safety** claim: the calendar removes the bear, and stepping out of
the market (into USDC or a short) during the fall makes the position survive it. The benchmark
reads on three axes — return, drawdown, and survival — with Mini (spot held in both regimes,
the protocol's buy-and-hold) as the baseline:

- **Real engine, real keeper.** A vault is deposited once, then `crank()`-ed at each calendar
  transition and `settle()`-d at the two settlement points (`P−H`, `T+H`) every epoch — the same
  calls the permissionless keeper makes. Equity is `navWad()`, nothing else.
- **BTC base + separate margin.** Each vault starts from **$100k of BTC**. Mini and B4 never
  short, so they post no margin. Pro and Pro Max short in the fall and therefore also post USDC
  **margin** — a short cannot be backed by the USDC from selling spot; it needs its own margin
  bucket. That margin is additional capital, reported separately; returns are taken on the $100k
  BTC base so all four products stay comparable.
- **Flat-`φ` sizing.** The shipped engine sizes perps at the flat base `φ`, not structural
  leverage (the `StructuralLeverage` library is designed and tested but not wired — see
  [audit record](../AUDIT-2026-07-structural-leverage.md)). Pro Max's edge here is the `φ`
  base target, not a structural amplification.
- **Costs charged by the contract itself:** the operator performance fee exactly as `opsSettle`
  takes it (≤ 38.19 % of the 4.5 % virtual fee, baseline re-anchored to NAV every settlement —
  **no high-water mark**), and perp funding as the venue applies it. The shared-pool client-share
  weight is **not** included — see [Pool weight](#pool-weight--not-a-backtestable-number).

## Three complete cycles + cycle 4 in progress (2012-11-28 → 2026-07-20)

Return is the compounded multiple on the $100k BTC base; drawdown is the worst cycle
peak-to-trough of `navWad()`.

| Product | Total return (BTC base) | Worst cycle drawdown | Extra margin posted |
|---|---:|---:|---:|
| Mini (spot hold — baseline) | 4,930x | 84.5 % | — |
| **B4** | **353,850x** | **73.9 %** | — |
| **Pro** | **369,138x** | **73.3 %** | $15k |
| **Pro Max** | **625,543x** | **72.9 %** | $25k |

## Per cycle

Return is the cycle's own multiple; `max DD` is the worst peak-to-trough of `navWad()` inside
the cycle. B4/Pro/Pro Max are in USDC or a short during the bear, so they draw down materially
less than Mini every cycle.

| Cycle | | Mini | B4 | Pro | Pro Max |
|---|---|---:|---:|---:|---:|
| **2012→2016** | return | 51.0x | 137.6x | 143.7x | **231.8x** |
| | max DD | 84.5 % | **73.9 %** | **73.3 %** | **72.9 %** |
| **2016→2020** | return | 13.4x | 52.6x | 52.5x | **55.3x** |
| | max DD | 83.4 % | **64.0 %** | **64.0 %** | **64.1 %** |
| **2020→2024** | return | 7.3x | 29.2x | 29.2x | 29.1x |
| | max DD | 76.8 % | **53.0 %** | **53.0 %** | **53.0 %** |
| **2024→now**\* | return | 0.99x | 1.68x | 1.68x | 1.68x |
| | max DD | 53.7 % | **28.2 %** | **28.2 %** | **28.2 %** |

<sub>\* cycle in progress, read at the last available price date.</sub>

## Reading the result correctly

- **B4/Pro/Pro Max draw down ~10 pp less than Mini every cycle** — they are in USDC (B4) or a
  short (Pro/Pro Max) through the fall, so the cycle bear that takes Mini to −76…−84 %
  contributes far less to them. The drawdown that remains is intra-bull volatility, and it gives
  back accumulated *profit*, not principal.
- **The short's edge is concentrated in cycle 1 and fades.** Cycle 1 (the largest fall, 2012→16)
  separates the products most: Pro Max 231.8x vs B4 137.6x. By cycles 3–4 they converge (29x,
  1.68x) — with a *fixed* margin, the short's notional shrinks relative to a compounding NAV, so
  it moves the needle less. Scaling margin with NAV would keep the short's contribution, at the
  cost of more capital posted (and at risk). The old idealized model hid this by re-applying full
  leverage every cycle.
- **Pro/Pro Max are on the BTC base**, so the margin they also post ($15k/$25k) is not credited
  into the multiple. The margin is preserved (plus the short's realized PnL) and returned; on a
  total-capital basis their multiple is lower than B4's (the idle margin drags it) — which is why
  the BTC-base view is the fair cross-product comparison.

## The survival record — the *designed* structural sizing

This section is about the `StructuralLeverage` library — **designed and unit-tested, not yet
wired into the engine** (the benchmark above runs flat-`φ`). It motivates the §7b redo: it shows
that a flat-`φ` leveraged position would have been liquidated by these historical counter-moves,
whereas a structurally-sized one — stop pinned at a confirmed extreme — survives. Pinned by
[`StructuralLeverageShort.t.sol`](../test/unit/StructuralLeverageShort.t.sol) and
[`StructuralLeverage.t.sol`](../test/unit/StructuralLeverage.t.sol).

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

## Pool weight — not a backtestable number

This section carried two wrong models before landing here. Both are recorded, because the
mistakes are the useful part: they show exactly what the pool is not.

**How a claim is earned.** At every settlement, the vault computes `virtualFee = 4.5 %` of
that interval's profit. Only the operator's slice (`≤ 38.19 %`, i.e. `≤ ~1.72 %` of profit)
is ever paid out — that is the only amount deducted from equity, and it's exactly what the
benchmark above charges. The remainder — `≥ 2.79 %` of profit, the **client share** — is not
lost: `B4VaultOps.opsSettle` adds it to `rewardBaseWad`, a balance that never resets except on
a partial exit (scaled down by the withdrawn fraction). Every settlement, the vault reports its
current `rewardBaseWad` to `B4Pool` as that interval's **weight**.

**How a claim is paid.** The pool's basket for an interval is whatever exit penalties
(`q = 11.8 %` of a penalized exit's position) landed before the interval closed. Distribution
is pro rata by weight: `your_share = bucket × your_weight / total_weight`, where `total_weight`
is the sum of every vault that settled and reported into that same interval.

**Why no multiplier is given here.** Weight is *your own* accumulated performance-fee share —
it scales with your vault's dollar profit (Pro Max generates far more absolute profit than
Mini at the same starting deposit, so it accrues disproportionately more weight, not an equal
cut). Both the basket (penalty volume) and `total_weight` (every *other* vault's own weight)
depend on who else is using the protocol concurrently — a population this backtest has no
grounds to assume. Two earlier drafts of this section put a number on it anyway: first a
"4–5× yield" (accrued penalties at cost, distributed them grown — double-counted the halving
appreciation a stayer's own book already captures), then a "flat ×1.09 transfer, identical for
every product" (ignored that weight is profit-proportional, not presence-proportional). Both
were fabrications dressed as backtest output; neither is in this repo anymore.

What is real and code-grounded: the worked settlement/exit numbers in
[docs/07-fee-routing.md §6](07-fee-routing.md#6-worked-numeric-example), pinned by
`Settle.t.sol`, `Exit.t.sol`, `V3Acct_SettleBasketFee.t.sol`. The mechanism is real and the
client share is never destroyed — its dollar payoff is an ecosystem property, so it stays out
of this benchmark's return figures.

## Model and assumptions

| | |
|---|---|
| Engine | The real `B4Vault`/`B4VaultOps`/`B4Pool`/`HalvingOracle`, cranked and settled like the live keeper. Equity = `navWad()`. |
| Data | Daily closes, 2012-01-01 → 2026-07-20; each run starts at the first halving in range |
| Halvings | Real block timestamps, accepted through the oracle at each epoch boundary |
| Sizing | Flat base `φ` — the shipped engine. `StructuralLeverage` is designed and unit-tested but not wired ([audit record](../AUDIT-2026-07-structural-leverage.md)) |
| Fee | Operator's cut of `Phi.FEE_F` (≤ 38.19 % of 4.5 %) on profit, no high-water mark — charged by `opsSettle` itself, not modelled |
| Margin | Pro/Pro Max post USDC margin for the fall short (this run: $15k/$25k on the $100k BTC base); Mini/B4 post none |
| Pool weight | not included — realized yield depends on ecosystem-wide participation (see [Pool weight](#pool-weight--not-a-backtestable-number)) |

**Operational assumptions that move the result:** the keeper cadence (this run cranks at each
calendar transition and the two settlements, not every block); the margin a short product posts
(more margin → larger short → more fall capture and more risk); and — because NAV excludes
unrealized PnL by design (invariant B3) — the point at which a short is closed and its gain
realized. A single-vault backtest shows the mechanism faithfully; it cannot promise a live
keeper reproduces the multiple to the digit.

**Not modelled:** slippage, market impact, trading fees, async execution delay, the DCA window
averaging of live entries. Perps were not liquid before ~2016, so Pro/Pro Max in cycles 1–2 are
historical hypotheticals. Three completed cycles is not a statistical sample and never can be
(~32 halvings will ever exist).

> **Superseded model.** An earlier `Backtest.t.sol` computed returns in a parallel equity
> calculator instead of the contracts. It re-applied compounding `StructuralLeverage` every cycle
> — leverage the shipped flat-`φ` engine never delivers — reporting e.g. Pro Max 22,542,031x
> (~36× the real 625,543x) and B4 114,693x (vs the real 353,850x). It has been deleted; the
> numbers above are the contract-sourced replacement.

## Data provenance

`data/btcusd_daily.csv` — daily BTC/USD closes, 2012-01-01 → 2026-07-20. History through
2026-05-06 from the project's existing dataset; extended from Binance `BTCUSDT` daily klines.
The two sources agree to within 0.02 % across their six-day overlap.
