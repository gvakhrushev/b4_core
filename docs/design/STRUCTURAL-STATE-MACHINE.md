# Structural sizing — the complete state machine (normative)

Exhaustive enumeration of every `(product, calendar state, price-vs-anchor)` → position kind +
sizing rule. Derived from the owner's worked examples (2026-07), which are the **AB-test
acceptance criteria** (§4) — real BTC data in `data/btcusd_daily.csv`, no mocks. Rule: *don't
invent — enumerate every state as a machine.* Code, documentation and tests MUST all match this.

> §4 (the worked numbers) is authoritative — it is the owner's own arithmetic. §2–§3 (the
> formulas) are the derivation from those examples and are validated *against* §4 during
> implementation; where a formula and a worked number disagree, the number wins and the formula
> is tuned.

---

## 0. Capital is in exactly ONE place — never mixed

At any instant the vault holds exactly one of:

| State | Holding | Leverage | Liquidation |
|---|---|---|---|
| **SPOT** | BTC (fraction `n∈[0,1]`) + USDC `(1−n)` | 1× | none |
| **PERP-LONG** | the WHOLE capital is USDC margin backing a long | `L×` | at the confirmed low |
| **PERP-SHORT** | the WHOLE capital is USDC margin backing a short | `L×` | at the confirmed peak |

There is **never** spot-BTC held *alongside* perp margin: that doubles the directional exposure
and pays funding on borrowed notional while half the book sits like Mini — against the product's
own thesis. `|n| > 1` ⇒ perp; `0 ≤ n ≤ 1` ⇒ spot. When a leg closes, its USDC finances the next
leg (a spot buy, or the opposite perp). This is the pure-perp model: a leveraged product is a
USDC-margined perp, full stop.

---

## 1. Calendar, windows, anchors

Three transitions (pivots), each a **20-day window = 10 days closing the old leg + 10 days
DCA-opening the new leg**:

| Pivot | Transition | Window | Confirms |
|---|---|---|---|
| **P** (38.2% = cycle/φ²) | long → short | peak-window `[P−W, P]` | `C` = **max** daily-open over the 20 days |
| **T** (61.8% = cycle/φ) | short → long | 62-window `[T, T+W]` | `B` = **min** daily-open over the 20 days |
| **halving** (`t=0`) | within growth | post-halving `[0, W]` | post-halving low; **Pro Max ADDS long volume here** |

`W = 20d`, `H = 10d`. Windows sample the **daily-open price once per day** (not intraday OHLC —
"no principal difference"); `C`/`B` are the max/min of those daily samples. This is exactly what
`B4Pool.sampleAnchor` reads (spot px, once per call).

**Anchors** (all in the same price unit):
- Long: `Pb` = previous cycle's confirmed bottom (delta anchor); `B` = this cycle's 62-min.
- Short: `Pp` = previous cycle's confirmed peak (delta anchor); `C` = this cycle's peak-max.

**One risk budget = one fixed stop.** The stop is always `extreme ∓ 0.618·(extreme − prevExtreme)`
— 61.8% of the delta beyond the confirmed extreme (`+` for a short's peak, `−` for a long's low).
Two regimes:
- **Window** (extreme not yet confirmed): each DCA slice uses ITS OWN price as the extreme
  estimate → `stop = p ∓ (p − prevExtreme)/φ` (per-slice).
- **Post-pivot** (extreme confirmed): the delta is FIXED, so the stop is FIXED — the SAME for every
  entry (`maxStop`/`MinStop`); only the **leverage** `L = p / |stop − p|` varies with the entry.
  A shallow entry (near the extreme) → high `L`; a deep entry → low `L`, deliberately `sub-1×`.

`φ` is the base/anchor, not the realized leverage. **Long and short are exact mirrors**
(min↔max, −↔+, floor↔peak). *(An earlier draft interpolated the post-pivot stop with the entry
price — wrong: the confirmed-extreme stop does not move with the entry.)*

---

## 2. Pro — base `g = 1`

