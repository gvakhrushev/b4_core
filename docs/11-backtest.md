# Benchmark: every product driven through the real contracts

Every figure here is `B4Vault.navWad()` read off the **actual deployed contracts** — the real
`B4Vault`/`B4VaultOps`/`B4Pool`/`HalvingOracle` and the reference `Strategy*` — cranked day by
day across the real halving epochs, rotating and settling exactly as the on-chain keeper would.
It is **not** a parallel spreadsheet model.

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
  calls the permissionless keeper makes. Return is `navWad()`; drawdown adds the perp's unrealized
  PnL, which `navWad` excludes by design (B3).
- **BTC only, short self-funds.** Every vault starts from the same BTC deposit and posts **no
  separate margin**. A short product (Pro / Pro Max) funds its fall short by selling that BTC into
  USDC and reclassifying it as perp collateral — the routing that [V6-M-2](audits/REGISTRY.md) fixed.
- **Income realized per cycle (the "3rd zone").** At each halving the vault fully exits inside the
  20-day penalty-free window — paying the performance fee and **realizing the perp-leg PnL that
  `navWad` excludes by design (invariant B3)** — then re-deposits. So the return is the real,
  compounded, post-fee value a holder would have taken, not an unrealized mark.
- **Structural sizing, measured.** The run calls `sampleAnchor` on every daily step, exactly as
  the permissionless keeper does, so the pool confirms its windows and the engine sizes by margin
  control against the structural stop (`docs/design/STRUCTURAL-STATE-MACHINE.md`). The structural
  amplification (`L > φ` near a confirmed extreme, deliberately `sub-1×` deep) is therefore in
  these figures. It used to be absent: the benchmark did not sample, every anchor getter withheld,
  and the engine correctly degraded to the genesis flat base — so what was published was the
  fallback, not the product.
