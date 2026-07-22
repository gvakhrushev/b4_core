# B4 re-implementation — status report

**Status: pre-mainnet.** The suite below is green, but production is gated on the funded
proofs and an independent audit (SECURITY_MODEL §5). Nothing in this report claims venue
semantics proven — local mocks cannot reproduce venue timing/atomicity.

## Proven locally (forge, mock venue)

- `forge build` clean, `forge fmt --check` clean, full `forge test` green
  (unit + integration + invariant campaigns; nightly profile `deep` 512 runs × 256 depth
  also green).
- All mandatory regressions of TEST_PLAN §2–4 — the exact traps that survived prior
  audits — fail-before/pass-after with adversarial variants (see INVARIANTS.md).
- All 18 SECURITY_MODEL §2 invariants traced to tests with honest GAPs (INVARIANTS.md).
- Contract sizes: every deployed contract under EIP-170; factory initcode under EIP-3860.
- Two internal spec contradictions surfaced, resolved, confirmed by the product owner and
  **applied to the package** (2026-07-18): same-sign interpolation — no forced sale, fee
  still on profit (SPECIFICATION.md §4, WHITEPAPER.md §4); exiting-share client share
  `nextRewardBase = (R + C·x)·(1−x)` (SPECIFICATION.md §9). Both are now mandatory
  regressions (TEST_PLAN.md §3b) with passing tests.

- A 26-agent adversarial consistency sweep over package↔docs↔code↔tests after the
  amendments; every confirmed finding fixed, including two hardening changes with
  fail-before/pass-after tests: pay-or-defer on failed payout transfers (a blacklisted
  recipient can no longer freeze settle/exit — H3) and in-flight-funding-aware
  settlement valuation (returning principal can no longer read as next-interval profit).

- **Post-build independent audit (2026-07-18):** a fresh multi-agent adversarial audit
  (5 hunt surfaces × independent verification) over the whole build. Async completion/retry,
  accounting, pool, calendar and authority surfaces came back clean at the code level (the
  prior total-fund-freeze High and the theft/deadlock classes were confirmed genuinely fixed,
  not just claimed). One **Medium liveness** defect found and fixed (new hazard **A13**): the
  sync planner's `_planSpotStep` returned `true` on a sub-lot spot no-op, short-circuiting the
  perp-sizing leg (perp hedge left unmanaged) and spinning the keeper on false progress. Fix:
  `_startFund`/`_startSpotOrder`/`_startToPerp` now report whether an intent was actually
  created; the planner reports progress only on a real state change and otherwise falls through
  to size the perp. Fail-before/pass-after regression on a coarse-lot market
  (`test_M1_sublot_spot_residual_does_not_starve_perp`, SyncMachine.t.sol).

## External discovery-report adjudication (2026-07-18)

All nine candidates of the repository-wide discovery report were adjudicated; every
confirmed defect carries a fail-before/pass-after regression (`FindingsRegression.t.sol`):

