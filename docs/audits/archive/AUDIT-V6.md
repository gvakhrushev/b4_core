# AUDIT-V6 — full-tree security re-audit after the structural-leverage round

**Date:** 2026-07-22 · **Tree:** HEAD `4d418ff` (= `246e442` "fix(audit-v5)" + one pool-economics docs/test commit; no `src/` delta between them)
**Baseline:** `forge build` OK · **246/246 tests, 37 suites** at committed HEAD · B4Vault **24,239 B** (337 B EIP-170 margin)
**With V6 PoCs:** **269/269, 45 suites** — 23 new adversarial tests, all passing against current code
**Naming:** the team's own 2026-07-22 full-tree round self-labeled "audit-v5" (REPORT.md). This report is the next independent round, hence **V6** (continuing the AUDIT-V3 / AUDIT-V4 series).

## Scope and method

Five parallel adversarial scopes, refute-by-default, every finding either PoC-proven on current
code (CONFIRMED) or argued from quoted code and live-venue documentation (ARGUED); every finding
adjudicated by the lead auditor against the cited lines:

- **A — Structural mechanism (new since V4):** `src/libraries/StructuralLeverage.sol`,
  `B4Pool.sampleAnchor`/`anchors` ratchet, `CoreReader` price trust, backtest fidelity,
  `PROPOSAL-pool-tranches.md` consistency.
- **B — Core engine:** `B4VaultEngine` (879 lines), `B4Vault`, `B4VaultOps`, `B4VaultStorage`,
  incl. the V5 fixes (`_quantizePx8`, F3, F4) and the recorded-but-unfixed items from
  `AUDIT-2026-07-structural-leverage.md`.
- **C — Pool / Calendar / Oracle / Factory:** full money path, SNAPSHOT_WINDOW 1h→24h,
  LayerZero root-of-trust, binding checks.
- **D — Venue / Keeper / libs / mocks / CI:** `CoreReader`/`CoreWriterLib` byte-level vs live
  Hyperliquid docs, `DescriptorLib`, `Keeper`, `MockCore` fidelity, CI gates.
- **E — Independent verification of the team's "audit-v5":** fail-before evidence for F1–F4,
  deep invariant campaign reality, slither gate, doc-honesty sweep, repo hygiene.

**What changed since AUDIT-V4:** sources reorganized into `src/{core,venue,libraries,periphery,citrea,interfaces}/`;
new `StructuralLeverage.sol` (pure math, long + symmetric short); on-chain anchor ratchet in
`B4Pool`; `_quantizePx8` price quantization (their F2, High); settlement-decimals binding check
(F3); spot zero-price guard (F4); `SNAPSHOT_WINDOW` widened 1h→24h; Pro is now `{1,−1}` (full 1×
short in fall); the structural-leverage engine wiring was landed, adversarially audited by the
team (C6/C1/C4 criticals), and **reverted** — the engine sizes perps flat-`φ`; the invariant
campaign gained a `warpPivot` handler (their F12). All prior V3/V4 fixes verified **intact** on
the new layout (headroom cap `B4VaultEngine.sol:245`; Keeper self-call wrappers
`Keeper.sol:97,110,117`; `TOKEN_READ_GAS` `B4Pool.sol:372`; activation wedge, settle-basket gate,
`_fromWad64` clamps).

## Verdict

No Critical or High found on the shipped code. The team's V5 fixes are **correct** (one — F1 —
with genuine fail-before evidence; the other three's *claimed* fail-before evidence does not
exist — see V6-M-5/L-9), and the big recorded items from their own audits are mostly refuted
here with passing PoCs (exit-loss dumping, rounding waterfall, F13 pool claim, sweep value loss).
**6 Medium, 9 Low, 7 Informational.** The sharpest live issues: a same-sign residual perp that
the planner can never close below the $10 venue minimum (V6-M-3), spot orders emitted under the
venue minimum after lot flooring (V6-M-4), and the silent deposit-routing degradation carried
over from C7 (V6-M-2). The structural anchor ratchet — dormant data today, load-bearing for the
§7b redo — has a one-directional over-leverage bias under sparse sampling (V6-M-1).

---

## Medium

