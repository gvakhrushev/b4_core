# B4 — implementation architecture & design decisions

Clean-room implementation of the `b4-greenfield` specification package. This document is
normative for the implementation (HAZARDS G3): every place the package left freedom — or
contradicted itself — the resolution is recorded here, in the same change as the code.

## Contract map

| Contract | Role |
|---|---|
| `HalvingOracle` | Immutable LayerZero receiver of the proven halving fact (E1–E4); genesis fact anchored in the constructor; one-shot delegate renounce. |
| `HalvingProver` (Citrea side) | Permissionless publisher: verifies `dSHA256(header)` against the Citrea light client, sends `(height, header)`. |
| `B4Factory` | Permissionless pool creation + atomic vault clone/init (F3). Holds the settlement descriptor; no funds, no owner. |
| `B4Pool` | Shared reward basket: interval materialization from the calendar, all-or-nothing checkpoint-price lock (D1), liability discipline (D2–D5), weights, claims, sweep, capture. |
| `B4Vault` (clone) | Isolated per-user vault. Its address **is** the Core execution identity. Deposits, policy, crank entry, intent verification, emergency clear. |
| `B4VaultEngine` | The async engine (abstract base): intent creation/verification per HAZARDS A, sync planner, reconcile. |
| `B4VaultOps` | Delegatecall module (immutable address in the implementation): planners' step dispatch, settle, exit finalize, recovery bodies. Code organization for EIP-170 — **not** an upgrade path; nothing can repoint it. |
| `Keeper` | One permissionless crank for every step (G2). |
| `ReferenceStrategies` | Mini / B4 / Pro / Pro Max as `(growth, fall)` pairs. |

Custody model: steady-state custody is on the EVM side; Core holds only perp margin and
in-flight amounts. Every spot trade round-trips EVM→Core→EVM with every arrow proven
(SPEC §7).

## Async discipline (HAZARDS A) — where each rule lives

- **A1 prove-then-credit** — all completion in `B4VaultEngine._verify*`; only measured
  deltas are credited.
- **A2 reliable balance** — completion keys: spot net-decrease (`ToPerp`), spot
  net-increase ≥ amount (`FromPerp`), net-decrease + EVM receipt (`Return*`). The perp
  `withdrawable` is used **only** to size clamps, never as a completion/retry counter.
- **A3 exact complement** — every resend condition is `!completion ∧ timeout` on the same
  reads; resend re-arms the timeout so at most one emitted action is live.
- **A4/A5 harvest quota** — `pendingHarvest6` gates nothing; settlement is
  `min(claim, available-now)` and always clears the whole claim; the residual becomes
  recoverable surplus.
- **A6** — `emergencyClearRecovery` accepts only `Recover*` intents.
- **A7** — `Return*` legs never resend once the source decreased.
- **A8** — `Fund*` legs poll forever; no resend, no abandon.
- **A9** — first-credit completion threshold is `amount − activation allowance` (constant
  `ACTIVATION_FEE_USD_WAD = $5`; exact live fee is a funded gate).
- **A10** — margin return, exit realization, loss reconciliation all require raw
  `szi == 0`; the epsilon band applies only to non-zero rebalance targets.
- **A11** — credits capped at intended amount and price envelope both directions;
  favorable overfill and donations stay unaccounted and recoverable.
- **A12** — timeouts only schedule measurement/resend; no accounting is ever finalized by
  time.

## Deliberate spec resolutions (applied to the package)

Both resolutions below were confirmed by the product owner and applied to the package on
2026-07-18 (SPECIFICATION.md §4/§9, WHITEPAPER.md §4, TEST_PLAN.md §3b) — the package and
the code now state the same behavior (HAZARDS G3).

1. **Same-sign target interpolation (SPEC §4 vs REQUIREMENTS §2 Mini).** The literal
   piecewise `growth→0→fall` interpolation would force Mini (1,1) to sell everything and
   buy back at every transition, contradicting "markets used: none after deposit" and the
   whitepaper's "hold spot, no trade". The normative *purpose* of the zero split is that a
   **derivative sign change** always passes through a verified zero. Resolution: pairs
   with strictly the same sign interpolate directly `growth→fall` across the full
   transition (Mini ⇒ constant, zero trades); pairs with opposite signs or a zero
   endpoint use the piecewise split at zero exactly at the settlement points.
   (`Calendar.targetAt`; `testFuzz_sameSign_direct_interpolation`.)

2. **Exit reward-base C (SPEC §9).** `nextRewardBase = (R+C)·(1−x)` with C read as the
   *full-vault* client share lets repeated dust exits mint unbounded weight
   (x→0 ⇒ R += C each time), contradicting §9's own "repeated partial exits MUST NOT
   create or duplicate reward weight". Resolution: C is the **exiting share's** client
   share (`clientShare·x`), symmetric with the "proportional operator cut" in the same
   sentence. The remaining share's open profit settles at the next checkpoint — each
   share's profit earns client-share exactly once.
   (`B4VaultOps._finalizeExit`; `test_repeated_partial_exits_no_weight_duplication`.)

