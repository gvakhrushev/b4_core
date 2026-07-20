# Security model

This page states, in reader-facing terms, what B4 trusts, what it refuses to trust, which safety properties it claims, and exactly which proofs are still missing — it is a summary of the normative [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md), not a replacement for it.

> **Status: pre-mainnet, externally unaudited.** Nothing here should be read as production-readiness. The mandatory independent audit and the funded on-chain release gates are both **outstanding** ([`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §5, [`REPORT.md`](../REPORT.md)).

## 1. What "security" means here

Security in B4 means preservation of **custody and accounting invariants** under untrusted callers, delayed (asynchronous) execution, and bounded external failures.

It does **not** mean the strategy avoids market loss, liquidation, token failure, or tax consequences. A vault can lose money while every security property below holds.

## 2. Trust model

### Trusted (B4 does not reproduce their security internally)

| Dependency | What is assumed |
|---|---|
| Execution chain + Core venue consensus | Correct consensus, precompile reads, CoreWriter action encoding, **and their live semantics** — action atomicity, account activation, gas |
| Canonical linked USDC | Issuer/admin behavior; Core↔EVM fungibility; `USDC = 1 USD` fixed, a depeg is undetected (decision C3) |
| Citrea Bitcoin light client | Its consensus and published block-hash view, read by `src/citrea/HalvingProver.sol` |
| LayerZero endpoint, message libraries, DVN stack | Delivery integrity for the halving fact received by `src/core/HalvingOracle.sol` |

A failure in any of these can halt execution, misprice, or cause loss.

### Untrusted — the protocol must stay custody-safe against

- the **operator** and the **keeper** (`src/periphery/Keeper.sol` is fully permissionless and holds no authority);
- the **halving submitter** and any relay caller;
- arbitrary callers of the permissionless entrypoints (`crank`, `settle`, `claimDeferred`, pool `advance`/`lockPrices`/`claimFor`/`sweep`/`capture`) — `reportWeight` is **not** among them: `B4Pool` accepts it only from a factory-registered vault (`NotAVault`), and a vault reports its own weight once per interval from inside `settle`;
- **direct EVM or Core token transfers** into a vault or its Core account — an external Core credit is a standard operation, not a "donation", and is treated adversarially in async completion (see [`spec/HAZARDS.md`](../spec/HAZARDS.md) A2/A11);
- a **mutable strategy contract after its targets are stored**: `B4Vault.selectPolicy` reads `IStrategy.targets()` **once** and writes `growthTarget`/`fallTarget` into storage, so a strategy that later changes its answer cannot move a vault that already resolved it. Reference strategies in `src/periphery/ReferenceStrategies.sol` (`StrategyMini`, `StrategyB4`, `StrategyPro`, `StrategyProMax`) are stateless contracts whose only function, `targets()`, is `external pure` and returns a constant `(growth, fall)` pair; they hold no authority over funds;
- the creator or owner of a **different** Pool or vault.

### Administrative boundary

There is **no** governance executor, **no** upgrade proxy, **no** pause, and **no** privileged fund mover. `B4Factory` holds no funds and has no owner; `createPool`/`createVault` are permissionless — a pool's existence is **not** an endorsement of its descriptors. Vault authority is limited to the fixed owner set at creation (`selectPolicy`, `deposit`, `initiateExit`, `recoverEvm`, `recoverCoreSpot`, `recoverPerpSurplus`, `emergencyClearRecovery`), none of which can direct funds to a third party.

The one temporary exception is the LayerZero-side configurator: each cross-chain contract has a `delegate` that must call the one-shot `renounceDelegate()` (`HalvingOracle.sol`, `HalvingProver.sol`) before production. Verifying that removal on-chain is a release gate, not a promise.

## 3. Safety invariants in plain language

The normative list is 18 numbered invariants in [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §2, each traced to concrete tests in [`INVARIANTS.md`](../INVARIANTS.md). The headline ones:

- **Isolation.** One execution identity belongs to exactly one vault; no vault can authorize movement from another vault's EVM or Core account; multiple vaults of one owner remain independent accounting domains.
- **Nothing is credited that was not measured.** Books grow only from an **actual received delta**, never a requested amount and never an unmeasured transfer. Donations and favorable overfills stay unaccounted and separately recoverable.
- **Emitting is not executing.** A CoreWriter action succeeding never finalizes accounting; a later Core state read must prove the effect. Completion keys only on a **self-moved (reliable)** balance — never on the PnL-driven, externally-toppable perp withdrawable — and every resend is the exact complement of the completion test. A Core→EVM completion requires both a Core debit and an EVM receipt.
- **No claim can outlive its escape.** A recorded harvest claim can never exceed what a single later call can settle, and no gate blocks the operation that would clear it.
- **Custody flatness is strict.** Any withdrawal with Core exposure first realizes a strictly-flat NAV (raw position size exactly zero, not "within epsilon") and returns all Core principal before proportional EVM payment. Owner margin stays separate from strategy capital.
- **Calendar integrity.** A derivative sign change always passes through a verified zero; a policy or scale change never invokes exit or penalty logic.
- **Pool discipline.** Pool liability increases only by actual receipt, `balance ≥ liability`, distribution never exceeds nominal liability, and loss socialization is order-independent.
- **Immutability of the route.** The operator/referral fee route cannot change after creation — no setter exists.
- **Bounded permissionless surface.** No permissionless entrypoint has an attacker-chosen recipient or direction, and no unbounded loop. The worst case of any async or gated path is **delayed liveness — self-healing by cranking — never a freeze and never loss** ([`spec/HAZARDS.md`](../spec/HAZARDS.md) H3).

## 4. Deliberate exclusions

These are **security boundaries, not dormant extension points** ([`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §4). B4 targets exactly one venue: HyperEVM + HyperCore.

- Funding/basis-carry strategies — out of scope by design; the calendar drives a single directional target pair.
- Arbitrary router callbacks.
- Protocol bridge custody.
- Rebasing, fee-on-transfer, or blacklistable **directional** assets (settlement USDC excepted — the payout path is pay-or-defer, so a blacklisted recipient delays rather than freezes).
- Governance, upgrade, or admin withdrawal.
- Automatic liquidation or insurance.
- Tax classification.
- Any guarantee about the quality of a permissionlessly created Pool.

## 5. Accepted residuals

Documented, decided, and not treated as bugs ([`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §3, [`spec/HAZARDS.md`](../spec/HAZARDS.md) §C, [`REPORT.md`](../REPORT.md)):

| Residual | Character |
|---|---|
| A `≥ amount` external top-up can fake a completion signal **once** | Attacker-funded, bounded, non-freeze/non-theft; leaves real assets ≥ books and is recoverable. Full closure needs a venue action receipt/nonce |
| Permanent bridge-credit loss (A8) | Stalls the affected vault's engine; an ecosystem-wide venue failure by assumption, not a B4-specific bug |
| `USDC = 1 USD` fixed, no depeg cross-check (C3); no oracle sanity band (C4) | Avoids a second trust dependency and a halt path; the execution price envelopes are the defense |
| Funding income untaxed while funding losses are borne (C1) | Documented economic asymmetry, not a safety defect |
| Exit-time reward weight valued at the live oracle (C2) | No mid-interval snapshot exists; accepted as economically inert under a deep venue |
| Wei-scale shortfall dust from per-claim flooring (RAW-B-002) | Bounded ≈1 unit per claim per token, protocol-favoring |
| Operator fee at settle payable only from the EVM basket | Paid in kind, and only from the accounted EVM basket. A vault whose value still sits on Core cannot settle at all — `settle` reverts `FeeNotRepatriated` until it repatriates (V3-ACCT-1), so a vault left uncranked past its report window makes that interval unreportable: delayed liveness, never custody or a waived fee. At exit-finalize the payment is instead carved proportionally in kind from the exiting share, which is reached only after all Core principal has returned |
| Market association (token ↔ perp) | No canonical on-chain statement exists; the immutable descriptor asserts it and **the user must verify it** |
| Liquidity / liquidation | IOC orders may fill partially or not at all; the `1/φ` reserve is a margin, not liquidation protection |

## 6. Audit posture

**What has happened** (full history in [`REPORT.md`](../REPORT.md)):

- **Four internal adversarial rounds** — a first-principles round (12 bug-class finders), a post-build multi-agent audit, the deep **V3** round (5 parallel workstreams + independent adjudication: 4 Medium, 6 Low, 8 Informational, no Critical/High), and a **V4** post-remediation re-audit that **refuted two of the V3 fixes as incomplete** (V4-ENG-1 fund-headroom overflow, V4-VENUE-1 codeless-vault keeper isolation) — both now fixed and independently re-verified.
- A separate 19-agent coverage sweep returned zero findings on the same tree in which V4 later found a genuine Medium. The repo records this explicitly: **"looks clean" is not "is clean"**.
- Every confirmed defect carries a **fail-before / pass-after regression**, plus an independent adversarial attempt to break the fix (H1). All 18 §2 invariants are traced to tests, with honest **GAP** markers where the property is venue semantics rather than locally provable ([`INVARIANTS.md`](../INVARIANTS.md)).
- **Static analysis in CI**: `slither --fail-high` runs on every push/PR; the last recorded run was 30 contracts / 95 detectors / 131 results, exit 0, with every high-severity result triaged as a verified false positive ([`SLITHER.md`](../SLITHER.md)).

**What has NOT happened, and is mandatory:**

1. An **independent external audit** — with a dedicated round on the async completion/retry, harvest-quota and recovery paths. That is the class in which the prior build's permanent-freeze High survived three audit rounds, and the class in which V4-ENG-1 still surfaced after three internal rounds.
2. The **funded network gates** ([`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §5) — 15 items that no local test can prove, including CoreWriter action atomicity and no delayed double-execution across a resend, fresh-account activation and its fee, reduce-only close to raw `szi == 0`, canonical USDC identity and both class-transfer directions, spot/perp scaling and encoding, light-client publication plus LayerZero delivery with production libraries/DVNs, permanent delegate removal, reproducible-build bytecode equality, and precompile gas calibration.

Mainnet must not proceed until both are recorded and independently reviewed.

## 7. Where to read further

| Document | Content |
|---|---|
| [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) | Normative trust model, the 18 safety invariants, accepted residuals, release gates |
| [`spec/HAZARDS.md`](../spec/HAZARDS.md) | The hazard map: every failure class (A async, B accounting, C economic decisions, D pool, E calendar/cross-chain, F authority, G operations, H process) as a design requirement with rationale |
| [`INVARIANTS.md`](../INVARIANTS.md) | Invariant → test traceability with explicit GAP markers |
| [`REPORT.md`](../REPORT.md) | Security dossier and audit history: rounds, findings, refutations, remediation, what remains unproven |
| [`SLITHER.md`](../SLITHER.md) | Per-detector static-analysis triage and the CI gate |
