# Claude Security results

Whole-repository scan of `/Users/grigorijvahrusev/Downloads/b4-greenfield` at medium effort, started 2026-07-29 14:03:07 UTC, no scope narrowing. The tree is not a git checkout, so the revision is recorded as `UNVERSIONED` — there is no commit hash pinning what was read, only the working tree as it stood at that moment. The target is the B4 protocol: a Solidity system of vaults, pools and a HyperCore/HyperEVM venue layer, driven by a permissionless keeper and a Bitcoin-halving oracle fed over LayerZero. Four findings survived verification: **three MEDIUM and one LOW**, all in the core vault/pool accounting rather than in the venue encoding, the header parsing, or the cross-chain message path. Nothing in this scan executed the repository's code — no tests were run, no exploit was fired, no proof-of-concept was validated. Every finding below is derived from reading the source.

## Coverage

Nine components were reviewed: `core-vault-factory` (`b4/src/core`), `venue-layer` (`b4/src/venue`), `libraries` (`b4/src/libraries`), `citrea-halving-prover` (`b4/src/citrea` plus `b4/src/core/HalvingOracle.sol`), `periphery-keeper` (`b4/src/periphery`), `interfaces` (`b4/src/interfaces`), `deploy-script` (`b4/script`), `tests` (`b4/test`), and `docs-and-spec` (`b4/docs`, `b4/spec`, and the four `b4/*.md` design documents). The whole tree was read — no attack-surface focus was applied, so tests, fixtures and scripts were audited as targets rather than treated as background. Thirty-seven researchers ran across the component × vulnerability-category matrix, at one researcher per cell, plus one breadth sweep over what the matrix did not cover.

Five areas were deliberately not examined, each for a stated reason:

- `b4/lib/forge-std` — vendored third-party Foundry standard library (git submodule), not project code.
- `b4/.slither-venv` — local Python virtualenv bundling the third-party slither tool and its pip dependencies, not project source.
- `b4/out`, `b4/cache` — generated Foundry build artifacts and cache, reproducible from `src/`.
- `b4/.git`, `b4/.gitmodules`, `b4/.gitignore`, `b4/.DS_Store`, `b4/src/.DS_Store` — VCS internals and OS metadata, not reviewable logic.
- `README.md` (repository root) — a pointer file with no code content.

The completeness check ran and passed: this is a whole-repository scan, and the tree's single top-level directory (`b4`) is accounted for — every part of it was either scanned or explicitly skipped above, with none left in neither ledger. That check covers top-level *directories*. It does not cover the loose markdown files at the repository root, and those are a real gap worth naming: `SPECIFICATION.md`, `REQUIREMENTS.md`, `SECURITY_MODEL.md`, `TEST_PLAN.md`, `HAZARDS.md`, `WHITEPAPER.md` and `FABLE_PROMPT.md` appear in neither ledger. Their `b4/spec/` counterparts were reviewed as part of `docs-and-spec`, but the root copies are not identical to them — `SPECIFICATION.md`, `SECURITY_MODEL.md`, `HAZARDS.md` and `WHITEPAPER.md` all differ from the `b4/spec/` versions that were read, and `FABLE_PROMPT.md` has no counterpart at all. These are documents, not compiled code, so nothing an attacker reaches depends on them; but if the root copies are the authoritative spec, the review measured the implementation against a different text than you may consider canonical.

No cap truncated anything: no components were dropped, no candidate buckets pruned, and every one of the 23 deduplicated candidates went before a full panel — none were left unverified. The run used the full component matrix; it did not collapse to the single-researcher shape.

## Findings

### F1 — Exit-weight forfeiture is gated on exact `keep == 0`, so `initiateExit(WAD - 1)` withdraws ~100% of a vault's capital while keeping its full reported pool weight (MEDIUM, confidence medium)

**Impact.** A vault that has exited its entire economic position keeps 100% of the weight it reported for the open interval, so `claimFor` still pays its owner `bucket * R / totalWeight` of a basket funded by other participants' exit penalties. Every vault that stayed is diluted by exactly that amount. This defeats the leaver-forfeits rule that AUDIT-2026-07-25 C-1 half B was added to enforce. Worse, both settlement points (t = P−H and t = T+H) fall inside `Calendar` transition zones, so `Calendar.freeExit` is true across the whole settle/report/claim span — the near-total exit can be taken with zero exit penalty as well.

**Where.** `b4/src/core/B4VaultOps.sol:302` in `_finalizeExit`

