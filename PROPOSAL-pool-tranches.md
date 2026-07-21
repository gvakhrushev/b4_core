# Proposal: the pool rides the fall — a standing pool short (SPS-1)

**Status (2026-07-21): designed, direction decided (SPS-1), gated behind the §7b redo.**
Pre-implementation design record. Sequencing: the structural-leverage §7b redo lands first
(margin `= notional/L`), then this. Until then the pool holds its fall-zone penalty share as
**passive USDC** — the honest interim. Nothing here is in shipped code.

**Design evolved (2026-07-21).** An earlier draft used *per-exit isolated tranches* with the
exiter's *inherited stop*. Working through the small-penalty problem (below) with a multi-agent
generate → adversarial-stress → synthesis pass (18 candidates, 3 killed on stop-attribution)
overturned that: the dust problem *forces* aggregation, aggregation needs a *shared* stop, the
only sound shared stop is a *far product-flat* one, and a far stop makes an in-regime shared
stop-out nearly impossible — which removes the entire reason isolation existed. The owner
accepted the reversal. The design is now a single standing pool short (SPS-1), no isolated tier.

## Problem being fixed — the fall-zone asymmetry

The exit penalty (`q = 11.8 %`) is paid to the pool **in kind** (`B4VaultOps._payBucket`) and
held passively until the next settlement. This carries the exiter's *stance* in only one regime:

| Exit during | Exiter's buckets | Pool receives | Pool's stance to the zone |
|---|---|---|---|
| Growth (long) | spot BTC + margin USDC | mostly **BTC** | long — carried ✓ |
| Fall 38–62 (Pro/Pro Max short) | USDC + margin USDC | almost pure **USDC** | flat — **the short is lost** ✗ |

In the fall the pool sits flat during exactly the regime where the strategy's stance is short.
The stayers forfeit the fall-zone alpha. Capturing it is the point of this mechanism.

## The small-penalty problem that shaped the design

A penalty share is often too small to open a perp at all. Two distinct failure modes:

1. **Dust:** a small deposit → a small penalty. `$20` deposit → `~$2.36` penalty; Hyperliquid's
   perp minimum is **`$10`** (confirmed on the live venue). `$2.36 < $10`.
2. **Low inherited leverage:** under the *old* per-exit design a decent penalty still opened a
   tiny notional when the exiter was deep in profit — the inherited stop `s` sits far above `p`,
   so `L = p/(s−p)` is low and `notional = penalty·L < $10` (a `$30` penalty at `L=0.3` → `$9`).

The second mode is caused by *stop inheritance itself*. Drop the inherited stop, size at the
product-flat leverage, and it disappears: `$30` of penalty → `~$30` of notional regardless of
the exiter's profit. That, plus the fact that dust *must* be aggregated to open at all, is why
the design collapses to a single aggregate short.

## The mechanism — SPS-1

### One standing pool short per (asset, product)

The pool runs a single reusable, pool-owned short vault per **(directional asset, product)** —
bounded (≤ assets × leveraged products, a small constant). It is an ordinary vault run by the
ordinary engine with a fixed degenerate policy `{growth: 0, fall: product's fall target}`
(Pro `{0,−1}`, Pro Max `{0,−φ}`), owner = the pool (F2 fixed-payout).

Every fall-zone penalty share — dust, low-L, or large — is an **O(1) scalar add** to that
vault's escrow accumulator; there is **no per-exit object at all**. A permissionless crank folds
the accumulated escrow into the vault as margin/notional. Dust rides as soon as the cumulative
escrow clears the keeper break-even threshold; below it, it stays staged (= passive) and reverts
to passive at `T`. The low-L mode does not exist (notional is product-flat, not inheritance-tied).

At `T` the calendar flips the vault's target to `0`; the engine flattens it by ordinary cranking
even if no one calls anything. A permissionless `poolExit`, gated to `owner == pool` and
`timeSinceHalving ≥ T`, finalizes; proceeds pay the pool, `capture()` accounts them, and they
distribute to stayers pro-rata by weight at the settlement.

### The aggregate stop — product-flat far ceiling (NOT the anchor)