## Settlement cadence (derived, then fixed)

Settlement points are the two fixed, product-independent instants per epoch: `t = P−H`
and `t = T+H`. Derivation: for sign-changing pairs (opposite signs or a zero endpoint)
these are the target zero-crossings — SPEC §8's "reject a still-wrong-sign perp" and the
*realized*-profit measurement are exact precisely where the previous regime's derivative
exposure has unwound through the verified zero. Same-sign pairs (resolution 1 above)
never visit zero: they pass through the same instants with their right-sign exposure
legitimately open — the wrong-sign gate passes (sign matches the current target), the
valuation uses recorded principal (B3), and the fee is taken in kind on interval profit.
The interval that starts at `T+H` spans the epoch boundary and ends at the next epoch's
`P−H` (E4). A superseded epoch's unreached points are skipped by construction
(`lastPointTime` monotonic; zones follow the latest fact); a missed point degrades to an
unreportable interval whose inventory sweeps forward — delayed liveness, never a freeze
(H3).

## Fixed windows and constants (chosen where the package gave none)

| Constant | Value | Source |
|---|---|---|
| Snapshot window | 24 hours (the settlement day) | chosen; SPEC §6 requires a fixed window. Width is a liveness/discretion trade-off: it recurs only once every ~1–1.5 years, so an hour leaves no room to recover from a dead cron, while a wider window gives a late caller more choice over which price becomes canonical. Bounded because the fee-paying owner can lock at `pointTime` themselves. Missing it defers settlement, never destroys it (`SnapshotWindow.t.sol`) |
| Report window | 2 days after snapshot | chosen; liveness-only |
| Distribution window | until the next interval materializes; then single sweep | chosen (D4) |
| Post-halving free-exit window | 20 days (= W) | chosen ("a fixed window", SPEC §4) |
| `RESEND_TIMEOUT` | 1 hour | chosen; venue drops unexecuted actions far sooner (funded gate) |
| `EMERGENCY_TIMEOUT` | 3 days | chosen (A6) |
| Rebalance dead-band | max(1% of strategy value, $10) | chosen; venue min order $10 (SPEC §7) |
| Perp envelope | 50 bps of mark | SPEC §7 (given) |
| Spot slippage cap | ≤ 500 bps, per-vault | SPEC §7 (given) |
| Activation-fee allowance | $5 on the first credit | chosen (A9); funded gate |

## Economic decisions (HAZARDS §C — resolved with the product owner, 2026-07-18)

- **C1**: positive funding is **not** taxed. Harvest credit is bounded by snapshotted
  mark-PnL, so funding surplus never enters the realized ledger; it is owner-recoverable
  surplus. Funding losses are still borne — documented asymmetry.
- **C2**: mid-interval exit profit **does** earn pool weight (unified fee mechanism;
  client share per resolution 2 above; penalty is separate logic on top). Valued at the
  live oracle — by design not snapshot-protected; economically inert under a deep venue.
- **C3**: fixed `USDC = 1 USD`; no depeg cross-check (no second trust dependency, no
  halt path).
- **C4**: no independent oracle sanity band; the 500/50 bps execution envelopes are the
  defense; the venue oracle is a disclosed trusted dependency.

## Keeper runbook (G2)

`Keeper.crank(pool, vaults, maxVaultSteps)` performs, in order: `pool.advance()` (all
passed points), `lockPrices(latest)`, a bounded `sweep` catch-up window (`SWEEP_LOOKBACK`),
`capture()`, then per vault via self-guarded external wrappers: `crankVault()` (intent
verify / sync step / exit step / finalize, ×N), `settleVault(reportable)`,
`claimFor(latest interval only)` (older intervals are swept forward before they fall behind,
so claiming `count−2` is a no-op — V3-VENUE-5), and `retryDeferred()`. Each per-vault call is
wrapped in `try this.crankVault/settleVault/retryDeferred` so a malformed or **codeless**
`vaults[]` entry is isolated and never rolls back the pool steps or other vaults (V4-VENUE-1).
Run it on a schedule (minutes-level during transitions, and always promptly after each
settlement point to hit the 24h snapshot window — lock early, at `pointTime` where possible).
Every call is permissionless; a stalled
step never blocks the others.

## Payout liveness and settlement valuation (hardening, 2026-07-18)

- **Pay-or-defer.** Every settle/exit payout (owner, operator, referrer, pool) is
  try-transferred; on failure (e.g. a USDC-blacklisted recipient — blacklistable
  settlement is in-model, SECURITY_MODEL §4) the amount is recorded as a deferred payout
  instead of reverting: a recipient's transfer failure can never freeze the vault (H3).
  `claimDeferred(recipient, token)` is a permissionless retry paying only the recorded
  recipient (F2); the keeper retries it each crank. Deferred amounts stay accounted and
  are excluded from unaccounted-EVM recovery.