**What.** The exit share `x` is fully controlled by the vault owner through `B4Vault.initiateExit`, and the pool-side forfeiture of already-reported interval weight fires only on the exact boundary `keep == Phi.WAD - x == 0`. Passing `x = Phi.WAD - 1` drains essentially the whole vault through `_payBucket` while leaving `B4Pool._intervals[id].weightOf[vault]` and `totalWeight` untouched. Nothing between the payout and the forfeiture check scales the weight by how much actually left — it is a single equality test, so one wei of retained share buys the full claim.

**Exploit scenario.** Alice owns vault V in a pool whose basket has accumulated penalty inventory. At settlement point t = P−H someone calls `pool.lockPrices(N)`; Alice calls `V.settle(N)`, which reports weight `R = rewardBaseWad` to the pool (`it.weightOf[V] = R`, `it.totalWeight += R`). She then calls `V.initiateExit(Phi.WAD - 1)` rather than `Phi.WAD`. Permissionless cranks drive `_planExitStep` through to `_finalizeExit`, where `x = WAD-1` and `keep = 1`: `_payBucket` pays out `wmul(bucket, WAD-1)` — every unit but flooring dust — of `dirEvm`, `usdcRotatedEvm` and `usdcMarginEvm` to Alice, and because `keep != 0` the `forfeitWeight` branch at line 302 is skipped. t is still inside the OpeningFall transition zone, so `s.free` is true and no penalty is carved. Once `reportDeadline(N)` passes, Alice or any keeper calls `pool.claimFor(N, V)`; `w = R != 0`, so the full `bucket[i] * R / totalWeight` of every basket asset transfers to `V.owner()` — Alice — even though V now holds only dust. Had she passed `Phi.WAD`, `forfeitWeight` would have zeroed `weightOf[V]` and `totalWeight`, redistributing that share to the vaults that stayed.

