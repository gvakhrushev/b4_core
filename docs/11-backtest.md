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
  calls the permissionless keeper makes. Equity is `navWad()`, nothing else.
- **BTC only, short self-funds.** Every vault starts from the same BTC deposit and posts **no
  separate margin**. A short product (Pro / Pro Max) funds its fall short by selling that BTC into
  USDC and reclassifying it as perp collateral — the routing that [V6-M-2](audits/REGISTRY.md) fixed.
- **Income realized per cycle (the "3rd zone").** At each halving the vault fully exits inside the
  20-day penalty-free window — paying the performance fee and **realizing the perp-leg PnL that
  `navWad` excludes by design (invariant B3)** — then re-deposits. So the return is the real,
  compounded, post-fee value a holder would have taken, not an unrealized mark.
- **Structural sizing, but genesis-flat here.** The shipped engine sizes perps by margin control
  against the structural stop (`docs/design/STRUCTURAL-STATE-MACHINE.md`), but this backtest does
  not sample the anchor windows, so the leverage degrades to the genesis flat base `φ` (a leveraged
  long/short still deploys the whole deposit as margin with liquidation at `p/φ²` / `p·φ`). The
  structural amplification (`L > φ` near a confirmed extreme, `sub-1×` deep) is exercised in the
  unit suite (`StructuralAB.t.sol`, `StructuralSizing.t.sol`), not here.
- **Costs charged by the contract itself:** the operator performance fee exactly as `opsSettle`
  and the exit path take it (≤ 38.19 % of the 4.5 % virtual fee, **no high-water mark**), and perp
  funding as the venue applies it. The shared-pool client-share weight is **not** included — see
  [Pool weight](#pool-weight--population-dependent-now-simulated-separately).

## Three complete cycles + cycle 4 in progress (2012-11-28 → 2026-07-20)

Return is the realized, compounded multiple on the BTC deposit; drawdown is the worst cycle
peak-to-trough of `navWad()`.

| Product | Total return | vs HODL | Worst cycle drawdown |
|---|---:|---:|---:|
| HODL (raw BTC, no vault, no fee) | 5,261.092x | 1.0× | ~84 % |
| Mini (spot hold — tracks HODL) | 4,813.714x | 0.915× | 84.45 % |
| **B4** | **345,257.166x** | **65.625×** | **73.85 %** |
| **Pro** | **1,317,056.456x** | **250.339×** | **73.85 %** |
| **Pro Max** | **31,753,217.433x** | **6,035.480×** | **75.40 %** |

> **Audit status.** The V6-M-2 fix passed its adversarial fan-out audit
> ([AUDIT-V7](audits/REGISTRY.md)) — no Critical/High, every finding low and NAV-preserving. The
> self-funded position sizes on strategy value net of the carved margin, landing a few percent
> under `|perpF|·NAV` at the BTC perp's `maxLev = 40`.
>
> **This benchmark deliberately uses the engine's genesis-flat fallback.** The production engine
> is wired for structural margin control, but this file does not sample the anchor windows; their
> getters therefore withhold anchors and correctly degrade to flat `φ`. It is not a benchmark of
> a confirmed-anchor deployment. Pro Max is 1× in the growth phase under BTC-only funding — a
> leveraged long needs margin on top of full spot, which selling spot cannot provide; its `φ` edge
> is the fall short and recovery long. Its downside remains understated: the test venue models no
> liquidation, and `navWad` excludes unrealized perp PnL (B3).

## Per cycle

Return is the cycle's realized multiple; `max DD` is the worst peak-to-trough of **mark-to-market
equity** inside the cycle — `navWad()` plus the perp's unrealized PnL. It must not be measured on
NAV alone: NAV excludes unrealized PnL by invariant B3, and pure-perp Pro Max holds `spot = 0`, so
NAV is blind to its entire position and reports ~0 drawdown no matter what the position does. This
table published that ~0 until 2026-07-31.

B4 and Pro are in USDC or a short during the bear, so they draw down materially less than Mini
every cycle. Pro Max rotates as well and still beats Mini, but it is levered, so it draws
**deeper than both unlevered rotators** in every cycle.

| Cycle | | HODL | Mini | B4 | Pro | Pro Max |
|---|---|---:|---:|---:|---:|---:|
| **2012→2016** | return | 52.3x | 50.8x | 137.2x | 230.8x | **660.4x** |
| | max DD | — | 84.45 % | **73.85 %** | **73.85 %** | 75.40 % |
| **2016→2020** | return | 13.6x | 13.2x | 51.9x | 73.2x | **180.1x** |
| | max DD | — | 83.44 % | **64.04 %** | **64.04 %** | 71.51 % |
| **2020→2024** | return | 7.3x | 7.1x | 28.6x | 45.8x | **125.1x** |
| | max DD | — | 76.81 % | **53.02 %** | **53.02 %** | 56.02 % |
| **2024→now**\* | return | 1.01x | 1.00x | 1.70x | 1.70x | **2.13x** |
| | max DD | — | 53.33 % | **28.15 %** | **28.15 %** | 38.17 % |

<sub>\* cycle in progress: not yet exited, so read as an unrealized mark.</sub>

## Reading the result correctly

- **B4/Pro draw down ~10 pp less than Mini every cycle** — they are in USDC (B4) or a
  short (Pro) through the fall, so the cycle bear that takes Mini to −76…−84 %
  contributes far less to them. The drawdown that remains is intra-bull volatility, and it gives
  back accumulated *profit*, not principal.
- **Pro Max is the exception, and it is the point of the product.** It rotates too, so it stays
  9–19 pp under Mini — but its leveraged growth leg amplifies the pre-rotation decline, so it
  draws 1.5–10 pp deeper than B4/Pro every cycle. It buys return with drawdown; it is not the
  low-risk end of the ladder.
- **Selling the whole spot position to stand up the short makes Pro a full-size short.** That is
  why Pro clears B4 by a wide margin (1.317M× vs 345k×) rather than tracking it — the fix lets the
  fall pay the position, not a small side-margin. Pro Max adds the `φ` leg on top (31.753M×).
- **The short's edge is largest in the deepest completed fall (cycle 1) and compresses later**
  as the cycle falls get shallower. In the still-open fourth epoch Pro equals B4 because its
  fall short has not yet had a completed fall to realize; Pro Max's recovery leg is already ahead.
- **Realizing at the exit matters for the leveraged legs.** Because `navWad` excludes unrealized
  perp PnL (B3), a leg's gain is invisible until the per-cycle exit realizes it — which is why
  Pro Max's realized cycle-1 figure (660.4×) is well above the unrealized mark.

## The survival record — structural sizing, separate from this fallback benchmark

The production engine is wired to `StructuralLeverage` and consumes only density-confirmed
anchors. This particular benchmark runs the intentionally unsampled, genesis-flat fallback
described above, so it must not be cited as a structural-leverage performance result. The
historical reconstruction below shows why confirmed-anchor margin control matters: a flat-`φ`
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
| Sizing | Production engine has structural margin control; this test intentionally does not sample anchors, so its valid fallback is flat base `φ` |
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