| Candidate | Verdict | Action |
|---|---|---|
| RAW-A-001 settle vs. unverified margin return | **Confirmed** (initial fix then re-refuted by adversarial pass, now hardened). Reconcile wrote the designed withdrawable dip of an executed-but-unverified perp transfer down as "loss"; principal resurfaced as fee-bearing profit. An in-flight-skip fix was itself refuted: a *genuine* loss coinciding with an in-flight transfer at a non-idle `settle` still over-reported. | `opsSettle` now **requires idle** (reverts IntentPending); `_reconcile` is a plain flat-check that only ever runs at idle, so it always sees genuine losses and never our own transfers. Spec §5 + HAZARDS B2 amended. |
| RAW-B-001 malformed ERC-20 return | **Confirmed.** `abi.decode` on junk return bytes reverted the whole fail-soft claim path (D5). | `SafeTransfer` parses the return word manually; `tryTransfer` is now revert-free, malformed data degrades to soft failure. |
| RAW-B-002 shortfall flooring order-dependence | **Accepted residual.** Per-claim floors leave wei-scale dust that later claimants may pick up; bounded by ~1 unit per claim per token (asserted ±1 in the order-independence test), protocol-favoring (B5). Not a fix. | Documented here and in ARCHITECTURE.md. |
| RAW-C light-client ABI | **Hardened.** Getter renamed to Citrea's published `getBlockHash(uint256)`; exact live selector stays a funded gate — if it differs, point `lightClient` at a thin permissionless view adapter (no trust added). | Interface + prover + docs. |
| RAW-D spot/perp writer scales | **Confirmed direction.** CoreWriter order fields are fixed-1e8 per current public docs, not read/lot units. | Engine converts px WAD→1e8 and lots→1e8 at emission; mock mirrors the writer↔reader asymmetry; exact-calldata regressions assert emitted bytes. Live confirmation remains funded gates §5.4–5. |
| RAW-D NO_MARKET position read | **Confirmed.** The accepted spot-only sentinel reached the position precompile truncated — on a strict venue every lifecycle path would revert. | `_position()` guard: NO_MARKET ⇒ permanently flat, perp planning skipped (spot-only vaults support spot products; a perp-bearing policy degrades to its spot component). Mock now fails invalid-asset position reads; full spot-only lifecycle regression. |
| RAW-D HIP-3 uint32 ids | **Confirmed hazard, rejected at binding.** A wide id would alias an unrelated market in every uint16 flatness/verification read. | Descriptors with `perpMarket > uint16.max` revert `PerpIdUnsupported` until the wide position read is funded-confirmed. |
| RAW-E-001 invariant revert masking | **Confirmed.** Handler-local `require`s were silently tolerated under `fail_on_revert = false`. | All handler assertions converted to ghost flags asserted by dedicated invariant functions (`invariant_policy_never_moves_funds`, `invariant_reconcile_heals`); the reconcile-heals ghost gates on `pendingHarvest6 == 0` so the designed one-crank heal delay isn't a false positive. |

A second adversarial pass (5 agents) against this fix batch **refuted 3** of the fixes with
concrete scenarios — all now closed with regressions: the settle/reconcile coincident-loss
race (→ settle-requires-idle, above); a uint64 overflow in the fixed-1e8 order-size
conversion for micro-priced assets (→ clamp lots, `test_D_writer_units_no_overflow_micro_asset`);
and a flaky `reconcileHeals` invariant handler (→ `pendingHarvest6 == 0` gate). Hardening from
the non-refuted findings: `SafeTransfer._call` caps returndata copy at 32 bytes (return-bomb
safe) and accepts only a canonical ABI `true`; binding rejects out-of-range decimals/token
widths and stale perp fields.

**Static analysis: run.** `slither-analyzer` 0.11.4 whole-repo with the `slither.config.json`
triage (30 contracts, 95 detectors, 131 results; `slither . --fail-high` exit 0). Every
high-severity result is a verified false positive
(delegatecall-proxy analysis, canonical `mulDiv` XOR seed, intentional strict-equality);
two Medium reentrancy detectors were cleared with checks-effects-interactions ordering
(defense-in-depth beyond the existing guards) and one Low with a zero-check. Full
per-detector triage in `SLITHER.md`. The static-analysis gate (SECURITY_MODEL §5) is
satisfied for this internal run.

## Deployment gates — funded venue confirmation (SECURITY_MODEL §5, TEST_PLAN §5)

**Status: `mainnet-gate` — planned deployment steps, not open defects.** Each item below is
already *implemented* against the venue's published ABI/encoding and is exercised locally
against an exact-ABI adversarial mock. What cannot be done off-chain is *confirming the live
venue behaves as its documentation says* — no mock can prove that, for any protocol.

So this is a **deployment runbook**, not a list of things that are broken or unknown: each
line is expected to hold (it is derived from the published semantics the implementation was
built on) and is checked once with funded transactions on the target network. A line that
failed would be a venue-semantics surprise, and each is written so the failure is visible
immediately rather than silently mispriced.

Nothing here may be skipped: mainnet MUST NOT proceed until these are recorded and
independently reviewed.

