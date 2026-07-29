# AUDIT-V8 — full security audit of the pure-perp redesign + §7b structural wiring

**Date:** 2026-07-23 · **Target: the WORKING TREE** — HEAD `bea4514` ("pre-register structural-leverage wiring") **plus the uncommitted step-3 WIP** (margin-control engine wiring, peak ratchet, rewritten `StructuralLeverage`, claimFor gate, exit stop-clear). Auditing the WIP was the point of the round: the team's own redo requirements mandate a fresh post-implementation adversarial pass before this code is committed.
**Baseline:** `forge build` OK · **289 passed / 4 skipped / 293, 47 suites** · B4Vault 24,287 B (289 B EIP-170 margin)
**With V8 PoCs:** **322 passed / 0 failed / 4 skipped, 56 suites** — 33 new adversarial tests, all passing
**Naming:** the team's internal fan-out on the V6-M-2 fix self-labeled "audit-v7" (`AUDIT-V7.md`). This is the next independent round — **V8** (series: V3 → V4 → V6 → V8).

## What changed since AUDIT-V6

**Committed (`4d418ff..bea4514`):** the V6-M-2 fix (`_reclassifyUsdc` — a fall short self-funds by selling spot) + the team's AUDIT-V7 fan-out on it (5 lows, fork); **pure-perp steps 1–2** — `Calendar.decompose` is now `spot = (0≤n≤1) ? n : 0`, `perp = n − spot` (any `|n|>1` or any short is a pure USDC-margined perp) and USDC deposits land in `usdcRotatedEvm` as **strategy capital** (a deliberate reversal of the old B3 owner-margin-reserve invariant); `BacktestReal.t.sol` drives the real contracts (the hand-rolled model is deleted); pool-yield "transfer not multiple" correction; repo reorg (audits/design under `docs/`); CI size gate scoped to production contracts.

**Uncommitted WIP (the step-3 redo itself):** margin-control sizing in `B4VaultEngine._planPerpStep` (~360 new lines) — frozen `perpStopWad`+`perpStopLong` re-derived every idle crank while flat and held unchanged while live; adds sized at the live mark (`szi_inc = Δm/|mark−stop|`); reduces proportional at the frozen avg entry; venue-`maxLeverage` clamp; zone/freshness-gated stops (`_longStopWad`: L-win/L-halving/L-post/L-rise; `_shortStopWad`: Pro flat `max(2p, C)`, Pro Max 2-anchor, `C` fed only in Fall with `peakTag == epoch+1`); the mirror **peak ratchet** in `B4Pool.sampleAnchor` + `peaks()`; `claimFor` restricted to the latest interval; `_finalizeExit` clears the frozen stop; new `StructuralLeverage` primitives (`longStop/longLev/shortStructStop/shortStructLev/shortFlatStop/shortFlatLev`).

**Method:** five parallel adversarial scopes (engine wiring / library + AB fidelity / pool ratchets / committed deltas + skips / campaigns + docs), refute-by-default, PoC-or-precise-argument, every finding adjudicated by the lead auditor against the cited lines and by personally re-running the key PoCs.

## Verdict

**No Critical or High.** The margin-control rewrite is **verified sound on its core claims** — with passing PoCs: a fresh open's venue liquidation equals the frozen stop (≤0.1 %, safe side); adds at a mark 40 % from the avg entry keep the combined liquidation pinned to the stop; reduces never pull liquidation closer; the maxLev clamp always moves liquidation *further* than the stop (both sides); a held position is not re-traded by price moves, anchor samples, halving flips, ADL, funding gaps, or exits; the Pro Max transition choreography (perp → spot interlude → perp) leaks nothing. The team's 2026-07-23 fan-out fix claims all reproduce as true. **4 Medium, 8 Low, 11 Informational.** The center of gravity has moved exactly where V6 predicted: **anchor data quality is now the live risk** — the ratchets feed real liquidation stops today.

---

## Medium

### V8-M-1 — Under-sampled anchors produce LIVE over-leverage (sparse peak confirmed; V6-M-1 now load-bearing)
**Status: CONFIRMED (PoC `test/unit/V8C_SparsePeak.t.sol`) · `src/core/B4Pool.sol:231-244` → `src/core/B4VaultEngine.sol:1094-1104`**

