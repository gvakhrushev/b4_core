# Proposal: penalty tranches — the pool rides the fall (v2 mechanism)

**Status (2026-07-21): designed, decisions locked; awaiting integration.** This is the
pre-implementation design record, prepared while the structural-leverage adversarial audit
runs. Sequencing agreed with the owner: audit round closes → adjudication + fixes → this
design is integrated (spec §9c + HAZARDS §C6 + implementation) in the next round, followed
by its own post-implementation adversarial pass. Nothing here is in the shipped code yet.

## Problem being fixed — the fall-zone asymmetry

The exit penalty (`q = 11.8%`) is paid to the pool **in kind**, proportionally across the
exiting vault's buckets (`B4VaultOps._payBucket`), and the pool holds it passively until the
next settlement. This carries the exiter's *stance* correctly in only one of the two regimes:

| Exit during | Exiter's buckets | Pool receives | Pool's stance until the zone |
|---|---|---|---|
| Growth (long) | spot BTC + margin USDC | mostly **BTC** | long — position carried ✓ |
| Fall 38–62 (Pro/Pro Max short) | USDC + margin USDC | almost pure **USDC** | flat — **the short is lost** ✗ |

In the fall zone the pool sits flat during exactly the regime where the strategy's stance is
short. The stayers' penalty income loses the fall-zone alpha. Fixing this is the point of
this mechanism: *"we built strategies that beat hold on both return and drawdown — it is
illogical for the pool to sit idle instead of running them."*

## Decisions locked (owner, 2026-07-21)

1. **A tranche can go to zero — accepted.** The user chooses the product and its risk; the
   protocol supplies four strategies and honest statistics, not risk management. A holder
   who did *not* exit faces the same stop on the same strategy.
2. **Pool income becomes strategy-exposed — intended.** Distribution replaces the flat
   guaranteed credit; in the fall zone shorts historically pay well (P-top → 62-bottom is
   −70…−80%), and loss tranches are possible. Deliberate change of profile.
3. **Dust-exit DoS is economically self-defeating** — the "attacker" pays the 11.8% penalty
   per exit, funding the pool they grief. The minimum threshold is technical hygiene, not a
   security control.
4. **A late tranche slides to the next interval — fine.** Deferral, not loss (H3).
5. **Reuse the existing stack** — tranches are standard vaults run by the standard engine.
   An audit round follows the implementation.