**Long leg = SPOT.** Growth `n=1` ⇒ hold BTC. At `T`: DCA-buy BTC over `[T+H, T+W]`. No perp, no
structural math (spot cannot be liquidated).

**Short leg = flat 1× pinned to C** (ONE anchor, `C`):
- **S-win** `[P−H, P]` (C unknown, DCA): each daily slice at price `p` → `stop = 2p` (a 1× short
  liquidates at 2× entry). Size = 1× the slice's capital.
- **S-post** `[P, T]` (C known): `stop = max(2p, C)`. Shallow (`2p > C`) → 1×. Deep (`2p < C`) →
  **pinned to C**, sub-1× (small volume, far stop survives the bounce to the printed peak).
  Crossover at `p = C/2`.

---

## 3. Pro Max — base `g = φ`, `θ = g−1 = 1/φ`

**Short leg = 2-anchor structural** (`Pp`, `C`):
- **S-win** `[P−H, P]` (C unknown, DCA): `stop = p + (p − Pp)/φ` (per-slice).
  `L = φ·p/(p − Pp)`. *[p=4000, Pp=1000 → stop 5854, L 2.16×]*
- **S-post** `[P, T]` (C known): `maxStop = C + (C − Pp)/φ` — **FIXED** for every entry;
  `L = p/(maxStop − p)`. *[C=4000, Pp=1000 → maxStop 5854; entry 5000 → L 5.85×; entry 2000 → L 0.52×]*

**Long leg = structural + halving-add + growth-ratchet** (`Pb`, `B`):
- **L-win** `[T+H, T+W]` (B unknown, DCA): `stop = p − (p − Pb)/φ` (per-slice). `L = φ·p/(p − Pb)`.
  *[p=1000, Pb=100 → stop 444, L 1.80× > φ]*
- **L-post** `[T+W, halving]` (B known): `MinStop = B − (B − Pb)/φ` — **FIXED** for every entry;
  `L = p/(p − MinStop)`. *[B=850, Pb=100 → MinStop 387; entry 800 → L 1.94×; entry 2000 → L 1.24×]*
- **L-halving** `[0, W]` — **ADD VOLUME** over the 20-day free window (per-day DCA): each day's
  slice `stop_day = p_day − (p_day − B)/φ` (anchor `B` = the 62-min; `p_day` = that day's price,
  so the stop and the combined liquidation *float* as the price drifts — NOT a fixed target).
  Deploys accumulated profit → the long's leverage rises. *[day-1 p=3000, B=850 → slice stop 1671]*
- **L-rise** `[W, P−W]` (flat φ with a ratchet): `stop = max(p/φ², ratchetFloor)`, where
  `ratchetFloor` = the L-halving combined stop. **No pin to the post-halving low** — in the 0→38
  growth leg a −61.8% pullback has never printed (supply-shock uptrend). *[p=4000 → max(1528,1664)=1664;
  p=7000 → 2674]*

**Difference Pro ↔ Pro Max (short):** (1) the **max stop** — Pro's is `2p` (flat, far); Pro Max's is
`maxStop` (Pp-boosted, closer ⇒ higher leverage); (2) the **speed of approaching the C-pin** — Pro
Max compresses toward C faster (`θ = 1/φ`). Same reflected logic on the long side, plus Pro Max's
halving volume-add which Pro (spot long) has no analogue for.

---

## 4. AB-test matrix (acceptance criteria)

Each row is a concrete `(product, state, price, anchors) → expected stop & leverage`. Implementation
is "done" for a row when the engine/library reproduces the number. Ran on `data/btcusd_daily.csv`.