- **Costs charged by the contract itself:** the operator performance fee exactly as `opsSettle`
  and the exit path take it (≤ 38.19 % of the 4.5 % virtual fee, **no high-water mark**), and perp
  funding as the venue applies it. The shared-pool client-share weight is **not** included — see
  [Pool weight](#pool-weight--population-dependent-now-simulated-separately).

## Three complete cycles + cycle 4 in progress (2012-11-28 → 2026-07-20)

Return is the realized, compounded multiple on the BTC deposit; drawdown is the worst cycle
peak-to-trough of mark-to-market equity (`navWad()` + unrealized perp PnL).

| Product | Total return | vs HODL | Worst cycle drawdown |
|---|---:|---:|---:|
| HODL (raw BTC, no vault, no fee) | 5,261.092x | 1.0× | ~84 % |
| Mini (spot hold — tracks HODL) | 4,813.714x | 0.915× | 84.45 % |
| **B4** | **345,257.166x** | **65.625×** | **73.85 %** |
| **Pro** | **1,814,284.221x** | **344.847×** | **73.85 %** |
| **Pro Max** | **188,693,627.296x** | **35,865.3×** | **75.40 %** |

> **Audit status.** The V6-M-2 fix passed its adversarial fan-out audit
> ([AUDIT-V7](audits/REGISTRY.md)) — no Critical/High, every finding low and NAV-preserving. The
> self-funded position sizes on strategy value net of the carved margin, landing a few percent
> under `|perpF|·NAV` at the BTC perp's `maxLev = 40`.
>
> **This benchmark now measures the confirmed-anchor deployment.** The run samples the anchor
> windows daily, so the pool confirms them and the engine sizes by margin control against the
> structural stop. The figures moved when it started doing so — Pro Max 31.7M× → 188.7M×, and its
> cycle-4 drawdown 38.17 % → 48.86 % — because what was published before was the genesis-flat
> fallback, not the product.
>
> That also removes the contradiction this section used to carry. The survival record below says a
> flat-`φ` position is liquidated by the 2015 and 2018 bear rallies and the 2020 COVID crash, all
> three inside the benchmark's window — and the benchmark used to run flat `φ` on a venue that
> models no liquidation, so its levered multiples described a position that would not have
> survived the period. The structural stop is the answer to exactly those three episodes: it sits
> at a confirmed extreme the market printed and failed to regain, and across every completed cycle
> it was **never touched**. The run measures that configuration now, so the no-liquidation venue
> is no longer papering over a position that needed one.

## Per cycle

Return is the cycle's realized multiple; `max DD` is the worst peak-to-trough of **mark-to-market
equity** inside the cycle — `navWad()` plus the perp's unrealized PnL. It must not be measured on
NAV alone: NAV excludes unrealized PnL by invariant B3, and pure-perp Pro Max holds `spot = 0`, so
NAV is blind to its entire position and reports ~0 drawdown no matter what the position does. This
table published that ~0 until 2026-07-31.

Which ZONE sets the worst drawdown is the mechanism itself. Mini holds spot through the bear and
sets its worst drawdown **inside the fall zone in all four cycles** (days 776/888/923/800 of the
1460-day cycle; the fall runs 548→912). B4, Pro and Pro Max are in USDC or short there and set
theirs **outside it in all four** — in growth (days 133/434/352/106) or recovery (day 1345). That
is asserted, not observed in passing: `test_real_all_products` fails if a rotating product ever
takes its worst drawdown in the fall.

| Cycle | | HODL | Mini | B4 | Pro | Pro Max |
|---|---|---:|---:|---:|---:|---:|
| **2012→2016** | return | 52.3x | 50.8x | 137.2x | 230.3x | **660.0x** |
| | max DD | — | 84.45 % | **73.85 %** | **73.85 %** | 75.40 % |
| **2016→2020** | return | 13.6x | 13.2x | 51.9x | 73.1x | **277.7x** |
| | max DD | — | 83.44 % | **64.04 %** | **64.04 %** | 71.86 % |
| **2020→2024** | return | 7.3x | 7.1x | 28.6x | 45.8x | **253.0x** |
| | max DD | — | 76.81 % | **53.02 %** | **53.02 %** | 58.11 % |
| **2024→now**\* | return | 1.01x | 1.00x | 1.70x | 2.35x | **4.07x** |
| | max DD | — | 53.33 % | **28.15 %** | **28.15 %** | 48.86 % |

<sub>\* cycle in progress: not yet exited, so read as an unrealized mark.</sub>

## Reading the result correctly

- **B4/Pro/Pro Max draw down ~10 pp less than Mini every cycle** — they are in USDC (B4) or a
  short (Pro/Pro Max) through the fall, so the cycle bear that takes Mini to −76…−84 %
  contributes far less to them. The drawdown that remains is intra-bull volatility, and it gives
  back accumulated *profit*, not principal.
- **The three rotating products take their worst hits on the same days as each other** — the
  April-2013 crash sets all three in cycle 1 — because in the growth zone they are all ~1× long.
  Pro Max's growth exposure sits slightly above 1× (≈1.05× in cycle 1, ≈1.23× in cycle 2), which
  is why it reads a point or two deeper there. That is composition, not a risk property of the
  levered product, and it is deliberately NOT asserted: pinning a basis-point ordering would
  encode noise as a claim.
- **Selling the whole spot position to stand up the short makes Pro a full-size short.** That is
  why Pro clears B4 by a wide margin (1.814M× vs 345k×) rather than tracking it — the fix lets the
  fall pay the position, not a small side-margin. Pro Max adds the `φ` leg on top (31.753M×).
- **The short's edge is largest in the deepest completed fall (cycle 1) and compresses later**
  as the cycle falls get shallower. In the still-open fourth epoch Pro equals B4 because its
  fall short has not yet had a completed fall to realize; Pro Max's recovery leg is already ahead.
- **Realizing at the exit matters for the leveraged legs.** Because `navWad` excludes unrealized
  perp PnL (B3), a leg's gain is invisible until the per-cycle exit realizes it — which is why
  Pro Max's realized cycle-1 figure (660.4×) is well above the unrealized mark.

## The survival record — structural sizing, separate from this fallback benchmark

The production engine is wired to `StructuralLeverage` and consumes only density-confirmed
anchors. This benchmark samples those windows daily, so the figures above ARE a structural-leverage
result — which they were not before, when the run went unsampled and the engine degraded to the
flat base. The historical reconstruction below is why that distinction decides the numbers: a
flat-`φ`
leveraged position would have been liquidated by these counter-moves, whereas a structurally
sized one — stop pinned at a confirmed extreme — survives. Pinned by
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

## Pool return — a closed population, not an assumed APY

**How a claim is earned.** At every settlement, the vault computes `virtualFee = 4.5 %` of
that interval's profit. Only the operator's slice (`≤ 38.19 %`, i.e. `≤ ~1.72 %` of profit)
is ever paid out — that is the only amount deducted from equity, and it's exactly what the
benchmark above charges. The remainder — `≥ 2.79 %` of profit, the **client share** — is not
lost: `B4VaultOps.opsSettle` adds it to `rewardBaseWad`, a balance that never resets except on
a partial exit (scaled down by the withdrawn fraction). Every settlement, the vault reports its
current `rewardBaseWad` to `B4Pool` as that interval's **weight**.

**How a claim is paid.** The pool's basket for an interval is whatever exit penalties
(`q = 11.803398… %` of a penalized exit's position) have *realised* by that interval.
Distribution is pro rata by weight: `your_share = bucket × your_weight / total_weight`, where
`total_weight` is the sum of every vault that settled and reported into that same interval.

[`ClosedPopulation.t.sol`](../test/backtest/ClosedPopulation.t.sol) is the contract-backed
population runner used for this component. Its inputs are deliberately limited to the ones the
protocol actually has:

- entry date;
- one of Mini, B4, Pro, or Pro Max; and
- `r`, the fraction of equal daily participants that exits early (`10%` = 9 stayers / 1 exiter;
  `20%` = 8 stayers / 2 exiters).

Each participant deposits the same daily USD value in BTC whenever the calendar accepts
deposits. A daily exiter uses the real exit state machine. Outside a free window the measured
in-kind receipt enters the selected strict pool's product escrow, is folded into its fixed
sleeve, and follows the ordinary engine. At the next free window that sleeve exits; only its
returned, realised tokens become `accruing`, then an interval basket and finally a `claimFor`
payout. A Pro or Pro Max penalty is therefore neither a passive BTC basket nor a fixed
percentage yield.

HODL receives the same accepted daily BTC cash flows. The run records the eight free-zone
boundaries per epoch and run end; claims are made on the first eligible daily close. A live
sleeve or an unmaterialized tail at the end is not silently counted as a participant payout.

**Valuation (A45) — the paired runs.** Claims are paid in kind, and the two kinds do opposite
things if simply held: a BTC claim keeps riding the asset, a USDC claim stays at par. Valuing
every claim "held untouched to run end" (the previous convention) therefore measured the payout
form, not the pool, and inverted the real ranking. Each `r = 20 %` scenario now runs **twice** —
once with claims left where they land, once with every stayer redepositing each claim into its
own vault on the receipt day, the benchmark's own realize-and-redeposit convention. The pool
add-on is the difference of the paired final **mark-to-market** values (A42: the final read may
hold an open perp leg that NAV excludes), read off the contracts:

| Product | final MTM, claims redeposited | final MTM, no redeposit | pool add-on | share of final |
|---|---:|---:|---:|---:|
| Mini | 7,247,183 | 7,066,831 | 180,352 | 2.49 % |
| B4 | 458,489,291 | 446,475,400 | 12,013,891 | 2.62 % |
| Pro | 2,569,790,258 | 2,497,776,168 | 72,014,090 | 2.80 % |
| Pro Max | 35,214,548,447 | 34,527,123,323 | 687,425,124 | 1.95 % |

<sub>MTM columns are floored to whole dollars and the add-on is the rounded WAD difference, so
every row adds up exactly as printed; the raw WAD values are in the test logs.</sub>

**Per-cycle matrix.** The `*_percycle` tests run the same pair per cycle: the population enters
at each halving, is measured at the next (cycle 4 to the end of data), and the add-on is the
paired difference of **mark-to-market** target value — a cycle boundary can hold an open perp
leg that `navWad` excludes by B3, so subtracting NAVs there would re-create the A41 blindness.
Per $100 deposited during the cycle (strategy DCA multiple of the same run in parentheses):

| Product | Cycle 1 | Cycle 2 | Cycle 3 | Cycle 4* |
|---|---:|---:|---:|---:|
| Mini | $11.57 (×5.22) | $8.63 (×3.55) | $4.88 (×2.60) | $1.45 (×0.81) |
| B4 | $32.86 (×12.21) | $30.79 (×13.01) | $13.76 (×6.40) | $2.84 (×1.21) |
| Pro | $55.35 (×19.57) | $46.52 (×19.41) | $22.84 (×9.34) | $3.58 (×1.64) |
| Pro Max | $87.09 (×44.07) | $97.42 (×64.97) | $58.39 (×31.89) | $4.99 (×2.32) |

The add-on is strictly increasing in strategy strength in every cycle. Note the basis: these are
DCA-through-the-cycle multiples of this population, not the README's enter-at-the-pivot lump
multiples; and each `assertGt(mtmRedep, mtmPlain)` pins that the pool adds value in every
cycle. The README's benchmark charts are generated from these tables by
`docs/assets/gen_charts.py`.

The absolute add-on rises with the strategy. The *production* side is pinned separately by
[`PoolYieldDiag.t.sol`](../test/backtest/PoolYieldDiag.t.sol), a value-conservation audit of
the whole pipeline (folds → sleeve equity → capture → claims → residuals): on identical inflows
(23.167 BTC folded for every product) the value each sleeve realizes into the basket, priced on
its realization days, is Mini 33,626 < B4 34,442 < Pro 34,956 < Pro Max 44,500, and the
unlevered sleeve conserves the penalty in kind to within its live tail. Two bounded payout-form
effects remain and are visible in the receipt-day claims (Pro Max ≈ 5,581 vs Mini ≈ 10,391):
realizing a settlement-margined perp returns settlement token, and realized inventory waits in
`accruing` until the next settlement point (~1.5 years for a halving-window capture) — in BTC
for Mini, flat in USDC for Pro Max. The parking is real protocol behaviour; the 13-year freeze
was not.

[`PoolClaimFlow.t.sol`](../test/backtest/PoolClaimFlow.t.sol) fixes the simple 20% case: two
penalized $1,000 exits at BTC $1,000 create exact `q`-sized BTC inventory; at $5,000 an
equal-weight stayer receives one eighth, $147.54245, or +14.754245% of its original $1,000.
The difference from an 11% hand estimate is the exact `q = 11.803398…%` and 8-decimal token
flooring.

An aggregate pool deliberately has no universal table: it needs one more user-supplied input,
the product mix of other participants, because Mini/B4/Pro/Pro Max carry different reward
weights. The contract supports aggregate pool `15`; a calculator must expose the mix instead of
inventing a dilution rate.

Run the current matrix with:

```bash
forge test --match-path test/backtest/ClosedPopulation.t.sol -vv
forge test --match-path test/backtest/PoolClaimFlow.t.sol -vv
```

## Model and assumptions

| | |
|---|---|
| Engine | The real `B4Vault`/`B4VaultOps`/`B4Pool`/`HalvingOracle`, cranked and settled like the live keeper. Equity = `navWad()`. |
| Data | Daily closes, 2012-01-01 → 2026-07-20; each run starts at the first halving in range |
| Halvings | Real block timestamps, accepted through the oracle at each epoch boundary |
| Sizing | Structural margin control, with the anchor windows sampled daily as the keeper does |
| Fee | Operator's cut of `Phi.FEE_F` (≤ 38.19 % of 4.5 %) on profit, no high-water mark — charged by `opsSettle` and the exit path themselves, not modelled |
| Funding | Realized by the mock venue on close; the deposit is BTC only (a short self-funds by selling spot — V6-M-2) |
| Realization | Full exit in the post-halving free window each cycle, then re-deposit — realizes the perp PnL that `navWad` excludes (B3) |
| Pool return | not included in this single-vault benchmark; the closed-population runner above measures strict-pool claims separately |

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

## Data provenance

`data/btcusd_daily.csv` — daily BTC/USD closes, 2012-01-01 → 2026-07-20. History through
2026-05-06 from the project's existing dataset; extended from Binance `BTCUSDT` daily klines.
The two sources agree to within 0.02 % across their six-day overlap.