The freshness gate (`peakTag == epoch+1`) checks THAT the peak window was sampled, not HOW DENSELY. The peak ratchet is reseed-to-first + up-only MAX, so a window sampled **once at its open** leaves `peakC` low ⇒ `maxStop = C + (C−Pp)/φ` low ⇒ **short leverage high**. PoC: prevPeak 100k, sparse `C` 110k vs true 130k, Fall entry 90k → the engine froze stop 116.18k and realized **3.44× vs the honest 1.54×** — and the realized liquidation (~116k) sits **below the true printed peak 130k, inside the market-proven range**, breaking the core safety claim "liquidation beyond the confirmed extreme". The venue maxLev clamp (40) does not engage at 3.44×. Requires no attacker: keeper failure or an unwatched thin asset suffices (permissionless pools), and every vault on the pool consumes the anchor via margin control **today**. The low side is the same class (V6-M-1: sparse 62-window ⇒ floor biased high ⇒ over-levered longs) — latent in V6, now equally live. V6's own recommendation conditioned a density gate on landing BEFORE §7b consumes anchors; the wiring shipped without it.
**Fix:** promotion/freshness eligibility requires ≥ N distinct samples spanning ≥ W/2 of the window (store count + first/last sample time), else the window does not confirm (fail-safe: long floor stays low; short `C` is not fed — flat-φ degrade). Plus a keeper-sampling incentive.

### V8-M-2 — Peak wick-poisoning: unrepairable in-window; next-cycle over-leverage or a full-cycle short outage
**Status: CONFIRMED (PoCs `test/unit/V8C_PeakWick.t.sol`, 3 directions) · `src/core/B4Pool.sol:235-238`**

The up-only MAX has no mirror of the low ratchet's F1 parity guard: one wicked-high spot print **cannot be repaired within the window** (honest samples can only push higher) and promotes to `prevPeak` at the next epoch. Mapped: **(this cycle)** maxStop higher ⇒ 0.30× vs 0.86× honest — fail-safe; **(next cycle, wick ≥ C′)** delta collapses ⇒ `shortStructStop` refuses ⇒ **no short for the entire Fall** (full-cycle product outage); **(next cycle, wick < C′)** delta shrinks ⇒ **3.58× vs honest 1.96×** with beyond-extreme placement intact. Persistence is one cycle (self-flushes, PoC'd). Cost: one wick print on a thin asset (`spotPxWad` is order-book-derived); payoff: a pool-wide cycle of over-leverage or a griefing outage.
**Fix:** same density gate as V8-M-1; consider median-of-samples or a sanity band instead of a raw MAX; optionally promote `prevPeak` at the halving flip (mirroring the low side) to shorten the poisoning window.

### V8-M-3 — User-facing benchmark and shipped-status claims are stale in BOTH directions; the test pins cannot catch the drift
**Status: CONFIRMED (run + quoted lines) · `README.md:37-38,181-197,228-234`, `docs/11-backtest.md:52-54,65,104-105,161`, `test/backtest/BacktestReal.t.sol`**

Measured on this tree: Pro Max compounded **31,753,217×** vs README's 9,728,705× (**3.26× under-claim**); Pro 1,317,056× vs 1,410,032× (−6.6 % over-claim); Pro Max cycle-1 max drawdown actual ~0–196 bps vs README's "73.9 %" (the mock has no liquidation/funding/taker fee and NAV excludes unrealized PnL — perp-product drawdowns are understated by construction). Meanwhile the "engine sizes flat-`φ` today / design target, not shipped behaviour" disclaimers (README:37-38, 228-234; docs/11 ×5) are now **false in the opposite direction** — structural sizing is wired and drives the benchmark. Root cause: `BacktestReal` asserts only relative ordering (`ProMax > Pro > B4 > Mini`) and a wide Mini band, so the exact table drifts silently. The team rated this exact class High as V5-F9 ("docs sold the structural stop as shipped"); consistency demands the same seriousness now that the numbers understate leverage economics and overstate survival.
**Fix:** regenerate the tables from the current run; delete/replace the flat-φ disclaimers; pin the compounded multiples (or ±bands) as assertions in `BacktestReal.t.sol`; add a drawdown-honesty note (mock limits).

### V8-M-4 — Carried from V6: spot orders still emitted below the $10 venue minimum after lot flooring
**Status: still live (characterization PoC `test/unit/V6D_VenueGaps.t.sol`) · `src/core/B4VaultEngine.sol:325-357`**

V6-M-4 is not fixed: `_startSpotOrder` floors to whole lots and only rejects `sz == 0`; when one lot's value exceeds `diff − $10` the emitted order is below the venue minimum (PoC: 1-lot $6 order on a $10.50 diff), the live venue rejects (no spot reduce-only exemption), and the planner resend-wedges until drift (H3). MockCore fills anything, hiding the class. Unchanged by the WIP.
**Fix:** recompute order notional after lot flooring; hold unless `sz·px ≥ MIN_ORDER_USD_WAD`.