1. Canonical USDC identity, decimals (EVM 6 / core wei 8 assumed), both class-transfer
   directions.
2. Directional token decimal conversions + round trip (descriptor fields vs live
   `tokenInfo`, incl. `evmExtraWeiDecimals` sign).
3. **Fresh-account activation** and its fee (assumed ≤ $5 allowance, deducted from the
   first credit; `coreUserExists` gating).
4. Spot asset-id offset (10000+), lot rounding, IOC encoding, price-unit conventions
   (8 − szDecimals) and bounds.
5. Perp price/size/entry-notional scaling (6 − szDecimals; entryNtl 1e6).
6. Margin in/out, positive harvest, realized loss, principal reconciliation end-to-end.
7. Partial exits on the live venue: full flatten to raw zero, complete margin return,
   proportional payment, remaining-vault resync.
8. Partial / no / delayed fill and the retry behavior around `RESEND_TIMEOUT`.
9. Core debit + EVM receipt on every return path (debit-then-deliver window length).
10. **CoreWriter action atomicity** and **no delayed double-execution across a resend**
    — the assumption that makes A3-resends safe. The engine re-arms the timeout per
    resend so at most one emitted action is live at a time; confirm the venue drops
    unexecuted actions well inside 1 hour.
11. **Reduce-only close to raw `szi == 0`** on a fine-lot market (A10).
12. Citrea light-client contract identity and hash byte-order convention; light-client
    publication + LayerZero delivery with production libraries/DVNs.
13. Permanent delegate removal on both LayerZero sides after configuration
    (`renounceDelegate`, one-shot — verify on-chain state).
14. Reproducible-build manifest: deployed runtime bytecode equality for every contract —
    including `B4Vault` (immutable `ops` pointer) and `B4VaultOps` — plus constructor
    args, linked settlement descriptor, and pool descriptors.
15. Precompile gas-cost calibration for every read used in completion proofs.

## Residual risks (accepted, documented)

- One-shot balance-signal fake by a ≥-amount external top-up: attacker-funded, bounded,
  recoverable (HAZARDS A11); closure requires a venue action receipt/nonce — design
  toward it when the venue exposes one.
- Permanent bridge-credit loss (A8) stalls the affected vault's engine — ecosystem-wide
  venue failure by assumption.
- `USDC = 1 USD` fixed (C3); no oracle sanity band (C4); funding income untaxed while
  funding losses are borne (C1); exit weight valued at the live oracle (C2) — all
  economic decisions confirmed by the product owner on 2026-07-18.
- Operator fee at settle is payable only from the EVM basket; if the basket is empty at
  settle time the unpaid remainder is not carried (protocol-favoring, disclosed).

## Round 1 — internal first-principles audit

A self-directed first-principles audit (12 bug-class finders + adversarial verification)
found and fixed 3 issues: a High (untaxed harvest extraction via `recoverPerpSurplus`), a
Medium (pool `sweep`/`capture`/`advance` reentrancy from a malicious basket token), and one
accepted Low residual (all-or-nothing checkpoint lock couples co-resident vaults in a shared
pool — within the "no Pool-quality guarantee" boundary). Both code fixes carry
fail-before/pass-after regressions. This is internal and does not substitute for the
mandatory independent audit below.

## V3 audit round

The deepest internal round (5 parallel adversarial workstreams + an independent adjudication
pass) found **4 Medium, 6 Low, 8 Informational**. No Critical/High: no theft path and no
escape-free custody freeze — but two Mediums broke the H3 "self-healing by cranking" standard.
All four Mediums are fixed with pass-after regressions: gas caps on untrusted-token calls +
exit `capture()` guard (V3-POOL-1); a pre-activation first-fund floor so an activation-fee ≥
first-fund can no longer wedge the engine (V3-ENG-1); a `FeeNotRepatriated` guard so a
Core-heavy vault cannot dodge the operator cut while reporting full pool weight (V3-ACCT-1);
and clamp-not-truncate `uint64` sizing with a sub-lot fall-through so an oversized micro-position
keeps rotating instead of freezing at `2⁶⁴` (V3-ACCT-2 — **later found incomplete; completed in
the V4 round below**). Lows folded into a hardening patch:
keeper per-vault isolation, descriptor decimal-range bounds, an **enforced EIP-170 size gate**
(B4Vault sits at 24,195/24,576 B — a min-margin test now fails before a real deploy would),
CI pins, and test-quality fixes (one hollow and one vacuous test repaired, a stale traceability
name, an unguarded harness `advance()`). V3-ACCT-1's happy-path safety was independently
re-verified (both B4 and Pro Max rest value on EVM in steady state, so the guard never blocks a
properly-cranked settle).

