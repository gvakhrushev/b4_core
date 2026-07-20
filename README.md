# B4 — clean-room implementation

From-scratch implementation of the `b4-greenfield` specification package (HyperEVM +
HyperCore; Citrea-proven Bitcoin-halving fact over LayerZero; canonical USDC settlement).
No admin, no upgrade, no pause, no privileged fund mover.

**Status: pre-mainnet.** Independent audit and the funded network gates are mandatory
before any production use — see `REPORT.md`.

## Documents

- `ARCHITECTURE.md` — contract map, async discipline, all design decisions and the two
  spec-errata resolutions. Normative for this implementation (HAZARDS G3).
- `INVARIANTS.md` — traceability: SECURITY_MODEL §2 invariants → tests, with honest GAPs;
  TEST_PLAN §2–4 mandatory-regression checklist.
- `REPORT.md` — the consolidated security dossier: what is proven locally vs. what remains a
  funded release gate, and the full internal audit history (four adversarial rounds + the
  coverage-ledger sweep, with final dispositions). Each round's fixes carry a
  fail-before/pass-after regression in the suite.
- `SLITHER.md` — static-analysis triage (Slither), enforced in CI (`--fail-high`).

## Build & test

```bash
forge build          # clean
forge fmt --check    # clean
forge test           # full suite: unit + integration + invariant campaigns
FOUNDRY_PROFILE=deep forge test --match-path 'test/invariant/*'   # nightly deep profile
```

Static analysis (release gate): Slither has been run and triaged — see `SLITHER.md` (no
real high-severity finding). Reproduce with the venv commands at the top of that file.

## Layout

```
src/
  core/       HalvingOracle, B4Factory, B4Pool, B4Vault(+Storage/Engine/Ops)
  venue/      HyperCore types, precompile readers, CoreWriter encoding, descriptors
  libraries/  Phi (fixed-point + constants), Calendar, BtcHeader, SafeTransfer
  periphery/  Keeper (cranks every step), reference strategies (Mini/B4/Pro/ProMax)
  citrea/     HalvingProver (source-chain publisher)
test/
  unit/       per-hazard regressions (TEST_PLAN §2–4) and component tests
  integration/ full product-ladder lifecycle through a whole cycle
  invariant/  stateful campaigns over SECURITY_MODEL §2
  mocks/      adversarial HyperCore mock (exact-ABI shims etched at precompile addresses)
script/     deployment wiring (ops → implementation → factory), funded-gate checklist
```
