# Audit record — structural-leverage engine wiring (2026-07-21)

Post-implementation adversarial audit of the structural-leverage wiring that had been added to
`B4VaultEngine._planPerpStep`. Method: 9 independent finder lenses over the changed surface →
per-finding adversarial verification by 3 lenses each (reproduce-or-refute / spec-consistency /
realistic-impact), kept only if ≥ 2 of 3 verifiers failed to refute → completeness critic.
46 agents, 26 raw findings, 12 after dedup, **10 confirmed, 2 correctly killed**.

**Outcome:** the engine wiring was **reverted**. Library (`StructuralLeverage.sol`) and ratchet
(`B4Pool.sampleAnchor`) remain on-chain and safe. The engine sizes leveraged perps flat-`φ`
until the mechanism is rebuilt to meet SPECIFICATION §7b. This file is the durable record and
the pre-registered attack surface for that redo.

## Confirmed findings

| # | Sev | Votes | Site | Defect |
|---|---|---|---|---|
| **C6** | **Crit** | 3/3 | `B4VaultEngine.sol:818` | **The safety half was never implemented.** Margin is the pre-mechanism flat reserve `notional·φ/maxLev`; `StructuralLeverage` only amplifies *size*. The venue liquidation stays ~4 % below entry, never at the structural stop. `stopWad` is dead code. A bigger position at the same tight liquidation — worse than not shipping. (Also surfaced as C2, C3, C8 from other lenses.) |
| **C1 / C4** | **Crit** | 3/3 | `B4VaultEngine.sol:781 / :796` | **Held position detonates at the halving.** `_perpMultiplier` reads live anchors every crank while the sizing price is frozen at entry; the two are only valid captured together. Pro Max holds a long straight across the halving (never flat), so at the first permissionless `sampleAnchor` the flip raises `floor` just below the frozen entry, the delta `(p−floor)` collapses, computed leverage explodes to ~25×, and the engine force-buys into the held position → near-instant liquidation of the whole reserve. Dual branch: if the sampled low ≥ frozen entry, `leverageWad` returns 0, the L783 fallback substitutes flat `g`, and the engine force-*dumps* a winning position. |
| **C5** | High | 3/3 | `B4VaultEngine.sol:783` | **Refusal mis-mapped.** `leverageWad` returns 0 iff `p ≤ floor` (refuse → un-leveraged spot leg, per §7b). `if (lev <= WAD) lev = g` instead installs flat `g`, running a `φ` perp at exactly the existential-low price the mechanism exists to de-risk. Genesis (`floor == 0`) legitimately wants flat `g`; the two opposite cases are conflated. |
| **C7** | Med | 2/3 | `B4Vault.sol:130` | **"Whole deposit deployed" (§7b) absent.** `deposit()` routes 100 % of USDC into the owner-margin reserve, which `_strategyValueWad` excludes and no path converts to strategy capital. A USDC-only Pro Max deposit gets 0 exposure; a dir-only deposit leaves margin 0 → `notionalCap = 0` → the leveraged leg is silently absent (Pro Max runs as unlevered spot, no event). |
| **C9** | High | 2/3 | `B4VaultOps.sol:89` | **Demo fee model wrong.** The demo charged a high-water-mark fee (`≤1.72 % of profit`); the contract's `opsSettle` re-anchors the ledger to NAV every settlement unconditionally — no HWM — so a loss regime resets the baseline DOWN and the recovery is re-charged. Corrected, a hold-like product's fee is higher and the "Mini comfortably beats HODL" headline nearly vanishes. **Fixed in the demo 2026-07-21.** |
| **C10** | Med | 2/3 | `B4Pool.sol:235` | **Demo anchors unproducible by the ratchet.** The demo passed one `(floor, cap)` pair per cycle (cap = post-halving low) for all three regimes; the shipped `sampleAnchor` re-seeds `cap` UP at the 62-window (T), so the recovery long should size against the current bear-bottom cap, not a stale one. **Fixed in the demo 2026-07-21** (per-regime cap). |

Killed (correctly): a claimed "cap reseeds sideways-up" spec self-contradiction (parenthetical
misreading — the flip vs 62-window reseed are distinct and consistent); and a claim that the
pool-income distribution key guts the `+2.95 %` figure (the pro-rata-by-weight key is documented
in SPECIFICATION §10 / WHITEPAPER, not hidden — though it does mean the demo's flat per-stayer
credit is a simplification, noted in the demo).

## Uncovered surfaces the completeness critic flagged (carry into the redo)

1. **Non-flip anchor moves also re-trade a held position.** The within-window cap ratchet-down
   and the 62-window reseed-up change `_perpMultiplier` every cycle, not just at halvings; since
   `sampleAnchor` is permissionless, an attacker controls the cadence of forced reduce-only sells
   into a drawdown. Any redo MUST capture anchors *with* the sizing price and freeze both.
2. **Exit pricing vs held leverage.** `_navWad` excludes unrealized PnL and `_reconcile` writes
   losses down only at `szi == 0`, so an informed exiter could redeem at full recorded margin
   while an amplified perp carries hidden losses that land on stayers. Examine redemption/settle
   interplay at the new leverage magnitudes.
3. **Oracle latency skips the flip.** `sampleAnchor` window kinds derive from `timeSinceHalving`,
   but the flip fires only on a kind-0 sample; a LayerZero delivery delay > `Calendar.W` (20 d)
   makes the post-halving window unenterable, silently skipping the flip (floor a full cycle
   stale ⇒ more leverage). Distinct from the documented lazy-keeper residual.
4. **`notionalTarget`-rounds-to-zero dead zone.** With `szi != 0` and target below
   `MIN_ORDER_USD_WAD`, the planner issues no reduce and no margin return — a still-large position
   goes unmanaged through a transition, and a dust wind-down parks `perpMargin6` forever (H3).
5. **Test-suite blindness.** `StructuralSizing.t.sol` never samples an anchor between cranks of a
   held position, never crosses a transition/halving, and never checks the venue liquidation
   price against `stopWad` — structurally incapable of catching C1/C4 and C6.

## Requirements for the redo (must all hold before re-wiring)

- Margin posted MUST equal `notional / L` (§7b clause 4); venue liquidation MUST sit at
  `StructuralLeverage.stopWad(...)`. A regression MUST assert the liquidation price, not order size.
- The sizing price MUST be captured together with the anchors used to size, and BOTH frozen for
  the position's life; a calendar zone change (incl. the halving flip) is a re-size event that
  first flattens or re-derives, never a silent re-lever at a stale price.
- `p ≤ floor` MUST refuse to the un-leveraged spot leg (perp target 0); only `floor == 0`
  (genesis) degrades to flat `g`.
- The deposit path MUST deploy the whole deposit at `margin = notional/L` (no permanently idle
  reserve); dir-only / USDC-only degradations MUST be explicit (event or revert), not silent.
- Tests MUST cross a halving with a held position, sample anchors mid-hold, and compare the
  realized liquidation to `stopWad`. Then a fresh post-implementation adversarial round.