## Coverage-ledger sweep (codex-security-snapshot)

A 19-agent adversarial sweep (one finder per code boundary + cross-cutting critics, verified
by skeptic panels) over the whole tree returned **zero new findings** and closed all 14 code
boundaries clean. **Important honesty note:** that sweep ran on the post-V3 tree and declared
it clean — the V4 round below then found a genuine Medium (V4-ENG-1) in exactly that tree. A
broad-fan-out "clean" sweep is real evidence but NOT proof of absence; the incremental
re-audit that re-derives each specific fix caught what the coverage sweep missed. This is the
"looks clean ≠ is clean" standard doing its job, and the reason each fix carries its own
fail-before regression rather than resting on a sweep.

## V4 audit round (post-remediation re-audit)

An independent re-audit of the V3 fixes (every fix re-read and proven fail-before with
sha256-verified restores) verified **3 of the 4 Medium fixes complete** but **refuted two as
incomplete** — both now fixed:

- **V4-ENG-1 (Medium)** — the V3-ACCT-2 clamp stopped one chunk short: after chunk 1 leaves a
  sub-lot Core residue `r`, chunk 2 re-funds `uint64.max`, so the credit `r + uint64.max`
  overflows the uint64 Core balance (revert locally / dropped-credit A8 wedge on the venue;
  reachable ≈ $370k of a micro-priced asset, no attacker). Fix: `_startFund` now headroom-caps
  every fund by the live Core balance (`headroom = type(uint64).max − _spotBal(coreToken)`;
  zero headroom ⇒ sell down first, no deadlock), covering the sell/buy/margin legs
  symmetrically. Pass-after: `test/unit/V4Eng_CastConvergence.t.sol` (2 converted demonstrators
  + 6 convergence controls).
- **V4-VENUE-1 (Low)** — the V3-VENUE-1 keeper isolation didn't cover **codeless** `vaults[]`
  entries: since solc 0.8.10 the extcodesize pre-check reverts in the crank frame, outside the
  `try v.crank()`/`try v.settle()`. Fix: per-vault calls now route through self-guarded
  external wrappers `this.crankVault`/`this.settleVault`, so the extcodesize revert is caught.
  Pass-after: `V3Venue_KeeperIsolation.t.sol` converted (mixed `[healthy, EOA]` list — pool
  steps + healthy vault survive).

Both fixes were then **independently adversarially re-verified complete** (all fund sites route
through the capped `_startFund`; convergence monotonic; every vault-touching keeper call inside
a `try this.*`). **Final verification state: 205/205 green**, `forge fmt --check` clean, deep
invariant campaign 512×256 green (8/8, 131,072 calls each, zero reverts), size gate green
(B4Vault 24,195 B), `slither . --fail-high` exit 0 (95 detectors, 131 results).

## Recommended next steps

1. **Independent external audit** with a dedicated round on the async completion/retry,
   harvest-quota and recovery paths — the class the prior build's permanent-freeze High lived
   in, and the class where V4-ENG-1 still surfaced after three internal rounds. Internal
   convergence on "clean" is strong but does not substitute for it.
2. Funded gate campaign per the list above, recorded and independently reviewed.
3. ~~Amend the specification package with the two errata~~ — done 2026-07-18
   (SPECIFICATION.md §4/§9, WHITEPAPER.md §4, HAZARDS.md §C decisions, TEST_PLAN.md §3b).