### V6-M-1 — Anchor ratchet promotes sparsely-sampled windows → one-directional over-leverage (latent; durable on-chain data)
**Status: CONFIRMED (PoC `test/unit/V6A_AnchorAttacks.t.sol`) · `src/core/B4Pool.sol:237-248`, `src/libraries/StructuralLeverage.sol:49-54`**

`sampleAnchor` reseeds `cap` to the **first** observation of a window and ratchets only **down**
within it. The F1 parity fix (`windowTag % 2 == 0`, line 241) guards only the **zero**-sample
case. A 62-window sampled **once** (keeper failure, thin unwatched asset, truncated window) still
promotes at the next halving flip — and a sparse cap is an **upper bound** on the true bottom.
Since `L = g·p/(p − floor)`, a floor biased **up** means systematically **higher** leverage than
structurally justified for the whole next cycle segment. PoC: a 62-window sampled once at its
open (20k vs true bottom 16k) promotes 20k at the flip; `leverageWad` returns strictly higher `L`
than with the honest bottom. One later honest sample heals it (ratchet-down), so the poison
holds only under 20 days of sampling silence — permissionless pools admit thin assets
(`MAX_DIRECTIONAL = 8`, no liquidity floor). Latent today (engine flat-`φ`, nothing on-chain
consumes anchors), but the ratchet writes durable data the §7b redo will trust. SPEC §7b's
disclaimer ("under-sampling is NOT fail-safe") covers the *zero*-sample case; the sparse case is
the same class and is not covered.
**Fix:** promotion eligibility requires ≥ N samples spanning ≥ W/2 of the window (store count +
first/last sample time in `Anchor`); else skip promotion (fail-safe, floor stays low). The redo
must treat fresh reseeds conservatively.

### V6-M-2 — USDC deposits never reach the strategy; dir-only leveraged deposits run silently unlevered (C7 remnant, still live)
**Status: CONFIRMED (PoC `test/unit/V6B_DepositRouting.t.sol`) · `src/core/B4Vault.sol:128-131`, `src/core/B4VaultEngine.sol:152-158`**

`deposit()` routes 100% of USDC into `usdcMarginEvm`; `_strategyValueWad` excludes it and **no
path converts it to strategy capital** (the spot planner buys only from the *rotated* buckets).
Consequences today: a **USDC-only deposit on any product gets zero exposure** (PoC:
`strategyValueWad() == 0`, crank converges immediately, NAV idles as parked reserve); a
**dir-only Pro Max deposit runs unlevered** (`notionalCap = margin·maxLev/φ = 0` ⇒ perp leg
silently absent, vault behaves as 1× spot). No theft — the entry ledger covers the funds and
exit refunds them — but the signed-for product is not delivered and **no event** marks the
degradation. Filed by the team's own structural audit as C7 (Med) against the reverted wiring;
the revert removed the wiring, not the routing.
**Fix:** deploy-or-revert — route USDC deposits through the rotation leg, or reject single-asset
deposits for leveraged descriptors / emit an explicit degradation event.

### V6-M-3 — A same-sign residual perp below the $10 venue minimum is never closed; planner never converges
**Status: CONFIRMED (PoC `test/unit/V6D_VenueGaps.t.sol::test_residual_perp_position_never_closed_below_min_order`) · `src/core/B4VaultEngine.sol:803-817` vs `:715`**

`_planPerpStep` clamps `notionalTargetWad < MIN_ORDER_USD_WAD` to 0, but the zero-target branch
only handles the strictly-flat case (`pos.szi == 0`, margin return). With `szi != 0` and
`0 < v·|perpF| < $10` it falls through `return false`, and `_planSyncStep` step 1 (line 715)
only fires on `perpF == 0` or wrong-sign — so **no close path exists**. PoC: 25 consecutive sync
cranks leave a 7-lot long and $5 margin untouched. Reachable at realistic small-vault states: a
~30% drawdown on a ~$20 strategy value, or partial exits scaling the buckets, wedges the perp
leg **indefinitely** — unintended open exposure through transitions, recorded margin parked
(margin return requires strict flatness, A10), the engine's convergence property violated. Not
fund loss: the owner exit flattens any `szi` (exact-closing reduce-only orders are exempt from
the $10 minimum — verified against venue docs) and recovers the margin. Pre-registered as critic
#4 in `AUDIT-2026-07`; now PoC-confirmed live on the flat-`φ` engine. (Merges scope-B's V6-B-4.)
**Fix:** in the zero-target branch, when `pos.szi != 0` emit a full `|szi|` reduce-only close
(mirror `_planSyncStep` step-1 semantics for clamped-to-zero targets regardless of sign).