- **In-flight funding at settlement.** An EVM→Core Fund leg is the only intent whose value
  is in neither bucket mid-flight (EVM debited at send, Core credited at proof). An earlier
  design valued this in-flight amount explicitly at settlement (a `_inFlightFundWad`
  helper). That approach was **superseded** by the settle-requires-idle hardening below
  (RAW-A-001): `opsSettle` now reverts `IntentPending` while any intent is in flight, so a
  valuation never runs mid-Fund — there is no in-flight amount to value and no
  `_inFlightFundWad` symbol in the code. The mid-flight "phantom profit" concern is
  therefore prevented structurally (by never valuing a non-idle engine) rather than by a
  special-case correction, and the later Core credit is still capped at the sent amount
  (A11) so it can never double-count. Regression: `test_settle_requires_idle_then_no_phantom_profit`.

## Discovery-report hardening (2026-07-18, see REPORT.md adjudication)

- **Settle requires an idle engine; reconcile only ever runs at idle.** `opsSettle`
  irreversibly pays the operator fee in kind and reports pool weight, so it must value a
  settled ledger — it reverts `IntentPending` if any intent is in flight. Since every
  valuation caller (settle, exit-finalize, the sync/exit planners, recovery) is idle,
  `_reconcile` is a plain flat-check: at idle the withdrawable moves only for real reasons
  (an order's realized PnL / liquidation), never for a transfer of our own, so the B2
  write-down is always a genuine loss and can never reclassify returning principal as
  fee-bearing profit (finding RAW-A-001, and the adversarial coincident-loss race). The
  report window (>2 days) dwarfs intent completion (~1h resend), so requiring idle costs
  nothing in practice; only an ecosystem venue failure could stall an intent past the
  window (documented liveness residual, H3). Spot-only vaults skip reconcile entirely (no
  perp principal, no perp precompile read).
- **Order sizes clamp, and funding respects the Core-balance ceiling.** The fixed-1e8 writer
  size field is uint64; a micro-priced asset held in the tens of millions of USD would
  overflow `lots·10^(8−szDec)`. The sell/fund sizing clamps to `uint64.max` instead of
  wrapping (V3-ACCT-2) — the delta-measured engine re-derives and chunks the move across
  cranks, so a reduce-only flatten still reaches raw zero (A10). A Core **spot balance** is
  itself uint64, so the chunked fund must also respect that ceiling: `_startFund`
  headroom-caps every EVM→Core credit by the live Core balance
  (`headroom = uint64.max − _spotBal(coreToken)`; zero headroom ⇒ the Core side is full and
  is sold down first, no deadlock), covering the sell/buy/margin legs symmetrically
  (V4-ENG-1 — the completion of V3-ACCT-2, which had funded a second `uint64.max` chunk on
  top of a sub-lot residue and overflowed). Binding also rejects `spotSzDecimals > 8`,
  `perpSzDecimals > 6`, `spotSzDecimals > coreWeiDecimals`, a wei/EVM decimal spread `> 30`,
  `coreToken > uint32.max`, and nonzero perp fields on a NO_MARKET descriptor (latent
  exponent-underflow / id-alias traps).
- **CoreWriter units.** Order `limitPx`/`sz` are emitted in fixed-1e8 (human × 10⁸) —
  deliberately different from the szDecimals read conventions; the mock enforces the same
  asymmetry and exact-calldata regressions pin the emitted bytes. Funded gates §5.4–5.
- **Spot-only vaults.** The NO_MARKET sentinel never reaches the position precompile;
  such a vault is permanently, strictly flat, supports spot products (Mini/B4), and a
  perp-bearing policy degrades to its spot component (disclosed).
- **Extended perp ids.** `perpMarket > uint16.max` (HIP-3 style) is rejected at binding —
  the legacy uint16 position read would alias an unrelated market. Supporting them needs
  the wide position read confirmed on the funded venue.
- **SafeTransfer.** Return data parsed manually; `tryTransfer` cannot revert on malformed
  bytes — the D5 fail-soft claim path and pay-or-defer survive grief tokens.
- **Shortfall flooring (accepted).** Pro-rata haircuts floor per claim; later claimants
  may pick up prior claims' sub-unit dust (bounded by ~1 wei per claim per token,
  protocol-favoring per B5). Order-independence holds to ±1 unit — not a defect.

## Known-accepted residuals (mirror of SECURITY_MODEL §3)

- A ≥-amount external top-up can fake one balance signal once; always attacker-funded,
  never freeze/theft; books stay ≤ real assets; excess is owner-recoverable
  (`test_R7_*`). Full closure needs a venue action receipt/nonce (funded).
- A permanently dropped EVM→Core bridge credit stalls that vault's engine (A8) — an
  ecosystem-wide venue failure by assumption, not a B4-specific state.
- Unreconciled market losses transiently overstate recorded perp margin until the next
  flat valuation (B2); self-heals on one crank (`reconcileHeals` invariant handler).
