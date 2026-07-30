# Static analysis — Slither triage

Tool: `slither-analyzer` 0.11.4 (Foundry compilation), run over `src/` only
(`--filter-paths "test/|lib/|script/" --exclude-dependencies`). Reproduce:

```bash
python3 -m venv .slither-venv && . .slither-venv/bin/activate
pip install slither-analyzer
slither . --foundry-out-directory out --filter-paths "test/|lib/|script/" \
  --exclude-dependencies --checklist --markdown-root . > slither-report.md
```

Result policy: `slither . --fail-high` must exit 0. Exact contract/detector/result counts are
release artifacts and MUST be regenerated after every source change; do not treat an old count
as current evidence. **No accepted high-severity detector finding is carried as waived debt** —
each high result must be triaged as a false positive or fixed. Two Medium reentrancy
detectors were eliminated by adding checks-effects-interactions ordering (defense-in-depth
beyond the existing guards); one Low was fixed with a zero-check. Regenerate the full report
with the command above. (The V3/V4 gas-cap and keeper-isolation hardening account for the
current informational deltas: `too-many-digits` fires on the two `500000` literals in
`SafeTransfer._call` plus the two immutable EIP-1167 creator modules —
`B4Pool._safeBalanceOf` uses the named constant `TOKEN_READ_GAS`, so it does not fire;
`uninitialized-local` includes intentionally zero-initialized structs/counters in
`B4VaultOps`, `Keeper`, `B4FactoryVaultCreator`, and `B4Pool`; `Keeper.crank`'s cyclomatic
complexity rose with its per-step try/catch isolation — all style/informational, unchanged
in security class.)

## High impact — all false positives (verified)

| Detector | Where | Disposition |
|---|---|---|
| `controlled-delegatecall` | `B4Vault._delegate` | **FP.** The target `ops` is an immutable set at construction; `data` is never caller-supplied — it is always built internally via `abi.encodeCall(B4VaultOps.opsX, …)` in the vault's own settle/exit/recovery functions. No attacker controls the selector or target. A zero-check on `ops` was added at construction (`ZeroOps`). |
| `incorrect-exp` (`(3 * d) ^ 2`) | `Phi.mulDiv` | **FP / intentional.** This is the canonical Remco Bloemen / OZ `mulDiv` Newton-iteration seed, where `^` is deliberately XOR (yields the modular inverse correct to 4 bits, then 6 doublings). `mulDiv` is fuzz-proven exact against native `(a*b)/d` across the full range (`testFuzz_mulDiv_matchesNative`, `_cancellation`, `_floorIdentity`). |
| `uninitialized-state` (`pool`, `owner`, `oracle`, `_dir`, `_usdc`, `slippageBps`, `growthTarget`, `fallTarget`, `_initialized`, …) | `B4VaultStorage` used by `B4VaultOps` | **FP (delegatecall proxy).** Slither analyzes `B4VaultOps` in isolation, where these vars are never written. They ARE written by `B4Vault.initialize()`, which shares the same storage layout via delegatecall (the module split exists for EIP-170). Covered by the full init/lifecycle test suite. |

## Medium impact — false positives / intentional (2 fixed)

