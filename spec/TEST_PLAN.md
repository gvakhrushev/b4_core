# B4 — test & verification plan

The verification bar the fresh implementation MUST meet. Emphasis reflects where the earlier
version's bugs actually lived: the asynchronous state machine and its state-gate interactions
— not the fund-accounting core. Several of these regressions correspond to bugs that survived
multiple independent audit rounds; they are mandatory from day one.

## 1. Layers

- **Unit** — libraries (fixed-point/mulDiv with fuzz across the full range, calendar geometry,
  fee math), the halving-fact verifier, safe-transfer.
- **Integration** — full product lifecycles (Mini/B4/Pro/Pro Max: create → deposit → sync
  through all zone transitions → settle → exit), multi-vault independence, fee routing.
- **Venue state-machine** — drive the async engine against **simulated venue precompiles**
  (mock every read; exact-calldata match). Cover every leg and every intent, happy and
  adversarial.
- **Stateful invariant campaigns** — assert every invariant in `SECURITY_MODEL.md §2` as a
  fuzzed campaign (high runs × depth), with handlers that respect the state machine so they
  make forward progress. A nightly deep profile.
- **Static analysis** — reject high-severity findings; triage the rest.

## 2. Mandatory async regressions (each fail-before/pass-after + an adversarial check)

These encode the exact traps of `HAZARDS.md`:

1. **Reliable-balance completion (A2).** For every transfer leg, completion keys on the Core
   spot balance, never the perp `withdrawable`. Test: `perp→spot` release **completes while
   the perp `withdrawable` drifts adversely** (PnL) or is externally topped up — it must not
   freeze; and `spot→perp`/`spot→EVM` complete on a spot net-decrease despite a small external
   spot top-up.
2. **Exact-complement resend (A3).** A sub-`amount` external top-up MUST NOT block the resend of
   a genuinely dropped transfer; a merely delayed action MUST NOT be double-applied.
3. **Harvest-quota deadlock (A4/A5).** Record a harvest quota, then drive the open residual's
   `withdrawable` **below** the quota (adverse move). Harvest MUST clamp to the available
   amount, clear the quota, and leave the vault operable — NOT revert into a permanent freeze.
   Include the `withdrawable == 0` (liquidation) sub-case.
4. **Emergency recovery vs. discard (A6).** A stuck surplus-recovery intent can be abandoned
   after the timeout (funds stay on Core, re-recoverable); an in-flight asset-transfer intent
   can NOT be discarded.
5. **Strict custody flatness (A10).** On a fine-lot market, a sub-epsilon residual position MUST
   block margin return / exit (raw `szi == 0` required), and a full reduce must be able to
   drive to raw zero.
6. **Surplus recovery, spot AND perp (B6).** Bounded to `balance − recorded`, flat/idle,
   no accounting callback; recover with zero recorded principal; abandon on both phases of a
   two-phase perp→spot→EVM recovery.
7. **External top-up == amount and > amount (A11).** Confirm the residual is bounded,
   non-freeze, non-theft, and the excess is recoverable — never an over-credit.
8. **Realized-loss reconciliation (B2).** Settle over an unreconciled Core loss MUST NOT
   over-report weight/fee — reconciliation happens before valuation in settle, exit, AND sync.

## 3. Mandatory Pool / calendar / cross-chain regressions

9. **Checkpoint-price poisoning (D1).** A transient oracle zero on one asset MUST NOT
   permanently lock/brick the interval; a retry within the window succeeds once the oracle
   recovers.
10. **`balance ≥ liability` and order-independent socialization (D2/D3).** Fuzz distribute/
    sweep/capture across many keys and vaults.
11. **Halving acceptance (E1/E2).** Accept a **fast cycle** (interval well under nominal);
    reject a non-monotonic or future timestamp; **no wall-clock window**. Verify epoch-boundary
    interval-key continuity and genesis edges (no underflow).
12. **Cross-chain (E3).** Reject spoofed/mismatched facts; idempotent re-delivery; conflicting
    fact reverts; one-shot delegate removal.

## 3b. Mandatory policy / ledger regressions

13. **Equal-target no-trade / same-sign interpolation (`SPECIFICATION.md` §4).** A vault
    whose stored targets are EQUAL (Mini) MUST emit no venue action through all four
    transition sub-windows; a same-sign non-equal pair MUST follow the direct
    `growth→fall` interpolation (no synthetic zero) and rebalance accordingly. In both
    cases the performance fee still accrues on interval profit at settlement, paid in
    kind — a fee never forces a sale.