### V6-M-4 — Spot orders emitted below the $10 venue minimum after lot flooring → rejection wedge (H3); MockCore hides the class
**Status: CONFIRMED emission (PoC `test/unit/V6D_VenueGaps.t.sol::test_spot_order_emitted_below_venue_minimum`) + live rejection ARGUED from venue docs · `src/core/B4VaultEngine.sol:277-292` (call sites `:753`, `:768`)**

The trade band guarantees the USD **diff** exceeds $10 (`:742`), not the **emitted** order. The
sell path floors to whole lots (`sz = inputWei / _dirWeiPerLot()`, line 289) and only rejects
`sz == 0` (line 292). When one lot's value exceeds `diff − $10`, the floored order is below the
venue minimum (PoC: szDecimals-0 token @ $6, diff $10.50 → 1-lot **$6** order emitted). The live
venue rejects sub-$10 orders ("Order must have minimum value of 10 USDC"; the exact-close
reduce-only exemption is perp-only — spot has no reduce-only), so the IOC no-fills, the intent
clears after `RESEND_TIMEOUT`, and the planner re-emits the identical order — an H3 wedge until
price/value drifts (2-lot reach or back into band). The same emission site serves the exit
flatten (argued extension: a dust-sized full exit can wedge identically). `MockCore` has no
min-notional rule and fills the order, hiding the class from the whole suite.
**Fix:** after lot flooring, hold unless `sz·px ≥ MIN_ORDER_USD_WAD` (return false like `sz==0`),
or widen the band by one lot value; add a strict-mode MockCore knob (V6-L-8).

### V6-M-5 — The team's High-rated F2 fix is tested only against an in-test mirror; its "fail-before" claim is false
**Status: CONFIRMED (test-integrity; worktree verification) · `test/unit/AuditV5Fixes.t.sol:15-36`**