**The structural anchors cannot ceiling a short.** They are confirmed structural *lows* (they
bound a long's stop from below); a short's stop is *above* price. Spec §7b says so explicitly
("no structural ceiling above a short"). Inheriting the anchor is unavailable without a new,
symmetric confirmed-*high* ratchet — deferred (see "left on the table").

The sound, no-new-machinery substitute is the **product-flat far stop**: margin `= notional/L`
at the product's own leverage, so venue liquidation sits at `1× short → 2·p` (Pro),
`φ short → φ·p ≈ 1.618·p` (Pro Max). In the fall regime price is *falling* from the top, so this
stop sits 60–100 % **above** entry — an in-regime shared stop-out essentially cannot occur, which
is exactly what makes sharing one stop safe and dissolves the case for isolation.

- **Cap-drift (mandatory).** A standing short topped up down the fall has a blended entry that
  drifts down, dragging its realized liquidation down with it. Refuse any top-up that would pull
  the aggregate's realized liquidation below the **fall-start price `P`**; route the overflow to
  passive. This pins the stop above the top of the traversed range, so no counter-trend bounce
  can hit it.

### Standing short vs generational fresh tranches — decide against the §7b code

If the redone §7b engine can safely re-size a **held** short on each top-up (drift-bounded, no
re-lever), keep the single standing vault (SPS-1). If it cannot — re-sizing a live leveraged
short against the current mark is *precisely* the reverted C1/C4 detonation — fall back to
**SPS-3**: the same accumulator mints a **fresh, once-sized, frozen** tranche each time the
escrow clears threshold, never touching a live position. Same stop, same aggregation; more
keeper objects. **This is decided against the redone sizing code, not in the abstract.**

## Mandatory implementation constraint (every candidate independently found this)

**Escrow must be a segregated sub-ledger, not the pool's USDC balance.** The permissionless
`B4Pool.capture()` sweeps any balance-above-`liability` into distributable `accruing`; escrow
sitting in the pool balance would either be *stolen* by `capture()` (mechanism silently no-ops
to passive) or *double-counted* against `liability` (haircutting unrelated stayers via the
`claimFor` shortfall path). Required: a segregated `escrowTotal` that `capture()` nets out
(`bal − liability − escrowTotal`), decremented atomically on funding, with the exit's escrow
write wrapped in `try/catch` so exit-liveness never couples to aggregation (V3-POOL-1). Ship an
invariant test asserting `balance ≥ liability + escrow` through every branch.

## Decisions

**Settled (2026-07-21):**
- **Single-tier SPS-1, no isolated tier.** Isolation guarded against a shared stop-out that the
  far stop makes near-impossible; surrendering it is close to free. (Overturns the earlier lean.)
- **Aggregate stop = product-flat far stop**, now. A market-confirmed high-ratchet is optional
  future tightening, not a blocker.
- **Trigger threshold = keeper break-even**, not the `$10` venue minimum (opening at the bare
  minimum mints objects too small to profitably crank, which silently degrade to passive).
- **Truly-unopenable residual stays passive** one interval (deferral, never loss) — the explicit,
  pre-committed fallback.
- **Per-(asset, product) bucketing** kept, so Pro Max runs its short at `φ`, not `1×`.

**Deferred to the §7b code:** standing (SPS-1) vs generational (SPS-3), per the re-size question.

## Invariants preserved

- **Exit liveness never depends on this** (V3-POOL-1): the exit adds a scalar to escrow inside a
  `try/catch`; folding/opening/`poolExit` are separate permissionless steps. A wedged vault,
  full escrow, or reverting fold can never block or delay an exit.
- **No new order machinery, no trigger orders, no position transfer.** Standard vault, standard
  engine, already-audited async keys, reduce-only rules, crank economics.
- **No admin / privileged mover.** The pool "owns" the vault only in the F2 fixed-payout sense —
  BUT it must hold the vault's `deposit`/`initiateExit` authority, which is *more* than F2.
  Constrain to permissionless, zero-discretion, fixed-parameter wrappers (fixed vault address per
  bucket, fixed policy, hardcoded recipient); enumerate that no other `onlyOwner` power is reachable.
- **H3:** worst reachable state is deferral-to-passive, self-healing by permissionless crank —
  never freeze, never loss (once the escrow-segregation fix is in).
- **Keeper economics:** zero per-exit state — dust spam is a scalar add that costs the attacker
  11.8 % funding the pool it griefs; no object to bloat, no loop to OOG, no per-exit list.

## Pre-registered attack surface (for the post-implementation audit)

1. **Escrow ↔ `capture()`/`liability` double-count** — the single most-repeated finding.
   Invariant test `balance ≥ liability + escrow` through fund/expire/poolExit/loss.
2. **Exit-liveness independence** — exits byte-identical when the escrow/vault reverts, is
   closed, or is wedged.
3. **Held-position re-lever on top-up (C1/C4 redux)** — if SPS-1's standing short is chosen, the
   completion/retry key reads only self-moved balances (size, spot deltas), never PnL/withdrawable;
   the top-up re-size must be provably drift-bounded.
4. **Blended-entry drift below `P`** — the cap-drift rule is load-bearing; without it a deep-fall
   liquidation drifts into the traversed range and a bounce wipes the book.
5. **Pool-as-owner initiative** — constrain the deposit/exit authority to fixed-parameter
   wrappers; prove no other owner power is reachable.
6. **Standing vault in its own distribution** — bar the pool-owned short from
   `reportWeight`/`claimFor` so it cannot dilute or self-claim against the pool it feeds.
7. **Cross-interval attribution / late-joiner skim** — proceeds land in one lump at `T` and
   distribute by weight-at-`T`; deposits are open through the fall, so a just-before-`T` depositor
   skims the concentrated fall alpha. The two-settlement calendar bounds it (the whole fall is one
   interval), but the concentration is real — gate eligibility to pre-fall tenure if it matters.
8. **Threshold / graduation griefing** — a permissionless crank must not open the aggregate at a
   wick or the venue floor; for SPS-3, `graduate()` timing sets the batch entry price.

## Value left on the table (honestly)

- **Sub-threshold late-fall tail stays passive** and captures no fall alpha — the genuine residual
  leak, largest in thin pools and late in deep falls.
- **No market-confirmed short ceiling** — the product-flat stop is sound but product-defined, not
  structurally anchored. A symmetric confirmed-high ratchet (mirror of `sampleAnchor`'s lows)
  would market-justify the ceiling; net-new audited machinery, deferred.
- **Per-exiter tailored stops are gone** — but the analysis shows those far tailored stops were
  the *cause* of the low-leverage failure, not a feature worth preserving.
