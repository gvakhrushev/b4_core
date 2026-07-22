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
- **BTC only, short self-funds.** Every vault starts from the same BTC deposit and posts **no
  separate margin**. A short product (Pro / Pro Max) funds its fall short by selling that BTC into
  USDC and reclassifying it as perp collateral — the routing that [V6-M-2](audits/AUDIT-V6.md) fixed.
- **Income realized per cycle (the "3rd zone").** At each halving the vault fully exits inside the
  20-day penalty-free window — paying the performance fee and **realizing the perp-leg PnL that
  `navWad` excludes by design (invariant B3)** — then re-deposits. So the return is the real,
  compounded, post-fee value a holder would have taken, not an unrealized mark.
- **Flat-`φ` sizing.** The shipped engine sizes perps at the flat base `φ`, not structural
  leverage (the `StructuralLeverage` library is designed and tested but not wired — see
  [audit record](audits/AUDIT-2026-07-structural-leverage.md)). Pro Max's edge here is the `φ`
  base target, not a structural amplification.
- **Costs charged by the contract itself:** the operator performance fee exactly as `opsSettle`
  and the exit path take it (≤ 38.19 % of the 4.5 % virtual fee, **no high-water mark**), and perp
  funding as the venue applies it. The shared-pool client-share weight is **not** included — see
  [Pool weight](#pool-weight--not-a-backtestable-number).

## Three complete cycles + cycle 4 in progress (2012-11-28 → 2026-07-20)

Return is the realized, compounded multiple on the BTC deposit; drawdown is the worst cycle
peak-to-trough of `navWad()`.

| Product | Total return | vs HODL | Worst cycle drawdown |
|---|---:|---:|---:|
| HODL (raw BTC, no vault, no fee) | 5,261x | 1.0× | ~84 % |
| Mini (spot hold — tracks HODL) | 4,814x | 0.9× | 84.5 % |
| **B4** | **345,052x** | **66×** | **73.9 %** |
| **Pro** | **1,410,032x** | **268×** | **73.9 %** |
| **Pro Max** | **9,728,705x** | **1,850×** | **73.9 %** |

> **Pending audit.** The V6-M-2 fix that lets the short self-fund is regression-green (269/269)
> but has not yet passed the adversarial fan-out audit our discipline requires for a core
> money-routing change. Treat the Pro/Pro Max figures as pending that gate.
>
> **Pro Max downside is understated twice:** the test venue models no liquidation (a `φ`-long
> through a deep enough drawdown would be liquidated live), and `navWad` excludes unrealized perp
> PnL (B3). The engine also sizes leverage flat-`φ`, not the structural stops below.

## Per cycle

Return is the cycle's realized multiple; `max DD` is the worst peak-to-trough of `navWad()`
inside the cycle. B4/Pro/Pro Max are in USDC or a short during the bear, so they draw down
materially less than Mini every cycle.

| Cycle | | HODL | Mini | B4 | Pro | Pro Max |
|---|---|---:|---:|---:|---:|---:|
| **2012→2016** | return | 52.3x | 50.8x | 137.2x | 216.6x | **365.6x** |
| | max DD | — | 84.5 % | **73.9 %** | **73.9 %** | **73.9 %** |
| **2016→2020** | return | 13.6x | 13.2x | 51.9x | 82.2x | **154.5x** |
| | max DD | — | 83.4 % | **64.0 %** | **63.6 %** | **63.5 %** |
| **2020→2024** | return | 7.3x | 7.1x | 28.5x | 46.7x | **97.5x** |
| | max DD | — | 76.8 % | **53.0 %** | **52.9 %** | **50.4 %** |
| **2024→now**\* | return | 1.01x | 1.00x | 1.70x | 1.69x | 1.77x |
| | max DD | — | 53.3 % | **28.2 %** | **28.1 %** | **21.8 %** |

<sub>\* cycle in progress: not yet exited, so read as an unrealized `navWad` mark.</sub>

## Reading the result correctly

- **B4/Pro/Pro Max draw down ~10 pp less than Mini every cycle** — they are in USDC (B4) or a
  short (Pro/Pro Max) through the fall, so the cycle bear that takes Mini to −76…−84 %
  contributes far less to them. The drawdown that remains is intra-bull volatility, and it gives
  back accumulated *profit*, not principal.
- **Selling the whole spot position to stand up the short makes Pro a full-size short.** That is
  why Pro clears B4 by a wide margin (1.4M× vs 345k×) rather than tracking it — the fix lets the
  fall pay the position, not a small side-margin. Pro Max adds the `φ` leg on top (9.7M×).
- **The short's edge is largest in the deepest fall (cycle 1) and compresses later** as the
  cycle falls get shallower — but it never inverts: Pro/Pro Max beat B4 in every cycle.
- **Realizing at the exit matters for the leveraged legs.** Because `navWad` excludes unrealized
  PnL (B3), Pro Max's recovery perp-long is invisible until the per-cycle exit realizes it — which
  is why the realized cycle-1 figure (365.6×) is well above the unrealized mark.

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
| Sizing | Flat base `φ` — the shipped engine. `StructuralLeverage` is designed and unit-tested but not wired ([audit record](audits/AUDIT-2026-07-structural-leverage.md)) |
| Fee | Operator's cut of `Phi.FEE_F` (≤ 38.19 % of 4.5 %) on profit, no high-water mark — charged by `opsSettle` and the exit path themselves, not modelled |
| Funding | Realized by the mock venue on close; the deposit is BTC only (a short self-funds by selling spot — V6-M-2) |
| Realization | Full exit in the post-halving free window each cycle, then re-deposit — realizes the perp PnL that `navWad` excludes (B3) |
| Pool weight | not included — realized yield depends on ecosystem-wide participation (see [Pool weight](#pool-weight--not-a-backtestable-number)) |

**Operational assumptions that move the result:** the keeper cadence (this run cranks at each
calendar transition, the two settlements, and the per-cycle exit — not every block), and the exit
timing inside the free window (NAV excludes unrealized PnL by design, B3, so *when* a leg is
realized matters). A single-vault backtest shows the mechanism faithfully; it cannot promise a
live keeper reproduces the multiple to the digit.

**Not modelled:** slippage, market impact, trading fees, async execution delay, the DCA window
averaging of live entries, and **perp liquidation** — the mock venue does not liquidate, so a
leveraged leg's deep-drawdown risk is understated (real Pro Max would face margin calls the
benchmark cannot show). Perps were not liquid before ~2016, so Pro/Pro Max in cycles 1–2 are
historical hypotheticals. Three completed cycles is not a statistical sample (~32 halvings will
ever exist). The base is $1,000 of BTC (small enough that the most-leveraged product's ~10⁷×
compounded NAV stays inside the mock's uint64 accounting; multiples are scale-invariant).

> **Superseded models (both deleted).** (1) A hand-rolled parallel equity calculator
> (`Backtest.t.sol`) re-applied compounding `StructuralLeverage` every cycle the flat-`φ` engine
> never delivers — Pro Max 22,542,031x. (2) A first real-contract pass required a separate USDC
> margin deposit — a workaround for the V6-M-2 routing bug, which is now fixed so the short
> self-funds. The numbers above are the current, contract-sourced result.

## Data provenance

`data/btcusd_daily.csv` — daily BTC/USD closes, 2012-01-01 → 2026-07-20. History through
2026-05-06 from the project's existing dataset; extended from Binance `BTCUSDT` daily klines.
The two sources agree to within 0.02 % across their six-day overlap.