Design choices: **per-exit isolation** (one vault per tranche, own margin ⇒ own stop — one
tranche's stop-out cannot touch another); **stop inheritance** (the tranche reproduces the
exiter's stop *price*, not a fresh flat φ); threshold **technical, ~$10–20**.

## The mechanism

### Flow (the owner's model, verbatim in protocol terms)

An exiter holds a 1 BTC short with its margin-realized stop. On a penalized exit:

1. The exit machinery runs exactly as today: strict flatness, harvest, repatriation,
   in-kind split. Owner gets their share; **operator/referral are carved from the penalty
   immediately, in kind, as today** — they decide for themselves what to do with it.
2. The pool's penalty share (~0.11 of the position, slightly less after the operator carve)
   arrives in the pool in kind. During the fall this is USDC.
3. **Instead of sitting flat, the settlement-token share is escrowed with a tranche record**
   `{amount, stopPxWad, fallTarget}` — the stop is snapshotted at *exit initiation*, while
   the exiter's position is still live (by finalize time the perp is already closed).
4. A permissionless keeper step `openTranche()` consumes the record: creates a fresh vault
   (factory), **owner = the pool** (F2 fixed-owner: every payout returns to the pool by
   construction), policy `{growth: 0, fall: exiter's fall target}`, deposits the escrowed
   USDC. The engine — unchanged machinery — opens the short.
5. The tranche **rides to the zone**. At `T` the calendar flips the target to `0` and the
   engine flattens the tranche to USDC by itself (strict flatness at the regime end) — even
   if no one calls anything. A permissionless `poolExit(vault)`, gated to `owner == pool`
   vaults and `timeSinceHalving ≥ T`, finalizes the exit; proceeds pay the pool, `capture()`
   accounts them, and they distribute to stayers by weight at the settlement — *"the trade
   closes at the zone and what is distributed is the realized profit."*

### Stop inheritance — sizing, not stop orders

The venue has no position-transfer primitive and the protocol places **no trigger orders**
(a resting trigger can sit unfilled forever, which breaks the async completion discipline
"resend = exact complement of fills"). Both are unnecessary: the protocol already realizes
stops **by margin size** (SPEC §7b). The tranche opens at the current price `p` and inherits
the exiter's stop price `s` by sizing:

```
L_tranche = p / (s − p)          (short: s > p; clamped by the venue maxLeverage)
margin    = notional / L_tranche  ⇒ venue liquidation sits at s
```

- Three tranches with stops 30k / 33k / 27k are three vaults with three margins — three
  independent stops. Price going the wrong way stops out one tranche without touching the
  others (the owner's isolation requirement, achieved the protocol's native way).
- `p ≥ s` at open time (the market already went past the exiter's stop) → **refuse**, fall
  back to today's passive USDC. No position beyond its own stop is ever opened.
- `p` close to `s` → huge `L`, clamped by the venue `maxLeverage` (stop lands nearer than
  inherited; same clamp rule as §7b).
- Side effect worth making normative: this gives the short side the **structural ceiling**
  that SPEC §7b explicitly lacks ("no structural ceiling above a short") — the ceiling is
  the exiter's confirmed, margin-realized stop.

### What stays passive (explicit fallbacks — today's behavior)

- Growth-zone exits (the in-kind BTC already carries the long; the un-carried `L−1` perp
  excess of a Pro Max exit is a possible later extension, out of scope here).
- Mini (fall target `+1` — its in-kind BTC *is* the position) and B4 (fall `0` — flat is
  the stance; passive USDC is correct).
- Sub-threshold tranches, refused opens (`p ≥ s`), exits with no live short at initiation
  (mid-transition, wrong-sign cleanup), and the directional in-kind dust of any exit.

### Minimum tranche

The venue minimum is already enforced protocol-wide: `MIN_ORDER_USD_WAD = 10e18` — a perp
target below $10 notional zeroes out (`B4VaultEngine` L802). For the tranche to open at all:

- Pro Max fall `−φ`: notional = φ·margin ⇒ margin ≥ ~$6.2 for a $10 notional.
- Pro fall `−1/φ`: notional = 0.618·margin ⇒ margin ≥ ~$16.2.

**`MIN_TRANCHE_USD = $20`** covers both with headroom; below it, passive fallback. (Plus lot
rounding: a tranche whose size floors to zero lots at the venue's `szDecimals` also falls
back — checked at open, not assumed.)

## Invariants preserved (why this does not break the protocol)

- **Exit liveness never depends on tranche machinery** (the V3-POOL-1 pattern): the exit
  transfers and records; `openTranche()` is a separate permissionless step. A reverting
  factory, a full escrow queue, a broken tranche — none of it can block or delay an exit.
- **No new order machinery, no trigger orders, no position transfer.** The tranche is a
  standard vault; the engine, async keys, completion discipline, reduce-only rules and
  crank economics are the already-audited ones.
- **No admin, no privileged mover.** Creation, cranking, and `poolExit` are permissionless;
  the pool owns tranches only in the F2 fixed-payout sense — it has no initiative and no
  keys. `poolExit` is gated by `owner == pool` + calendar time, not by identity.
- **H3.** A stuck tranche is its own liveness island: worst case its proceeds miss the
  interval and accrue to the next one (deferral, accepted). Pool distribution of other
  assets is already per-token deferrable (D5).
- **Keeper economics.** Tranche count is bounded by real penalized exits ≥ $20; each one was
  paid for by an 11.8% penalty. Griefing-per-dollar is worse for the attacker than for the
  keeper.

## Honest risk statement (goes into HAZARDS §C6 at integration)

- **A short tranche has no surviving spot leg.** A gap through the inherited stop →
  venue liquidation → the tranche's margin is consumed → that tranche distributes ≈ 0.
  Bounded to the tranche by per-exit isolation; the passive-USDC counterfactual never zeroes.
- **Stayers' pool income becomes a distribution**, including loss tranches. In exchange it
  carries the fall-zone alpha the passive pool forfeits — the point of the mechanism.
- **Stop snapshots are only as good as the exit-initiation mark** — same oracle discipline
  as every other sizing read (`_livePxWad`), no new oracle surface.

## Draft normative language (paste into SPECIFICATION §9c at integration)

- On a penalized exit during the fall regime by a policy with `fall < 0`, the pool's
  settlement-token penalty share ≥ `MIN_TRANCHE_USD` MUST be escrowed with the exiter's
  live stop price snapshotted at exit initiation, and MUST be openable permissionlessly
  into a tranche vault (owner = pool, policy `{0, fall}`) sized so the margin-realized
  stop sits at the snapshotted price, clamped by the venue `maxLeverage`.
- `p ≥ stop` at open MUST refuse (passive fallback). A tranche below the venue minimum
  order or below `MIN_TRANCHE_USD` MUST fall back. Exit liveness MUST NOT depend on any
  tranche step.
- After `T` the tranche's target is `0`; the engine MUST flatten it by ordinary cranking.
  `poolExit` MUST be permissionless, gated to `owner == pool` and `timeSinceHalving ≥ T`,
  with no deadline (funds never strand). Proceeds accrue to whichever interval is accruing
  when they land.
- Growth-zone exits, Mini/B4 exits, and directional in-kind shares stay passive (today's
  §9 behavior is the normative fallback in every refused/sub-threshold case).

## Pre-registered attack surface (for the post-implementation adversarial round)

1. Escrow record lifecycle: double-open, open-after-refusal, stale snapshots across the
   halving, records surviving a policy change, escrow griefing by dust records.
2. Stop-inheritance math at the edges: `p → s` (maxLev clamp), `p ≥ s` refusal, sub-lot
   flooring, Pro's sub-1 exposure (`L < 1` semantics in the sizing formula).
3. `poolExit` gating: early-call griefing (must be impossible before `T`), re-entry with
   the pool as owner-recipient, interaction with `capture()` measured-receipt accounting.
4. Tranche vault under the degenerate `{0, fall}` policy: does the growth-side `0` truly
   flatten at `T` under all crank orders; no long ever opens; A13 no-spin on the flatten.
5. Factory-from-pool path: reentrancy, who pays gas, failure containment (openTranche
   reverts ⇒ escrow intact, exit unaffected).
6. Interval attribution: proceeds landing during `advance()` materialization races.
7. Double-counting vs `liability` in the pool when tranche proceeds return.
8. Keeper-abandonment: no `openTranche` call all regime — escrow must remain claimable as
   passive fallback at some point (design an expiry-to-passive rule at integration).

## Test plan (fail-before/pass-after at implementation)

- Unit: stop-inheritance sizing (inherit / clamp / refuse / sub-lot / sub-threshold);
  escrow record write at exit initiation with a live short; two-step open.
- Integration: full lifecycle — penalized Pro Max exit mid-fall → escrow → open → ride →
  `T` flip flattens → `poolExit` → `capture` → distribution by weights; late tranche →
  next interval; gapped tranche → liquidation → isolated loss, neighbors unaffected.
- Regression: exits never blocked by a reverting factory/escrow (V3-POOL-1 discipline);
  no completion key depends on tranche state; Mini/B4/growth exits byte-identical to today.

## Integration checkpoints

1. ~~`selectPolicy` accepts `growth = 0`?~~ **Verified 2026-07-21:** `_setPolicy` checks
   magnitude only (`|r| ≤ φ` after scale); zero targets pass — B4 itself is `{1, 0}`. The
   tranche policy `{0, fall}` needs only a trivial `IStrategy` returning those targets,
   installed at vault creation (deposit and policy are `onlyOwner` = the pool).
2. ~~Deposit-window gating vs mid-fall funding?~~ **Verified 2026-07-21:** `depositOpen`
   closes only in `OpeningFall`/`OpeningGrowth` — both are **free-exit** zones, where
   penalized exits cannot occur. Every penalized exit therefore happens while deposits are
   open; `openTranche` funds the tranche in the same steady zone. An escrow that lingers
   past the zone (keeper abandonment) hits a closed window only after `T`, when the ride is
   over anyway — covered by the expiry-to-passive rule (surface #8).
3. `MIN_TRANCHE_USD = 20e18` constant placement (pool, not engine).
4. Stop snapshot plumbing at exit *initiation* (the only moment the short is still live).
5. Escrow-expiry-to-passive rule for keeper abandonment (surface #8).