14. **Dust-exit weight minting (`SPECIFICATION.md` §9).** Repeated dust partial exits MUST
    NOT inflate reward weight: `nextRewardBase = (R + C·x)·(1−x)` with `C·x` the exiting
    share's client share. Include an adversarial run of many tiny exits.
15. **Exit-weight proportionality (`SPECIFICATION.md` §9, AUDIT-2026-07-29 F1).** Reported pool
    weight MUST scale by `keep` on every exit, not only at `keep == 0`. Required cases:
    `initiateExit(WAD − 1)` MUST leave a dust claim, not the full one; a 50% exit MUST leave
    exactly half; a split exit (three 80% steps) MUST compound multiplicatively rather than
    dodging; `totalWeight` MUST stay the exact sum of surviving `weightOf` entries; and an exit
    finalized past `reportDeadline` MUST leave weights untouched, since scaling is confined to
    the window in which `reportWeight` is allowed. No threshold variant is acceptable — a
    boundary test on an owner-chosen number is defeated by sitting one wei above it, and a
    condition read from the post-exit BASE is defeated by the `C·x` profit re-inflation.
    (`AuditHalfB_ExitWeightOrder.t.sol`, `V6B_ExitFairness.t.sol` (iv).)
16. **Settlement valuation instant (`SPECIFICATION.md` §8, AUDIT-2026-07-29 F4).** The instant a
    vault's interval NAV is measured at MUST NOT be a settle caller's choice. Required cases: the
    owner captures at `pointTime` and a later front-runner settling at a trough MUST mint weight
    off the captured NAV, not off its own price (assert the settlement identity
    `entryAfter = nav − operatorCut` against the captured `nav`, so the test fails if the live
    price is used); a settle past `Calendar.SNAPSHOT_WINDOW` with nothing captured MUST revert
    `NavNotSnapshotted` rather than valuing two days from the point; the capture MUST be one-shot,
    refused even to the owner; the capture MUST be refused outside the window; reporting MUST still
    succeed anywhere up to `reportDeadline` once captured; and a single `settle` inside the window
    MUST still work with no separate call. The in-kind operator cut MUST be valued on the captured
    basis, not the live one. (`AuditF4_SettleValuationInstant.t.sol`.)
17. **Peak-anchor value binding (`SPECIFICATION.md` §7b, AUDIT-2026-07-25 M-3 +
    AUDIT-2026-07-29 F2).** The peak VALUE must be decidable by no single caller. Required
    cases, each fail-before: a squatter taking every daily density slot at a low MUST NOT
    suppress an honest observation of the true high in the same close window; an off-close print
    MUST NOT bind at all, however often it is spammed; a single AT-close print MUST be a
    candidate only, binding once a second distinct close-day reaches it; the sampling window's
    OPENING observation MUST carry no served value; and a corroborated high MUST survive later
    lower closes. Density counting and value binding MUST remain separate mechanisms — sharing
    one gate is what produced F2. (`AuditF2_PeakSlotSquat.t.sol`, `AuditH4M3_Anchors.t.sol`.)

## 4. Access / griefing / init

15. Every permissionless entrypoint pays only the fixed owner / advances only legitimate state;
    no attacker-chosen recipient/direction; loops bounded.
16. Atomic factory init; one-shot re-init guards; no half-init; binding cannot precede init.
17. A rogue Pool/vault cannot interfere with a legitimate one.

## 5. What cannot be tested locally (must be funded — see `SECURITY_MODEL.md §5`)

Action atomicity and delayed-double-execution across a resend; fresh-account activation and
fee; reduce-only close to raw zero; real precompile gas; real linked-token decimals; production
LayerZero DVN delivery. Local suites use mocks and MUST mark these as funded gates rather than
claim them proven — the mock cannot faithfully reproduce venue timing/atomicity.

## 6. Process

- Each fix ships a fail-before/pass-after test **and** an independent adversarial attempt to
  refute the fix before it is called fixed (`HAZARDS.md` H1).
- Keep a traceability map: every invariant in `SECURITY_MODEL.md §2` → the tests asserting it,
  with honest GAP markers.
- Treat "looks clean" on the async surface as unproven. A permanent-freeze High survived three
  external audit rounds in the earlier version; budget a dedicated audit round for the async
  completion/retry, harvest-quota, and recovery paths.