---

## Low

| # | Finding | Status | Site |
|---|---|---|---|
| V8-L-1 | **V6-L-1 only partially fixed:** `_planPerpStep` has the zero-mark guard (`:1024`) but the **exit flatten** calls `_startPerpOrder` directly — a halted mark still emits reduce-only `limitPx == 0` → live rejection → resend wedge **mid-exit** (H3, self-heals on feed return). Mirror the F4 guard inside `_startPerpOrder`. | CONFIRMED (PoC `V8D_Adapted.t.sol` characterization) | `B4VaultOps.sol:171-173` → `B4VaultEngine.sol:408` |
| V8-L-2 | **Skipped peak window silently degrades the Fall short to genesis flat-φ** (fail-safe, but silent and product-visible): `prevPeak` promotes only inside a peak-window sample, so one skip strands it at 0 and gates `C` out. Optional: promote `prevPeak` at the halving flip (mirror the low ratchet). | CONFIRMED (PoC `V8C_SparsePeak.t.sol`) | `B4Pool.sol:236` |
| V8-L-3 | **claimFor latest-only gate — intended, but docs stale:** `docs/08-keeper.md:141` still says a deferred token claim is "fully retryable" (retry now dies at successor materialization) and describes a "1h" lock window (24h since the V5 era). Two one-line corrections. | CONFIRMED (behavior PoC `V8C_ClaimGate.t.sol`; intent pinned by `B4Pool.t.sol:368` + ARCHITECTURE:124) | `B4Pool.sol:329`, `docs/08-keeper.md:138-141` |
| V8-L-4 | **maxLev-clamp re-trade vs the "held ⇒ never re-traded" claim:** after a clamped open, a price rise shrinks `maxSz` below `absNow`, so the engine REDUCES a held position. Direction is safe (de-lever + profit-take, liquidation deeper); no value leak. Document the clamp as an exception, or gate the clamp to `max(maxSz, absNow)` once live. | ARGUED | `B4VaultEngine.sol:960` |
| V8-L-5 | **B3 reversal not propagated:** SPEC §5 still mandates "owner margin MUST NOT increase strategy notional" and an "owner margin reserve" state category the code abolished; README's "Mini … trades nothing" is now false — a USDC deposit on Mini converts to spot (PoC: 17,784 USDC → 0.1368 BTC). No fund-loss path; product semantics contradict the normative spec. Rewrite §5 categories; correct the Mini narration (or refuse USDC deposits on spot-target-1 policies). | CONFIRMED (PoC + quoted lines) | `spec/SPECIFICATION.md:80-81`, `B4Vault.sol:134`, `README.md:111`, `docs/02-core-concepts.md:63` |
| V8-L-6 | **AB acceptance is looser than claimed:** "every §4 row pinned" = 9 of 12 (PM5/PM6/PM7 unpinned — PM5/PM7 ARE wired and hit the doc numbers exactly, so it's a coverage gap); TOL = 1 % is ~7× the widest owner-rounding (a systematic +0.4 % θ error passes every φ-bearing pin). Pin exact WAD values, add the 3 rows. | CONFIRMED (PoC `V8B_StructuralAudit.t.sol`) | `test/unit/StructuralAB.t.sol:14` |
| V8-L-7 | **Invariant campaign has no structural ghosts:** 9/9 deep runs pass and Pro Max is exercised transitively, but no property pins liquidation == frozen stop, the freeze lifecycle, the freshness gate, or the maxLev clamp. Add a ghost asserting venue-liquidation ≈ frozen stop (±1 lot) on every held structural position. | ARGUED | `test/invariant/Protocol.invariant.t.sol` |
| V8-L-8 | **The 4 skipped tests are now actionable and undisclosed.** All four adjudicated STALE-SCENARIO (none hides a bug — the admitted "dust 17,784" is post-exit spot redeployment, the `TransferFailed()` is an unminted-fixture defect); three re-pinned as PASSING adapted scenarios (`V8D_Adapted.t.sol`), the fourth (residual-perp) is transformed: `perpF == 0` now closes any position, same-sign dust is an on-target hold. Rewrite on the new decompose and disclose until zero-skip. | CONFIRMED (adapted PoCs pass) | `SyncMachine:298`, `FindingsRegression:464`, `V6B_ExitFairness:99`, `V6D_VenueGaps:43` |

## Informational

| # | Note | Site |
|---|---|---|
| V8-I-1 | Margin parking: mid-ramp recorded margin ≫ marginNeed ⇒ realized liquidation sits strictly DEEPER than the stop until full deployment (conservative; converges exactly at full deployment). | `B4VaultEngine.sol:1020-1021` |
| V8-I-2 | `_finalizeExit`'s `perpStopWad = 0` is redundant with re-derive-while-flat (externally unobservable, harmless). | `B4VaultOps.sol:255` |
| V8-I-3 | Sub-$10 PARTIAL reduce-only orders: mock fills; if the live venue enforces the minimum on partial reduces (exact-closes are exempt — verified V6), a dust residual resend-stalls (H3 liveness only). | `B4VaultEngine.sol:764,1050` |
| V8-I-4 | Stale comment: "Shorts and g ≤ 1 legs keep the flat-φ path (interim)" — contradicted two pages later (shorts are structural). | `B4VaultEngine.sol:998-999` |
| V8-I-5 | `shortFlatStop` has no `g < 1` guard (silent sub-1× pricing for a hypothetical future product; de-levering direction). | `StructuralLeverage.sol:185-189` |
| V8-I-6 | `Phi.INV_PHI` truncation pushes both stops slightly toward entry (riskier direction) — magnitude ~2.8e-14 USD at a 100k delta: nil. | `Phi.sol:15` |
| V8-I-7 | Carried: `uint64(q)` silent truncation above ~$1.8e11 limit price (V6-I-4); clamp before cast. | `B4VaultEngine.sol:158` |
| V8-I-8 | Pro Max transitions pass through the `n∈(0,1)` spot regime by design (~2×NAV extra churn per pivot) — invariant intact (verified-zero at settlement points); document the passage in docs/02. | `Calendar.sol:97-123`, state-machine §0 |
| V8-I-9 | AUDIT-V7's A/B/C fork is still printed "(owner decides)" — de-facto A was chosen, and the pure-perp redesign has since removed the limitation the fork was about; V7-2…V7-5 say "open" against superseded code. Record the resolution. | `docs/audits/AUDIT-V7.md:38-50` |
| V8-I-10 | Dead legacy lib functions (`leverageWad/stopWad/shortStopWad/shortLeverageWad`) remain with their known V6-L-4/L-5 defects; test-only consumers; **0 reclaimable deployed bytes** (proven by stripped-copy rebuild); doc claim "removed" is false of the file. | `StructuralLeverage.sol:42-138` |
| V8-I-11 | `slither-stderr.txt` (ignored artifact) is stale; SLITHER.md should note the 3 new intentional `incorrect-equality` FPs (`B4VaultEngine.sol:944,948,1003`). | repo root, `SLITHER.md` |

---

## Verified: the team's fan-out claims reproduce (PoCs `V8A_Liquidation.t.sol`, `V8A_Freeze.t.sol`)

Liquidation == frozen stop on fresh opens (≤0.1 %, safe side) · weighted-average ADD at a mark −40 % from avg entry keeps the pin · REDUCE stays at-or-deeper · maxLev clamp moves liquidation FURTHER than the stop on both sides (long 97.5k < stop 99.4k; short 102.4k > stop 100.4k, leverage exactly 40) · permissionless peak/low sampling + halving flip never re-trades a HELD position (szi and freeze byte-identical) · ADL/forced close re-opens fresh (lossy variant writes principal down first, B2) · multi-crank funding gap with −20 % mid-gap price move opens at the post-gap stop · partial exit flattens to raw zero; kept capital re-derives · spot interlude (perp → spot(n) → zero → short) holds across a 33-day walk with no value leak · `_avgEntryWad` precision immaterial ($1e-6/unit + 1 wei, safe side).

## Refuted this round (headline)

- ADD/REDUCE or the clamp pulling liquidation closer than the stop — refuted both directions with numeric pins.
- Genesis fall refusing shorts — refuted: `shortStructStop(p,0,0) = 1.618p` ⇒ opens at exactly φ.
- `peakTag` off-by-one at the halving boundary — refuted both sides.
- Wick-UP as this-cycle over-leverage — refuted: fail-safe this cycle; harm is next-cycle only (V8-M-2).
- claimFor gate breaking Keeper claims or leaking value — refuted: ordering already latest-only; forfeit is redistribution by design.
- Conservation regression behind the skipped waterfall test — refuted: per-exit bucket decrements == recipient deltas EXACTLY (dust = 0) on all 4 exits; the 17,784 USDC is post-finalization spot redeployment, exact to the sat.
- `wmul` phantom overflow — `Phi.wmul` delegates to 512-bit `mulDiv`; threshold ~1.9e77, unreachable.
- Long/short mirror asymmetry — stops bit-identical under mirrored inputs (fuzz 512 runs).
- B3 blast radius — donations still excluded (recorded buckets only + A11 cap); pool/penalty-bound USDC can never be reclassified (same-tx outflow; reclassify unreachable while an exit pends); deposit→crank→exit exact.
- Invariant Pro Max absence — refuted: Pro Max is deployed in the campaign with a real pool; the structural gate is live on every crank (but see V8-L-7 for the missing property ghosts).
- CI size gate toothless — refuted: padded 24,763 B B4Vault fails the gate (threshold 24,576 confirmed).

## V6 carry-over status

| V6 finding | Status now |
|---|---|
| M-1 anchor under-sampling | **LIVE — V8-M-1** (peak side PoC'd) |
| M-2 deposit routing | **FIXED** (superseded by pure-perp: USDC is strategy capital; shorts self-fund) |
| M-3 residual perp dead zone | **Transformed/closed** (`perpF == 0` closes any position; same-sign dust is on-target hold) |
| M-4 spot sub-minimum emission | **OPEN — V8-M-4** |
| M-5 F2 mirror-only tests | **OPEN** (`AuditV5Fixes.t.sol` still a mirror; no harness-exposed `_quantizePx8` fuzz) |
| M-6 oracle root-of-trust | **Standing release gate** (delegate renouncement + light-client pin) |
| L-1 perp zero-mark | **PARTIAL — V8-L-1** (planner guarded; exit flatten unguarded) |
| L-9 F3/F4 missing regression tests | **OPEN** |

## Campaigns / tooling at the working tree

- Deep invariant: **9/9 PASS** — 512 runs × 256 depth, 131,072 calls each, 0 reverts; `warpPivot` 6,895 calls; transitions crossed post-decompose (deterministic F12 + real-engine sign-change-through-zero in the backtest).
- Slither `--fail-high` (pinned 0.11.4): **exit 0**; 150 results vs 134 baseline — no real new medium/high (3 intentional `incorrect-equality` guards + timestamp-class FPs + naming).
- Sizes (CI gate command replicated): B4Vault 24,287 B (**289 B margin**), B4VaultOps 23,348, B4Pool 8,834 — gate proven to fail at 24,763 B.
- `forge fmt --check`: clean (V8 PoCs formatted).

## V8 PoC inventory (new, untracked, all passing — 33 tests)

| File | Tests | Demonstrates |
|---|---|---|
| `test/unit/V8A_Liquidation.t.sol` | 5 | liquidation == stop; weighted add; reduce safety; clamp direction ×2 |
| `test/unit/V8A_Freeze.t.sol` | 5 | freeze lifecycle: anchor flip, ADL, funding gap, exit, sampling mid-hold |
| `test/unit/V8A_SpotInterlude.t.sol` | 1 | 33-day transition choreography, no leak |
| `test/unit/V8B_StructuralAudit.t.sol` | 8 | exact AB pins (12 rows), loose-TOL demo, mirror fuzz, overflow refutation, truncation direction, guards |
| `test/unit/V8C_SparsePeak.t.sol` | 5 | **V8-M-1** + dense control + genesis + skip ×2 (V8-L-2) |
| `test/unit/V8C_PeakWick.t.sol` | 3 | **V8-M-2** directions F/G/H |
| `test/unit/V8C_ClaimGate.t.sol` | 2 | claimFor gate semantics (V8-L-3) |
| `test/unit/V8D_Adapted.t.sol` | 3 | skipped scenarios re-pinned on the new decompose (V8-L-8) |
| `test/unit/V8D_ExitWaterfallDiag.t.sol` | 1 | bucket-exact waterfall diagnostic (conservation refutation) |

## Recommended fix order

1. **V8-M-1 + V8-M-2** — the anchor sampling-density gate (≥ N samples over ≥ W/2) on BOTH ratchets before this WIP is committed; consider median/sanity-band instead of raw MIN/MAX; promote `prevPeak` at the halving flip.
2. **V8-M-3** — regenerate the benchmark tables, delete the flat-φ disclaimers, pin the multiples as assertions (their own F9 precedent).
3. **V8-M-4** — post-flooring minimum-notional hold in `_startSpotOrder` (carried from V6).
4. **V8-L-1** — mirror the zero-mark guard into `_startPerpOrder` (one line; completes F4 on the exit path).
5. **V8-L-6 + V8-L-7 + V8-L-8** — exact AB pins + the 3 missing rows; structural invariant ghosts; rewrite the 4 skipped scenarios on the new decompose (3 already exist as passing adapted tests).
6. Doc fixes: V8-L-3 (keeper table), V8-L-5 (SPEC §5 + Mini), V8-I-4, V8-I-9, V8-I-11.
7. Decide V8-L-4 (clamp re-trade: document or gate).