**Preconditions.**
- Attacker owns a vault created through the factory and registered in the target pool (`B4Pool.isVault[vault] == true`).
- The vault has already called `settle(intervalId)` for the currently open interval, so `reportWeight` recorded weight `R` and `lastSettledPlusOne == intervalId + 1`.
- The exit finalizes before `reportDeadline(intervalId)` — the only window in which `forfeitWeight` would otherwise act.
- The interval basket holds inventory (other vaults' non-free exit penalties or donations captured into `accruing`).

**Fix.** Make the forfeiture proportional rather than boundary-triggered: reduce the pool-side reported weight by the exited fraction on *every* exit — e.g. a `forfeitWeightPartial(id, x)` doing `it.weightOf[msg.sender] -= wmul(w, x); it.totalWeight -= wmul(w, x);` — still confined to the pre-`reportDeadline` window and still a silent no-op on every non-applicable case, so it can never revert the crank-path exit. Substituting a dust threshold for `keep == 0` only moves the boundary and remains gameable.

**Verification.** 2/3 lens verifiers confirmed.

### F2 — Peak-anchor daily sample slot can be squatted, suppressing `peakC` and over-levering every structural short (MEDIUM, confidence medium)

**Impact.** Every honest sample inside the same 24-hour period is rejected while the attacker's own samples still increment `count` and extend `last - first`, so `peaks()` returns a **CONFIRMED but systematically suppressed** `peakC` — the density gate vouches for a value the market never printed. Since `shortStructStop` computes `stop = C + 0.618*(C - Pp)` and leverage is `p/(stop - p)`, a suppressed `C` pulls the stop toward the price and *raises* leverage — the exact anti-conservative direction the mechanism exists to prevent. Every Pro/Pro Max short vault and every pool-owned short sleeve on that asset is then sized with its venue liquidation inside a price range the market has already visited, so an ordinary bounce toward the real peak liquidates positions the structural stop was designed to survive.

**Where.** `b4/src/core/B4Pool.sol:461` in `sampleAnchor`

**What.** `sampleAnchor` is fully permissionless, and the peak value updates only when `_recordDistinctSample` returns true — at most once per `MIN_ANCHOR_SAMPLE_GAP` (one day), claimed by whoever calls first after `d.last + 1 day`. Binding the value ratchet to the same slot that counts confirmations means a caller who takes every daily slot at a price of their choosing controls the recorded `peakC`, which `B4VaultEngine._shortStopWad` feeds straight into `StructuralLeverage.shortStructStop`. The comment at lines 455-460 anticipates a missed peak as conservative, but not a *claimed* one that blocks the honest sample.

**Exploit scenario.** During the 20-day peak window the attacker calls `sampleAnchor(i)` once per day, each time at an intraday low — or simply front-runs the keeper's daily crank by a few seconds. `_recordDistinctSample` returns true for the attacker and false for every honest caller that day, so `a.peakC` ends the window as the maximum of the attacker's chosen daily lows rather than the window's true maximum. When the pool enters the Fall zone, `_shortStopWad` reads the confirmed-but-suppressed `peakC`. With prevPeak 69k, a true peak of 110k suppressed to 90k and entry at 80k, the structural stop moves from 135.3k to 103k and the sized leverage from ~1.45x to ~3.5x; a retest of the real 110k peak then liquidates the position. Cost to the attacker: roughly 20 transactions, once per ~4-year cycle.

**Preconditions.**
- The pool is in the peak window `[P-W, P)` of an epoch and the asset has a Pro / Pro Max (perp-short) product.
- Attacker sends one transaction per day for the ~20-day window, timed just after the previous `d.last`.
- Attacker can observe `d.last` — their own transaction timestamps plus the `PeakSampled` events suffice.

**Fix.** Decouple the value ratchet from the density counter on the peak side, mirroring the low side: let `a.peakC = max(a.peakC, pxp)` on every in-window observation, so an honest caller can always record a genuine high, and keep `_recordDistinctSample` purely as the confirmation counter. If daily-cadence value binding must be kept to block the M-3 wick attack, take the peak from a manipulation-resistant reference (a TWAP or oracle price) rather than the instantaneous `spotPx` at a caller-chosen instant, and/or allow more than one counted observation per day so a single squatter cannot monopolise the slot.

**Verification.** 2/3 lens verifiers confirmed.

### F3 — Permissionless `claimDeferred` races an in-flight Core→EVM return leg and permanently wedges the vault (MEDIUM, confidence medium)

**Impact.** The `ReturnDir`/`ReturnUsdc` intent can neither complete (`received < evmNeeded`) nor resend (`decreased == true` disables the resend branch), and `emergencyClearRecovery` explicitly refuses non-`Recover*` kinds. With a pending intent, `crank()` only re-runs `_verifyIntent()`, and every idle-gated entrypoint — `settle`, exit finalize, and all three owner recovery paths — reverts on `_requireIdle()`. The vault is frozen with capital split across Core and EVM and no admin able to unstick it. The only repair is for someone to gift at least `amount` of the token directly to the vault so `_unaccountedEvm` recovers — undocumented, and not reachable from `B4Pool` for a pool-owned sleeve.

**Where.** `b4/src/core/B4VaultRecovery.sol:41` in `opsClaimDeferred`

**What.** `B4Vault.claimDeferred` is permissionless and carries no `_requireIdle()` guard, yet `opsClaimDeferred` lowers the vault's EVM token balance without lowering `booked` in `_unaccountedEvm` — the exact delta `_verifyReturn` uses as its A2 receipt proof. Any caller can therefore make a live return leg unable to ever satisfy its completion condition. Note this does not need an attacker: the bundled `Keeper.crank` reaches `crankVault` and then `retryDeferred` on the same vault in one transaction, so an honest keeper can trip it.

**Exploit scenario.** A vault settles an interval and the operator-cut transfer to a USDC-blacklisted operator fails, leaving `deferredPayout[operator][USDC] = A`. Later the operator is un-blacklisted. On the next crank the planner repatriates Core USDC: `_startReturn(false, ...)` snapshots `intent.snapEvm = _unaccountedEvm(USDC, false)`, which counts `A` as unaccounted, and emits the `spotSend`. HyperCore debits Core spot (so `decreased` becomes true) and delivers `evmNeeded` to the vault. Before the next verification, any caller — or `Keeper._retryDeferred` in that very crank transaction — calls `claimDeferred(operator, USDC)`, sending `A` out of the vault. From then on `un = snapEvm + evmNeeded - A`, so `received = evmNeeded - A < evmNeeded`, and `_verifyReturn` returns false on every future crank while the resend branch stays disabled. Every subsequent `crank`, `settle`, exit finalization and recovery call on that vault fails permanently.

**Preconditions.**
- A non-zero `deferredPayout[recipient][token]` exists for one of the two accounted tokens — a prior settle or exit-finalize payout whose ERC20 transfer failed, e.g. a USDC-blacklisted operator or referrer.
- That transfer now succeeds, so `opsClaimDeferred` does not revert.
- A `ReturnDir` or `ReturnUsdc` intent is live and its Core source has already decreased (`decreased == true`).
- `claimDeferred` lands after `intent.snapEvm` was taken and before the leg is verified.

**Fix.** Subtract `deferredPayoutTotal[token]` inside `_unaccountedEvm` (`b4/src/core/B4VaultEngine.sol:398-402`) so the measure only ever counts value the vault does not owe, and/or add `_requireIdle()` to `opsClaimDeferred`. The docstring at `B4VaultEngine.sol:391-393` — asserting that `deferredPayoutTotal` "changes only inside settle / exit-finalize, both of which require an idle engine" — is factually wrong for the permissionless `claimDeferred` path and should be corrected alongside the fix. Consider also giving `ReturnDir`/`ReturnUsdc` a bounded self-heal (re-deriving `snapEvm` against the live `deferredPayoutTotal`) so no single balance perturbation can produce an unclearable intent.

**Verification.** 3/3 lens verifiers confirmed.

### F4 — Permissionless, one-shot `settle` lets a third party pin another vault's minted pool weight at a price trough (LOW, confidence medium)

**Impact.** An attacker fixes a victim's `rewardBaseWad` increment at a trough price, permanently reducing the weight that vault reports for the interval and therefore its share of that interval's reward basket — which is redistributed to the remaining claimants, including the attacker's own vault. Symmetrically, the attacker settles their own vault at the window's peak; because `profit` is floored at zero, a high anchor is cumulatively never worse than a low one. The mitigation the `Calendar` docstring relies on for `lockPrices` — "the harmed party can simply call lockPrices at pointTime and remove all discretion" — no longer applies: since the C-1 remediation the locked price feeds no valuation, and the discretion moved to `settle`, where the harmed party cannot pre-empt a front-runner. Bounded and partly self-correcting through the chained entry ledger, hence LOW.

**Where.** `b4/src/core/B4Vault.sol:217` in `settle`

**What.** `settle` has no caller restriction, and `opsSettle` values NAV at `_livePxWad()` — the price at the instant the call lands — while `lastSettledPlusOne` makes the interval one-shot. Any third party therefore chooses the valuation instant for a vault they do not own, and the victim cannot re-settle that interval afterwards.

**Exploit scenario.** The attacker runs a vault in the same pool. When the interval locks they watch the directional spot price; at a local trough they call `settle(N)` on every other vault in the pool. Each victim's `lastSettledPlusOne` advances to N+1 and `reportWeight(N, rewardBase)` records a minimised weight, and none of them can settle N again. At a local peak the attacker calls `settle(N)` on their own vault, with `route.operatorBps = 0` so no in-kind cut is taken, maximising their own `rewardBaseWad`. After `reportDeadline(N)`, their inflated share of `totalWeight` yields a larger `claimFor` payout from the shared basket.

**Preconditions.**
- The target vault is idle, has a locked interval open, and satisfies the wrong-sign / `FeeNotRepatriated` gates.
- The attacker calls `settle` before the vault owner or an honest keeper does — a roughly 3-day report window is available.
- The directional price moves materially within the report window.

**Fix.** Remove the caller's discretion over the valuation instant. Either value the interval at its locked checkpoint price, restoring `lockPrices` as the canonical and owner-preemptable basis, or reserve `settle` for the vault owner during the first portion of the report window and open it to keepers only near the deadline — so a third party can supply liveness but cannot choose the price.

**Verification.** 3/3 lens verifiers confirmed.

## What was verified

The scan partitioned the tree into nine components, threat-modelled each, and hunted with 37 researchers across the component × category matrix plus one breadth sweep. That produced 28 raw candidates, deduplicated to 23. Each of the 23 then faced an independent three-lens adversarial panel — 69 verifier votes in total, cast by agents that did not see the researcher's reasoning and were tasked with refuting the claim. Four findings survived: F3 and F4 unanimously (3/3), F1 and F2 on a 2-of-3 majority. The 19 that failed were dropped, most of them unanimously. No candidate went unreviewed and no cap truncated the panel. The stamp's `verification.status` is recorded alongside this report in the revision stamp file; it is derived from the vote record itself, not asserted here.

Two calibration notes. The 2-of-3 findings (F1, F2) carry a dissenting verifier by construction — their confidence is capped at medium for that reason, and the dissent is a signal worth weighing when you triage, not noise. And scans are nondeterministic: running them regularly builds coverage over time. This complements SAST, dependency scanning, and human code review; it does not replace them.