## Structural sizing (2026-07-21/22): both sides specified + math shipped; engine wiring REVERTED after audit

The mechanism specified in `SPECIFICATION.md` §7b, `HAZARDS.md` §C5 and
`PROPOSAL-structural-leverage.md`: every leveraged position's liquidation sits at a
*structurally confirmed* extreme, realized by margin size (`margin = notional/L`) — longs
bounded by the confirmed lows (`stop = min(p − (p−floor)/g, cap)`), shorts by the confirmed
highs (`stop = max(p + (MaxStop−p)·(g−1), C)`, `MaxStop = C + (C−prevPeak)·(g−1)`), sized once
per regime and **held**. Verified on every completed cycle: the structural stop was never
touched, while flat-`φ` is liquidated by the +99–103 % bear rallies (short) and the −64 %
COVID crash (long). Preceded by a design + adversarial-critique round (which caught an
inverted fail-safe claim in the spec). **The math and the low-side ratchet are on-chain and
safe; the engine sizing was written, reported done, then failed a dedicated
post-implementation audit and was reverted.**

**On-chain now (safe, but unused by the engine):**

1. `src/libraries/StructuralLeverage.sol` — the pure math, BOTH sides. Long: 8 unit tests pin
   the March-2020 survival case, May-2021, the post-halving flip, and genesis = flat φ.
   Short (added 2026-07-22): 11 unit tests pin the owner-verified window/post-pivot numbers,
   monotone de-levering, the sub-1× deep entry, the +99 % 2018 rally survival, and all
   refusal/genesis fallbacks. (Survival is a property of the **math**; it is realized only if
   the engine posts `margin = notional/L`, which it does not yet — see below.)
2. `B4Pool.sampleAnchor` / `anchors` — a permissionless, sampling-only min-ratchet over the
   62-window and the post-halving window, per directional asset; 7 tests. More sampling lowers
   the anchor (⇒ lower leverage), so it depends on a keeper sampling each window. The
   symmetric max-ratchet (peak-window highs) is specified in §7b and is part of the redo.

**Reverted (was `B4VaultEngine._planPerpStep`):** the engine currently sizes leveraged perps at
flat `φ`, not structurally. The [2026-07-21 adversarial audit](AUDIT-2026-07-structural-leverage.md)
(46 agents, 10 confirmed findings) found two blocking defects in the wiring:

- **C6 (Critical) — the safety half was never implemented.** The engine kept the flat reserve
  `margin = notional·φ/maxLev` and only amplified position *size*. The structural stop was never
  realized; `stopWad` was dead code. A bigger position at the same ~4 %-away liquidation — worse
  than not shipping. The proposal's own mandated regression ("stop realized by margin") was never
  written; the shipped `StructuralSizing.t.sol` pre-loaded margin and asserted only order size.
- **C1/C4 (Critical) — held position detonates at the halving.** `_perpMultiplier` read live
  anchors while the sizing price was frozen; at the halving flip a permissionless `sampleAnchor`
  collapsed the delta and leverage exploded ~25×, force-buying into the held position →
  near-instant liquidation of the reserve.

Also confirmed: C5 (refusal `p ≤ floor` mapped to flat `g` instead of the un-leveraged spot leg),
C7 ("whole deposit deployed" absent — USDC deposits sit idle, dir-only Pro Max runs unlevered
silently), C9/C10 (demo errors, since fixed). The audit record lists all 10 plus 5 uncovered
surfaces the critic flagged and pre-registers the attack surface for the redo.

**Next round (not started):** the full symmetric mechanism — `margin = notional/L` on both
sides, whole deposit deployed, sizing price captured *with* its anchors and both frozen,
refusal → spot-only (long) / flat base (short), the high-side ratchet, plus the mandated
regressions: a test suite that crosses a halving with a held position, samples anchors
mid-hold, and checks the venue liquidation against `stopWad`/`shortStopWad`.
Design-before-code, then a fresh adversarial pass. Until then the engine sizes flat-`φ` and
the leverage figures in the demo and docs are the design target, labelled as such.