| # | Product | State | `p` | anchors | expected stop | expected L | note |
|---|---|---|---:|---|---:|---:|---|
| P1 | Pro short | S-win | 4000 | C=? | 8000 | 1× | flat 2p |
| P2 | Pro short | S-post | 5000 | C=4200 | 10000 | 1× | 2p > C |
| P3 | Pro short | S-post | 2000 | C=4200 | 4200 | 0.91× | pinned to C |
| PM1 | Pro Max short | S-win | 4000 | Pp=1000 | 5854 | 2.16× | p+(p−Pp)/φ |
| PM2 | Pro Max long | L-win | 1000 | Pb=100 | 444 | 1.80× | p−(p−Pb)/φ |
| PM3 | Pro Max long | L-post | 800 | B=850,Pb=100 | 387 | 1.94× | fixed MinStop |
| PM4 | Pro Max long | L-post | 2000 | B=850,Pb=100 | 387 | 1.24× | SAME fixed MinStop, lower L |
| PMs1 | Pro Max short | S-post | 5000 | C=4000,Pp=1000 | 5854 | 5.85× | fixed maxStop |
| PMs2 | Pro Max short | S-post | 2000 | C=4000,Pp=1000 | 5854 | 0.52× | SAME fixed maxStop, sub-1× |
| PM5 | Pro Max long | L-halving d1 | 3000 | B=850 | 1671 | — | per-day add |
| PM6 | Pro Max long | L-rise | 4000 | floor=1664 | 1664 | — | ratchet floor |
| PM7 | Pro Max long | L-rise | 7000 | — | 2674 | — | flat φ (p/φ²) |

*(φ = 1.618033988749894848; small rounding vs the owner's numbers is expected — the number is the
target, the formula is tuned to hit it.)*

---

## 6. Engine mapping — how the crank realizes the machine (margin-control, no frozen L)

The engine is crank-based, async, delta-measured. It realizes §2–§4 by **margin control**, with
**no engine-side frozen `(entryPx, L)`**: the venue's own `(szi, entryNtl)` IS the accumulated,
frozen position. Each crank the engine only ADDS a slice (on a calendar ramp-up or the halving-add)
or REDUCES (on a ramp-down), sizing the slice's margin so its own liquidation lands on the current
structural stop; the venue accumulates the DCA and the combined liquidation is the weighted average.

Liquidation (isolated, ignoring maintenance): long `p_liq = (entryNtl − margin)/szi`;
short `p_liq = (entryNtl + margin)/szi`. A slice at price `p` with target stop `s` deploys
`szi_inc = Δm/|p − s|` for margin `Δm` (so that slice liquidates exactly at `s`).

Per-crank (leveraged leg; a Pro long is spot and never reaches here):
1. `perpF = decompose(target).perp`; `stop` = §2/§3 for the current state (window: use the current
   price `p`; post-pivot: the confirmed extreme, fixed).
2. `marginTarget = capital · |perpF|/g` — ramps `0→capital` over the opening window. A day-15
   entrant starts at the current 50% target; by day 20 the full target is deployed.
3. `perpMargin < marginTarget` → **ADD** a slice (`Δm = marginTarget − perpMargin`, `szi_inc = Δm/|p−s|`).
4. `perpMargin > marginTarget` → **REDUCE**-only proportionally; the freed margin returns to strategy
   (rotation) and finances the next leg.
5. `perpF` crosses 0 → reduce to raw `szi == 0` first (invariant 9), then the opposite leg re-derives.

**Why this removes the whole freeze-bug class (audit + fan-out).** The single frozen `perpStopWad`
is **re-derived at the live price on every idle crank WHILE FLAT** (`szi == 0`) and held UNCHANGED
only while the position is live. Freezing only across the live span is what stops a price move OR a
halving anchor flip re-trading a HELD position (C1/C4); re-deriving while flat is what guarantees a
full exit, a no-loss venue close (ADL/forced-deleverage), or a multi-crank async funding gap always
opens against a FRESH stop — no stale value survives a flatten (kills the exit/close over-lever the
2026-07-23 margin-control fan-out reproduced). Each **ADD** is sized at the live **mark** (`Δm/|mark −
s|`), not the frozen avg entry, so a mid-hold deposit or a ramp add can never drag the combined
liquidation off the stop; a **reduce/hold** sizes at the (unchanged) avg entry. Every structural size
is finally **capped at the venue max leverage** (§7b): near an anchor the raw `L → ∞`, so the clamp
de-levers (liquidation FURTHER than the stop — the safe direction), never emitting a venue-impossible
order. The `p ≤ stop` refusal (C5) is re-checked at the ADD site, so a price drop mid-open stops adding.