| Detector | Where | Disposition |
|---|---|---|
| `reentrancy-no-eth` | `opsSettle`, `_finalizeExit` | **Fixed (defense-in-depth).** Both were already unreachable for reentry — every `B4VaultOps` entry is reached only through a `nonReentrant` `B4Vault` entrypoint (`crank`/`settle`/`recover*`), which Slither can't see across the delegatecall dispatch. Reordered to checks-effects-interactions anyway (ledger writes / `lastSettledPlusOne` before the external `pool.capture()` / `reportWeight`); behavior-identical (the moved writes are independent of the transfer results), and the detector no longer fires. |
| `divide-before-multiply` | `Phi.mulDiv`, `_lotsToSz8` | **FP / intentional.** In `mulDiv` the `/twos` and modular-inverse steps are exact bit operations (fuzz-proven). In `_lotsToSz8`, `maxLots = uint64.max/scale` then `maxLots*scale` is deliberately the largest multiple of `scale` ≤ uint64.max — the intended clamp ceiling. |
| `incorrect-equality` | `_verifyIntent` (enum `==`), `_planPerpStep` (`szi == 0`) | **FP / intentional.** Enum comparisons are exact; the raw `szi == 0` checks are the mandated strict custody flatness (HAZARDS A10 — must be exactly zero, never an epsilon). |
| `uninitialized-local` | Zero-initialized structs/counters in `_finalizeExit`, `Keeper.crank`, `B4FactoryVaultCreator.createVault`, `sampleAnchor`, `_quantizePx8` | **Intentional.** Solidity's zero initialization is used as a fail-safe default: free exits keep `poolWad = 0`; caught keeper reads leave `reportable = false`; the vault-init struct is filled before use; `kind`/`digits` are assigned on every reachable continuation. |
| `unused-return` | `HalvingProver.publish` receipt, partial tuple destructures, initial sleeve `crank()` | **Intentional.** Delivery is idempotent by height; ignored tuple fields are not needed; `foldPenalty` deliberately attempts the first permissionless crank but does not require synchronous progress. |

## Low / Informational — triaged

| Detector | Disposition |
|---|---|
| `missing-zero-check` (factory/oracle/implementation/init params, prover/oracle delegates) | Set once by the deployment path or immutable factory flow. Invalid oracle/bootstrap state now fails closed at pool creation (`OracleNotBootstrapped`); invalid descriptors fail at binding; a zero implementation fails atomically on clone/init. The one silent delegatecall-target case — `B4Vault.ops` — reverts `ZeroOps`. |
| `locked-ether` (`HalvingOracle` payable `lzReceive`, no withdraw) | Intentional: `lzReceive` must be `payable` per the LayerZero V2 receiver interface; the endpoint sends no value for the fact message, and the oracle never holds user funds. Adding an ether-withdraw would introduce a privileged mover, contradicting F1 (no privileged transfer). Force-sent ether is a griefer burning their own funds — no protocol impact. |
| `reentrancy-benign` / `reentrancy-events` | State-changing public pool/vault paths are guarded or use immutable/self-controlled callees; flagged post-call capture/event sites do not grant caller-selected recipients or repeatable credit. Covered by pool, sleeve, async, and invariant suites. |
| `missing-inheritance` (`B4Pool` vs local call-site interfaces) | Cosmetic. The interfaces are local consumer views; ABI compatibility is exercised by integration tests and deliberately not coupled by inheritance. |
| `timestamp` | Intended: the deterministic calendar is a pure function of block time; halving acceptance uses no wall-clock window (HAZARDS E1). |
| `assembly`, `low-level-calls` | Intended: `Phi.mulDiv` 512-bit math and `SafeTransfer` return-data handling (return-bomb-safe) use assembly / low-level calls by design. |
| `calls-loop` | Loops are bounded by the pool's `MAX_DIRECTIONAL` whitelist (F2). |
| `too-many-digits`, `unindexed-event-address`, `cyclomatic-complexity`, `constable-states`, `unused-state`, `missing-inheritance` | Style/informational (φ WAD literals; the async engine's inherent complexity; proxy-pattern `constable`/`unused-state` false positives — the constants/vars are used and written by `B4Vault`). |

## CI enforcement

The gate is wired into CI: `.github/workflows/test.yml` runs `slither --fail-high` on every
push/PR, so any NEW high-severity finding fails the build. The triaged false positives above
are excluded via `slither.config.json` (`detectors_to_exclude`:
`controlled-delegatecall, incorrect-exp, uninitialized-state, constable-states, unused-state`).
Periodically run Slither WITHOUT that config and re-triage, so a genuinely new instance of an
excluded detector can't hide behind the proxy-pattern exclusions.

## Verdict

No high-severity finding survives triage. The static-analysis release gate (SECURITY_MODEL
§5: "reject high-severity findings; triage the rest") is satisfied for this run and enforced
in CI. The mandatory independent audit and funded-network gates remain outstanding.
