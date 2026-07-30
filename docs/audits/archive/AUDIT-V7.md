# AUDIT-V7 — adversarial fan-out on the V6-M-2 USDC-reclassification engine change

**Date:** 2026-07-22 · **Target:** the V6-M-2 fix (commit `58ccdb6`, `src/core/B4VaultEngine.sol`)
— `_reclassifyUsdc` / `_reclassifyUsdcEvm` and their wiring in `_planPerpStep` (rotated→margin, so
a short self-funds by selling spot) and `_planSpotStep` (margin→rotated, so the recovery rebuys).
**Method:** 7 finder lenses → 2 adversarial refuters per finding (refute-by-default) →
completeness critic. 18 agents.

## Verdict

**No Critical/High. Every finding is LOW and NAV-preserving** — no fund loss, no freeze, no
cross-vault impact; the reclassification only shifts value between the two sub-buckets of the
*same* USDC token, and their sum (hence NAV and the real Core balance) is conserved on every path.
Async completion (A2/A3/A7), storage layout, and strict-flatness are untouched. The fix does what
it set out to do — a BTC-only Pro/Pro Max opens its fall short by selling spot (`szi < 0`,
confirmed) — but it has real, bounded edges an owner should weigh before shipping.

## Findings

| # | Severity | Finding | Status |
|---|---|---|---|
| V7-1 | low (CI) | `EngineHarness`/`EngineHarnessAccess` (test-only, inherit the full engine) grew to 25,143 B — 567 B over EIP-170 — so `forge build --sizes` exits non-zero. Production `B4Vault` (24,239) / `B4VaultOps` (21,165) are unaffected; the harness is never deployed. | **FIXED** — CI size gate scoped to `--skip 'test/**' --skip 'script/**'`. |
| V7-2 | low | **Self-funded position sizes on post-carve `strategyValue`.** `notionalTarget = strategyValue·\|perpF\|`, and carving margin *out of* rotated USDC shrinks `strategyValue`, so the short/long settles at `≈ strategyValue·\|perpF\|·(1 − φ/maxLev)` and the carved margin is over-collateralized until the position closes. For the BTC perp (`maxLev = 40`) this is ~4 % undersize (minor); for a low-`maxLev` venue it grows (~54 % at `maxLev = 3`). NAV-neutral; capital returns at close. | open (decision) |
| V7-3 | low | **Mixed deposit can leak owner margin into strategy (B3 edge).** A single bucket holds both owner-deposited margin and BTC-carved margin. On a `BTC + USDC-margin` deposit, after the short closes and its margin repatriates to `usdcMarginEvm`, the recovery reverse-reclassify (`margin→rotated`) can pull the *owner's* margin into `strategyValue`, sizing the next perp on an inflated base — violating SPEC §5/B3 ("owner margin MUST NOT increase strategy notional"). NAV-preserving; isolated to the owner's own vault; only bites on a mixed deposit + fall→recovery sequence. | open (decision) |
| V7-4 | low | **Orphaned reclassify when the consuming intent no-ops.** The reclassify is followed by an intent that *can* no-op (sub-lot spot order, sub-USD6 margin, halted feed) while a sibling EVM `_startFund` reports progress — so the bucket move commits but is not consumed. On a fresh/headroom-blocked Core account *both* Core and EVM reclassify can commit with **no** intent created, and the step returns false: state changed, no progress (an A13 edge). NAV-neutral; worst case is delayed liveness (H3), self-healing on a later crank. | open (decision) |
| V7-5 | low | **Reverse reclassify is gated on bucket levels, not recovery context**, so in a growth regime it can siphon owner margin staged for a leveraged long into a spot buy, ping-ponging with the perp step's re-fund. Mixed-deposit + leveraged-long only; NAV-neutral. | open (decision) |

### Honest limitation (not a reclassify defect, but must be disclosed)

**Pro Max's growth-phase leverage does not engage under BTC-only funding.** A leveraged long
decomposes to `spot = 1` (100 % of equity in BTC) plus a perp long that needs margin *on top* —
which selling spot cannot provide (there is nothing left to sell). So a BTC-only Pro Max runs
**1× (unlevered) in the growth phase**; its `φ` edge comes from the fall short (funded by selling
spot) and the recovery long (funded by the closed short's returned margin). The benchmark numbers
already reflect this — they are the honest real-contract output — but the docs must not imply full
`φ` leverage throughout the cycle.

## The fork (owner decides)

All findings are low/NAV-safe, so this is not a must-revert. The choice:

- **(A) Keep + document.** Ship the fix as-is (short self-funds), disclose V7-2…V7-5 and the
  Pro Max growth-leverage limitation in the docs, and note the whole feature is `maxLev`-favourable
  (the undersize is negligible for BTC's `maxLev = 40`). Lowest effort; honest.
- **(B) Harden.** Track owner-deposited vs BTC-carved margin separately (a new sub-bucket or a
  provenance flag) so the self-funded short can size on the full capital (fixing V7-2) and owner
  margin can never enter strategy (fixing V7-3/V7-5); gate the reverse reclassify to a recovery
  context; guard the orphan (V7-4). This is a real engine change under EIP-170 pressure and would
  need its own re-audit.
- **(C) Revert.** Go back to requiring a separate margin deposit for shorts. Contradicts the owner's
  "sell BTC to stand up the short" model, so listed only for completeness.

## Killed findings (refuted)

- *"Pro Max recovery long never opens / docs contradict φ-leverage"* — refuted as a V6-M-2 defect:
  a levered long is not self-fundable by construction (its spot leg is already 100 %); the recovery
  long *does* fund from the closed short's returned margin. The genuine residual is the growth-phase
  limitation above and one doc mis-wording.
- *"USDC-only deposit gets no exposure"* — refuted as a V6-M-2 defect: the `v > 0` gate and
  margin-exclusion are pre-existing B3 invariants, identical with or without the reclassify helpers;
  the funds are valued at full NAV and fully returned on exit.
