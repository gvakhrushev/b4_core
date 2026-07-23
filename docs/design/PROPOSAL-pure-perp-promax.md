# Proposal: pure-perp leveraged products (Pro Max) + 2nd-anchor structural leverage

**Status:** in progress (steps 1–2 implemented + validated, uncommitted; steps 3–4 pending).
**Owner decision (2026-07-23):** full redesign. Driver: a BTC-only Pro Max must open a
**leveraged perp long** ("это суть про макс"), not sit 1× in spot.

## The four steps

### 1. Pure-perp decompose — DONE, verified

`Calendar.decompose(n)`: the spot leg exists only for an **unlevered long** (`0 ≤ n ≤ 1`, held
in the asset — no funding, no liquidation); any leverage (`|n| > 1`) or short is a **pure perp**
(`spot = 0`, `perp = n`). Makes Pro Max symmetric — `φ` perp long in growth, `φ` perp short in the
fall — and lets the whole position self-fund by selling the deposited spot into margin.

Verified: `test_real_promax_leverage_by_zone` — growth-mid `szi = +1.22M` (was 0), fall short,
recovery long. `SPECIFICATION §5` must be updated (currently mandates `spot = clamp(n,0,1)`).

### 2. USDC = strategy capital — DONE, but ripples (needs care)

`B4Vault.deposit` routes USDC to `usdcRotatedEvm` (strategy) instead of `usdcMarginEvm` (the
segregated owner-margin reserve). Required because a pure-perp exit returns USDC, and a USDC
re-deposit was inert (`_strategyValueWad` excluded the margin reserve → `notional = φ·0 = 0`).
With USDC as strategy capital the perp margins from it via the V6-M-2 reclassify.

Validated the multi-cycle benchmark now levers every cycle (Pro Max cycle 2: 1.0× → 199×, cycle
3: 1.0× → 119×). **BUT** this reverses the B3 invariant ("owner margin MUST NOT increase strategy
notional", SPEC §5) and breaks ~9 tests. Two failures look like **real** accounting issues from
the routing change, not stale assertions — investigate before trusting step 2:
- `test_V6B_2d_settle_exit_waterfall_conservation`: `usdc dust 17,784 > 10` — dust no longer bounded.
- `test_residual_perp_position_never_closed_below_min_order`: `TransferFailed()`.
Mechanical (stale-B3) updates: `test_V6B_2a_usdc_only_deposit_zero_exposure` (now HAS exposure —
the fix), `test_deposit_measuredDelta_and_entryLedger`, `test_margin_returns_when_target_zero_and_flat`,
`test_promax_opens_leveraged_long` (16180 → 18145), `test_D_spot_only_perp_policy_degrades_and_recovers`,
`test_V6B_2b_exit_realizes_hidden_loss_before_payment`, `test_decompose`.

### 3. Wire the EXISTING 2nd-anchor `StructuralLeverage` for Pro Max — PENDING (the hard part)

**This is not a design task — the library is written and unit-tested** (`StructuralLeverage.sol`,
`StructuralLeverage.t.sol`, `StructuralLeverageShort.t.sol`). It is Pro Max's leverage source, not
flat-`φ`:
- **Long:** anchors `floor` (prev-cycle confirmed low) + `cap` (last confirmed low).
  `stop = min(p − (p−floor)/g, cap)`, `L = p/(p−stop)`.
- **Short:** anchors `prevPeak` (prev-cycle peak) + `peakC` (peak-window max).
  `maxStop = C + (C−prevPeak)·θ`, `stop = max(p + (maxStop−p)·θ, C)`. The **2nd anchor
  (`prevPeak`) BOOSTS leverage above `φ` near the extreme** (cycle-4 pivot ≈ 4.8×).

The stop sits at a **confirmed extreme** the market has proven it cannot regain → the leveraged
position **survives** the intra-cycle crashes a flat-`φ` perp is liquidated by. Pure-perp is a
CLEANER fit than the old spot-base: the structural stop now governs the **whole** position, not
just the `0.618` excess.

**Why it is the hard/risky part:** the engine WIRING (perp sized by `L`, margin = notional/`L`,
re-sizing a HELD position) was implemented, audited, and **reverted** on C1/C4 "re-lever
detonation" ([[structural-leverage-status]], `docs/audits/AUDIT-2026-07-structural-leverage.md`).
Redo needs the diminishing-returns window cap (SPEC §7b caveat) and a post-implementation
adversarial audit.

**Until step 3 lands, the benchmark Pro Max numbers are INFLATED** — flat-`φ` + MockCore models
no liquidation, so the `φ`-perp "survives" crashes it would be liquidated by live. The numbers
become honest/survivable only once the structural stop sizes the position.

### 4. Re-audit + spec (§5 decompose, §5/§7b margin/B3) + docs + benchmark — PENDING

## Current tree state

Steps 1–2 are **uncommitted**. The committed HEAD is green (269/269). Do not present the current
inflated benchmark numbers as final.