**Anchor confirmation (both sides gate the confirmed extreme by zone + freshness).** The SHORT feeds
the confirmed peak `C` to `shortStructStop` ONLY post-pivot (Fall) AND only when `peakTag == epoch+1`
(this cycle's peak); everywhere else `C = 0`, so the S-win (OpeningFall, peak still forming) uses the
live price `p` and a SKIPPED/stale peak window never anchors the short to a systematically-too-low
prior peak (over-lever — the anti-conservative direction). The LONG mirrors this: L-post
(TerminalGrowth, cycle low `B = cap` confirmed) uses the FIXED `MinStop = B − (B − Pb)/φ`; L-win uses
the live `p`. `B4Pool.peaks()` exposes `peakTag` for the freshness check.

## 5. Implementation status

**Shipped and tested:**
- **`StructuralLeverage.sol`** — the corrected primitives, both sides: `longStop`/`longLev`
  (Pb, B), `shortStructStop`/`shortStructLev` (Pp, C, Pro Max), `shortFlatStop`/`shortFlatLev`
  (Pro, pinned to C). Every §4 row pinned in `StructuralAB.t.sol` (10/10). The old window-only
  long and interpolating short are removed.
- **`B4Pool`** — the mirror **peak ratchet** (`sampleAnchor` over `[P−W, P]`, `peaks()` getter
  now exposing `peakTag` for the short's freshness gate), `AnchorRatchet.t.sol`.
- **`B4VaultEngine._planPerpStep`** — **margin control, no frozen L** (§6): the venue's own entry
  is the frozen reference; the engine adds/reduces on a calendar ramp, so a held position is never
  re-traded (a price move or a permissionless anchor flip can't re-lever it — C1/C4). The single
  frozen `perpStopWad` (with its side) is **re-derived every idle crank while FLAT** and held only
  while live, so a full exit, a no-loss venue close, or an async funding gap re-opens FRESH. Adds
  size at the live mark; every size is capped at the venue max leverage. Both post-pivot fixed stops
  (long L-post `MinStop`, short S-post `maxStop`) are zone-gated, and the short's confirmed peak is
  freshness-gated. Long AND short structural (Pro flat / Pro Max 2-anchor), whole deposit deployed,
  liquidation at the structural stop — `StructuralSizing.t.sol`. Current suite status belongs
  in CI/audit evidence, not this design document.

**Post-implementation adversarial audit (2026-07-23) — findings fixed:** the margin-control rewrite
was fanned out (9 lenses → 3-vote refute-by-default verify → completeness critic). Confirmed and
fixed: the freeze lifecycle (re-derive while flat, closing the exit-reopen over-lever + the no-loss
ADL stale stop + the async-funding staleness); the short anchoring the unconfirmed running / stale
prior-cycle peak (now zone + freshness gated, mirror-safe flat-φ fallback); the long's dead L-post
fixed `MinStop` (now wired); the missing venue-max-leverage clamp (added); and the critic's
deposit-mid-hold liquidation drift (adds now size at the live mark). Each has a regression test in
`StructuralSizing.t.sol`.

**Remaining refinements (documented interim, not yet shipped):**
- **`L-rise` ratchet floor** — the growth rise uses `p/φ²` (flat φ) without the `max(·, halvingStop)`
  ratchet floor.
- **Per-slice DCA** — within an opening window the engine pins the combined position to the single
  frozen (first-slice) stop rather than the per-slice average; the two differ only by the intra-window
  price drift (a genuine cross-cycle deposit add is exact — sized at the mark; only same-window DCA
  slices carry this residual).
- **Docs** — SPEC §5/§7b, WHITEPAPER §3, docs/02 reconciled to this machine (2026-07-23).