The F2 regression suite exercises `_quantize`, a **uint256-returning mirror defined inside the
test file** — never the engine's `_quantizePx8`. Reverse-applying the `src/` hunks of `246e442`
while keeping the tests: **all 4 F2 tests still pass** on pre-fix code (the only failing test in
the whole suite is F1's — genuine). The test file's own comment ("Real-engine coverage lands in
the venue integration tests") is not backed by any test. The mirror structurally **cannot** catch
engine-side regressions: V6-I-4's `uint64(q)` truncation lives exactly in the part the mirror
doesn't reproduce. The fix itself is verified **correct** — the venue rule was checked against
the official Hyperliquid tick-and-lot documentation this round (integer exemption confirmed,
decimal caps confirmed, `≤5` sig figs confirmed) and completeness probes pass on realistic
inputs. This is a test-integrity finding, not a code-defect finding: a High-rated fix whose
regression evidence is self-referential.
**Fix:** expose `_quantizePx8` via `EngineHarness` (the V3 pattern) and port the validity fuzz to
the real function; add a fail-before witness pinning an invalid raw price through the engine.

### V6-M-6 — Halving root-of-trust rests entirely on the Citrea light client + LZ DVN config + delegate renouncement (config-gated)
**Status: ARGUED (code-level forgery REFUTED via PoC `test/unit/V6C_OracleOrdering.t.sol`) · `src/core/HalvingOracle.sol:86-110`, `src/citrea/HalvingProver.sol:57-76`**

On-chain `_accept` is sound within its boundary: immutable (endpoint, srcEid, srcSender) path,
height strictly `+210000`, timestamps strictly increasing and `≤ now`, hash/ts re-derived from
header bytes, idempotent redelivery, conflicting same-height reverts (PoC), out-of-order delivery
reverts then self-heals (PoC). But the oracle does **not** bind header↔height — no PoW check;
that binding is wholly `HalvingProver`'s off-chain `lightClient.getBlockHash(height) ==
dSHA256(header)`. So fact integrity = the Citrea light client + the LayerZero DVN set, and a
**delegate** (until `renounceDelegate()`) can reconfigure DVNs. A compromised light client or an
unrenounced delegate admits a fake fact → calendar rewinds, `POST_FACT_FREE_EXIT` opens a 20-day
penalty-free exit window (11.8% dodge), anchor windows re-seed. This matches the documented
SECURITY_MODEL §5.12-13 boundary — flagged as a **release gate**, not a code defect: delegate
renouncement and light-client adapter pinning must be verified before any funded deployment.

---

## Low

| # | Finding | Status | Site |
|---|---|---|---|
| V6-L-1 | **`_startPerpOrder` lacks the F4 zero-price guard.** On a halted perp mark it emits an IOC with `limitPx == 0` (`markWad=0 → limitWad=0 → _quantizePx8→0`); venue rejects → resend-forever on the wrong-sign reduce (`:716`), exit flatten, and harvest paths — the exact H3 class F4 fixed for spot. Live reachability thin (a bound market never marks 0; delisting reverts the precompile). MockCore compounds it by "filling" at px 0. (Merges scope findings B-1/D-3/E-4.) | CONFIRMED (PoC `V6B_PerpZeroMark.t.sol`, `V6D_VenueGaps.t.sol`) | `B4VaultEngine.sol:360-384` vs `:279` |
| V6-L-2 | **24h lock-window discretion — undocumented pool-share direction.** First-call-wins bounds the window to "honest infra misses pointTime"; then an adversary may lock above own entry but below competitors' → their interval weight contribution is 0 → capturable share of the fixed penalty bucket up to ~100% in a pool's first intervals (decays as `rewardBaseWad` accumulates). Fee direction quantified: ΔoperatorCut ≈ 1.35%·q·Δpx, Δweight ≈ 3.15%·q·Δpx. The Calendar.sol mitigation ("the harmed party can simply call at pointTime") is a race, not a guarantee; anyone can close the window. Doc-note fix; optional keeper-always-locks-at-pointTime policy. | ARGUED | `B4Pool.sol:184-199`, `Calendar.sol:43-65` |
| V6-L-3 | **"Ratcheted up only" is false.** A deeper next-cycle 62-window bottom flips `floor` down (PoC: 16000→9000). Fail-safe direction (lower floor ⇒ lower leverage), no exploit — but the §7b redo must not assume floor monotonicity; SPEC/PROPOSAL text needs correcting. | CONFIRMED (PoC `V6A_AnchorAttacks.t.sol`) | `B4Pool.sol:241-243` |
| V6-L-4 | **Asymmetric base-leverage guard.** `leverageWad(p, g<1, …)` returns WAD (amplifies a sub-1× product to 1×) where `shortStopWad` refuses (`g <= WAD → 0`). Only g=φ callers exist today; the redo must guard or the lib should add the symmetric check. | CONFIRMED (PoC `V6A_LibEdges.t.sol`) | `StructuralLeverage.sol:47` vs `:113` |
| V6-L-5 | **`stopWad`/`leverageWad` edge divergence.** At a 1-wei delta, `drop` rounds to 0: `stopWad` returns `stop == p` (liquidation AT entry) while `leverageWad` returns WAD via a `stop >= p` branch `stopWad` lacks. The duplicated long-side logic the docs say "cannot drift" already diverges at the edge. Single-source it, as the short side does. | CONFIRMED (PoC `V6A_LibEdges.t.sol`) | `StructuralLeverage.sol:61-71` vs `:42-56` |
| V6-L-6 | **No leverage clamp in the lib + a 1-wei cliff.** `L(floor+2 wei) ≈ 1e5×`; short window regime mirrors it (>1e4× near `prevPeak`). "Venue maxLeverage is the hard ceiling" is enforceable only by the redo — yet the AUDIT-2026-07 redo-requirements list omits the clamp, and sub-1× shorts imply `margin = notional/L > notional`, which the redo must handle explicitly. | CONFIRMED (PoC `V6A_LibEdges.t.sol`) | `StructuralLeverage.sol:54,137` |
| V6-L-7 | **Backtest anchors unreproducible at decision time (C10-class residual).** `capG`/`capR` are full-window mins used at window-open entries; the on-chain ratchet then holds a reseeded/stale cap. Direction is conservative (demo L ≤ realizable) and `docs/11-backtest.md:164` discloses it accurately — no flattered results — but the redo must not benchmark against these anchors. F14/F15 assertions verified real; no short-side look-ahead found; no-HWM fee modeled faithfully. | ARGUED | `Backtest.t.sol:341-342,370-372,443-445` |
| V6-L-8 | **MockCore fidelity gaps — the class that hid V6-M-3/M-4/L-1.** Not replicated: $10 minimum + exact-close exemption; 5-sig-fig/decimal price rejection; px==0 rejection; perp margin sufficiency/liquidation; USD-class-transfer dust floor; unknown-asset precompile error-consume-all-gas (mock returns 0); no taker-fee drag. Fix: strict-mode mock knob enforcing the first four, run the full suite against it. | ARGUED | `test/mocks/MockCore.sol:342-489,534-542` |
| V6-L-9 | **F3/F4 shipped with zero regression tests; commit message misattributes fail-before evidence.** No test anywhere asserts `BadSettlement` on a weiDec-5 settlement (F3) or exercises a halted spot feed on the engine path (F4); both claimed "fail-before/pass-after in AuditV5Fixes.t.sol + AnchorRatchet.t.sol". Independent probes (written this round, worktree-only) confirm the fixes themselves are correct and complete — F3 covers both binding paths, F4 covers the only spot-order choke point. | CONFIRMED (worktree verification) | `DescriptorLib.sol:67`, `B4VaultEngine.sol:279` |

## Informational

| # | Note | Site |
|---|---|---|
| V6-I-1 | **Late LZ acceptance (> W) skips the flip — fail-safe LOW, refuting AUDIT-2026-07 critic #3's "⇒ more leverage" (direction-flipped).** New detail: the next on-time flip promotes the *newer* confirmed bottom, permanently skipping the older one (PoC); self-healing, document the semantics. | `B4Pool.sol:220-225`, `HalvingOracle.sol:98-107` |
| V6-I-2 | **Flip liveness:** if the next epoch's post-halving window is *also* missed, an already-confirmed 62-window bottom is dropped without promotion (conservative; floor lags a full cycle). Option: allow kind-1 opens to promote an even-tag cap. | `B4Pool.sol:239` |
| V6-I-3 | **Normative contradiction:** both proposals claim "spec §7b (both sides) done", but shipped SPECIFICATION §7b still says shorts use the flat base `g`; SPS-1 assumes "same anchors as every product short" while **no on-chain peak ratchet exists** (`sampleAnchor` records lows only; `prevPeak`/`peakC` are backtest-only). Also stale: `StructuralLeverage.sol:34-35` + `Backtest.t.sol:13-15` claim "engine and demo call the SAME function" — the engine consumes nothing (flat-`φ`); docs/11:173-174 is the honest text. | `SPECIFICATION.md:170-171`, proposals, `B4VaultEngine.sol:821,848` |
| V6-I-4 | **`uint64(q)` truncates silently** (Solidity narrowing doesn't revert) for limit prices above ~$1.84e11/unit — venue-representable, economically absurd. Clamp to `type(uint64).max` before the cast (never revert — H3). The F2 mirror-fuzz covers this region but, returning uint256, cannot observe it (see V6-M-5). | `B4VaultEngine.sol:112` |
| V6-I-5 | **Keeper:** `pool.intervalCount()` is the only pool call outside try/catch — a reverting pool fails the whole crank (caller-chosen pool ⇒ self-grief only; one-line wrap closes it). V4-VENUE-1 self-call wrappers verified intact; no new unguarded external-call surface. | `Keeper.sol:33` |
| V6-I-6 | **DescriptorLib residual (documented boundary, restated):** the token↔perp association has no on-chain statement — a malicious factory can bind real-token-A spot ↔ real-token-B perp; all venue checks pass. All decimal bounds verified clean: `spotSzDecimals ≤ 8` / `perpSzDecimals ≤ 6` guard every `10**(…)` exponent; spread math underflow-safe, ≤ 30. | `DescriptorLib.sol`, SECURITY_MODEL §3 |
| V6-I-7 | **Minor engine notes:** (a) `pxWad ∈ (0, 1e10)` yields a zero-price spot order despite F4 (sub-$1e-8 assets — `_quantizePx8` returns 0, caller proceeds); (b) the buy-side lots cast `uint64(Phi.mulDiv(...))` truncates rather than clamps at ~$18M+ single spends on micro-priced assets (inconsistent with the `_fromWad64` discipline); (c) SLITHER.md count stale: 134 results vs stated 131 — exactly +2 Medium, both inside the F2 fix and both in already-triaged intentional-FP classes (`divide-before-multiply` floor-to-grid; zero-init `digits` counter). | `B4VaultEngine.sol:287,304`, `SLITHER.md` |

---

## Refuted this round (headline items, with evidence)

- **Exit-loss dumping (AUDIT-2026-07 critic #2)** — REFUTED by construction + PoC
  (`V6B_ExitFairness.t.sol`): the exit machine always flattens the live position first, realizing
  PnL on the venue; `_reconcile` writes `perpMargin6` to actual withdrawable before
  `_finalizeExit` values NAV. Quantified: φ-long, −30% crash (hidden loss = 7.4× margin), 50%
  exit → exiter takes exactly 50% of post-loss NAV to the dollar, stayer remainder identical.
  Settle-side: recorded profit > 0 requires recorded legs up since anchor ⇒ the
  spot-marked/perp-at-cost asymmetry only ever *understates* the fee base.
- **Settle/exit phi-rounding waterfall** — REFUTED by PoC: `entryLedgerWad = nav − paidVal` and
  the SPEC §9 exit formulas hold **exactly** at every step; residual dust ≤ 10 units over 4
  exits, stays in vault buckets; weight reported once; penalty exit's pool capture succeeds.
- **F13 — "a pool claim is never paid to a real vault"** — was a coverage gap, not a bug. New
  integration PoC (`test/integration/V6C_PoolClaimPays.t.sol`): deposit → +20% → settle → a
  second vault's penalized exit funds the pool → `claimFor` pays the fixed **owner** the exact
  pro-rata nominal; vault balance untouched; `remaining`/`liability` conserve to ≤ 1 wei dust.
- **Keeper sweep-before-claim value loss** — REFUTED by PoC: swept value re-buckets into the next
  interval and pays out there; liability byte-identical (D4 holds; beneficiaries change — by
  design).
- **Wick-down anchor poisoning ⇒ higher leverage** — REFUTED: the direction is backwards; a lower
  cap/floor only *lowers* `L` in both capped and uncapped regimes (fail-safe griefing at worst).
  The live bias is the sparse-sampling **up** direction (V6-M-1).
- **CoreReader price normalization "asserted only by comment" (V5-recorded)** — REFUTED for
  validated descriptors: the `10^(8−szDec)` / `10^(6−szDec)` normalization matches the official
  Hyperliquid docs **verbatim**; underflow impossible for bound descriptors. CoreWriter encoding
  byte-exact vs docs; L1Read ABI/addresses full match; `withdrawable` 1-field-struct ≡ bare
  uint64 decode safe; staleness ≤ 1 block per docs guarantee.
- **"Integer prices exempt" suspicion** — REFUTED: the official tick-and-lot doc confirms integer
  prices are allowed regardless of significant figures (BTC $123,456 valid). `_quantizePx8`'s
  exemption and conservative digit grid are correct.
- **`_pxWadToPerpRaw` underflow** — unreachable: `DescriptorLib` rejects `perpSzDecimals > 6` at
  binding; spot-only descriptors must zero it.
- **SNAPSHOT_WINDOW 24h settle-skew** — the extension only *strengthens* the engine's sole timing
  assumption (in-flight ≈ 1h ≪ report window); no lock-proximity assumption anywhere.
- **Pool money path** — conservation `liability = accruing + Σ unswept remaining` holds
  inductively across advance/claim/sweep/capture; malicious-ERC20 isolation (revert / return-bomb
  / gas-burn) defers only the offending token (D5); `totalWeight == 0` intervals roll forward
  loss-free; interval-id monotonicity and late-materialization self-healing confirmed.

## Verification of the team's "audit-v5" round (commit `246e442`)

| Fix | Their claim | Independent result |
|---|---|---|
| F1 (M) anchor flip parity | fail-before in `AnchorRatchet.t.sol` | **GENUINE** — reverse-applied src fails the named test with the exact defect |
| F2 (H) `_quantizePx8` | fail-before in `AuditV5Fixes.t.sol` | **Claim false** — tests exercise an in-test mirror; all pass on pre-fix code (V6-M-5). Fix itself verified correct against live venue docs |
| F3 (M) settlement decimals | fail-before claimed | **No test existed** (V6-L-9). Fix verified correct + complete (both binding paths) by independent probe |
| F4 (L) spot zero guard | fail-before claimed | **No test existed** (V6-L-9). Fix verified correct; incomplete one step over — perp side unguarded (V6-L-1) |
| F12 invariant campaign | deep campaign 9/9, transitions crossed | **CONFIRMED real** — `FOUNDRY_PROFILE=deep`, 512 runs × 256 depth, 131,072 calls per invariant, 0 reverts, 9/9 pass; `warpPivot` fired 6,843×; fall regime exercised; deterministic reachability test passes |
| Slither gate | `--fail-high` exit 0 | **Confirmed** (pinned 0.11.4); 134 results, +2 Medium both intentional-FP classes inside the F2 code; SLITHER.md count stale (V6-I-7c) |
| Doc honesty (F9-F11) | structural stop marked DESIGNED not shipped | **Verified** — README per-row status column, WHITEPAPER §, docs/01, docs/11 all accurate; no overclaims found; benchmark numbers match the asserted backtest |

## Campaign / tooling state at HEAD `4d418ff`

- `forge test`: **246/246, 37 suites** (committed) · **269/269, 45 suites** with V6 PoCs.
- Deep invariant campaign: 9/9 at 512×256 (131,072 calls each, 0 reverts) — transitions genuinely crossed.
- Slither `--fail-high`: exit 0. CI: fmt+build+test on push/PR, nightly deep invariant, slither gate — matches SLITHER.md/REPORT.md (actions pinned by tag, not SHA — self-acknowledged residual).
- Sizes: B4Vault 24,239 B (337 B margin) — the binding constraint for any fix that adds engine code.

## V6 PoC inventory (new, untracked, all passing)

| File | Tests | Demonstrates |
|---|---|---|
| `test/unit/V6A_AnchorAttacks.t.sol` | 5 | V6-M-1 (×2), wick-down refutation, V6-L-3, V6-I-1 |
| `test/unit/V6A_LibEdges.t.sol` | 6 | V6-L-4, V6-L-5, V6-L-6 (×2), overflow refutation, WAD-floor pin |
| `test/unit/V6B_DepositRouting.t.sol` | 2 | V6-M-2 (both branches) |
| `test/unit/V6B_ExitFairness.t.sol` | 2 | exit-dumping refutation (quantified), waterfall refutation |
| `test/unit/V6B_PerpZeroMark.t.sol` | 1 | V6-L-1 |
| `test/unit/V6C_OracleOrdering.t.sol` | 2 | V6-M-6 boundary (out-of-order heal, conflicting-fact reject) |
| `test/integration/V6C_PoolClaimPays.t.sol` | 2 | F13 closure, sweep roll-forward |
| `test/unit/V6D_VenueGaps.t.sol` | 3 | V6-M-3, V6-M-4, V6-L-1 (mock-compounded variant) |

## Recommended fix order

1. **V6-M-3** — close-on-zero-target in `_planPerpStep` (few lines; frees parked margin; restores convergence).
2. **V6-M-4** — post-flooring minimum-notional hold in `_startSpotOrder` (few lines; kills a live H3 wedge class).
3. **V6-L-1** — `if (markWad == 0) return;` in `_startPerpOrder` (one line; completes F4 symmetrically).
4. **V6-M-5 + V6-L-9** — harness-exposed `_quantizePx8` validity fuzz + the three missing regression tests (F3/F4/perp-guard).
5. **V6-M-2** — deposit routing: deploy-or-revert + explicit degradation events (needs a product decision on USDC deposits).
6. **V6-M-1** — ratchet sampling-density gate (≥ N samples over ≥ W/2) **before** the §7b redo consumes anchors; fold in V6-L-4/L-5/L-6 (lib guard, single-source, venue-maxLeverage clamp + sub-1× margin handling) and the V6-I-3 spec/proposal reconciliation as redo requirements.
7. **V6-L-8** — strict-mode MockCore knob; re-run the suite against it (would have caught M-3/M-4/L-1).
8. Doc fixes: V6-L-2 (share direction), V6-L-3 ("ratcheted up only"), V6-I-1/I-2 (skip semantics), SLITHER.md count.
9. Release-gate checklist: V6-M-6 (delegate renouncement + light-client adapter pin).
