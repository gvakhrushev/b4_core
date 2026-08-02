# Security model

This page states, in reader-facing terms, what B4 trusts, what it refuses to trust, which safety properties it claims, and exactly which proofs are still missing — it is a summary of the normative [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md), not a replacement for it.

> **Status: pre-mainnet, externally unaudited.** Nothing here should be read as production-readiness. The mandatory independent audit and the funded on-chain release gates are both **outstanding** ([`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §5, [`docs/audits/REGISTRY.md`](audits/REGISTRY.md)).

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
- arbitrary callers of the permissionless entrypoints (`crank`, `snapshotNav`, `settle`, `claimDeferred`, pool `advance`/`lockPrices`/`claimFor`/`sweep`/`capture`/`sampleAnchor`, and in a strict Product Pool `foldPenalty`/`initiateSleeveExit`/`crankSleeve`) — `reportWeight`, `scaleWeight`, `beginPenalty` and `capturePenalty` are **not** among them: `B4Pool` accepts each only from a factory-registered vault (`NotAVault`), and a vault reports its own weight once per interval from inside `settle`. A caller of a permissionless step chooses only *when* it runs, never what it does — see the crank-timing residual in §5;
- **direct EVM or Core token transfers** into a vault or its Core account — an external Core credit is a standard operation, not a "donation", and is treated adversarially in async completion (see [`spec/HAZARDS.md`](../spec/HAZARDS.md) A2/A11);
- a **mutable strategy contract after its targets are stored**: `B4Vault.selectPolicy` reads `IStrategy.targets()` **once** and writes `growthTarget`/`fallTarget` into storage, so a strategy that later changes its answer cannot move a vault that already resolved it. Reference strategies in `src/periphery/ReferenceStrategies.sol` (`StrategyMini`, `StrategyB4`, `StrategyPro`, `StrategyProMax`) are stateless contracts whose only function, `targets()`, is `external pure` and returns a constant `(growth, fall)` pair; they hold no authority over funds;
- the creator or owner of a **different** Pool or vault.

### Administrative boundary

There is **no** governance executor, **no** upgrade proxy, **no** pause, and **no** privileged fund mover. `B4Factory` holds no funds and has no owner; `createPool`/`createVault` are permissionless — a pool's existence is **not** an endorsement of its descriptors. Vault authority is limited to the fixed owner set at creation (`selectPolicy`, `deposit`, `initiateExit`, `recoverEvm`, `recoverCoreSpot`, `recoverPerpSurplus`, `emergencyClearRecovery`), none of which can direct funds to a third party.

The one temporary exception is the LayerZero-side configurator: each cross-chain contract has a `delegate` that must call the one-shot `renounceDelegate()` (`HalvingOracle.sol`, `HalvingProver.sol`) before production. Verifying that removal on-chain is a release gate, not a promise.

## 3. Safety invariants in plain language

The normative list is 19 numbered invariants in [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §2, each traced to concrete tests in [`INVARIANTS.md`](../INVARIANTS.md) — which carries 22 rows: rows 1–18 map to §2 1–18; rows 19–21 (weight integrity, zero-price handling, full-exit forfeiture) were added by the 2026-07-25 audit round and are traced there before being renumbered into §2; and §2's own 19th invariant, strict Product Pool penalty routing, is row 22. The headline ones:

- **Isolation.** One execution identity belongs to exactly one vault; no vault can authorize movement from another vault's EVM or Core account; multiple vaults of one owner remain independent accounting domains.
- **Nothing is credited that was not measured.** Books grow only from an **actual received delta**, never a requested amount and never an unmeasured transfer. Donations and favorable overfills stay unaccounted and separately recoverable.
- **Emitting is not executing.** A CoreWriter action succeeding never finalizes accounting; a later Core state read must prove the effect. Completion keys only on a **self-moved (reliable)** balance — never on the PnL-driven, externally-toppable perp withdrawable — and every resend is the exact complement of the completion test. A Core→EVM completion requires both a Core debit and an EVM receipt.
- **No claim can outlive its escape.** A recorded harvest claim can never exceed what a single later call can settle, and no gate blocks the operation that would clear it.
- **Custody flatness is strict.** Any withdrawal with Core exposure first realizes a strictly-flat NAV (raw position size exactly zero, not "within epsilon") and returns all Core principal before proportional EVM payment. Owner margin stays separate from strategy capital.
- **Calendar integrity.** A derivative sign change always passes through a verified zero; a policy or scale change never invokes exit or penalty logic.
- **Pool discipline.** Pool liability increases only by actual receipt, `balance ≥ liability`, distribution never exceeds nominal liability, and loss socialization is order-independent. In a strict Product Pool a non-free exit's penalty is held in a **second book** (`escrowHeld`/`penaltyEscrow`) that is excluded from liability and from the shortfall balance, so a live sleeve can never haircut an unrelated claim: the invariant there is `balance ≥ liability + escrowHeld` ([`spec/HAZARDS.md`](../spec/HAZARDS.md) D6). A penalty is attributed to the exit that measurably delivered it, and can only fund that vault's own write-once `(product, directional asset)` sleeve (D7).
- **Leaving means leaving.** A vault that exits in full holds no standing reward base and no reported pool weight — the vault-side base is zeroed and the pool-side weight is forfeited — so both call orders (settle-then-exit, exit-then-settle) agree. The shared basket is funded by leavers for the benefit of stayers.
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

Documented, decided, and not treated as bugs ([`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §3, [`spec/HAZARDS.md`](../spec/HAZARDS.md) §C, [`docs/audits/REGISTRY.md`](audits/REGISTRY.md)):

| Residual | Character |
|---|---|
| A `≥ amount` external top-up can fake a completion signal **once** | Attacker-funded, bounded, non-freeze/non-theft; leaves real assets ≥ books and is recoverable. Full closure needs a venue action receipt/nonce |
| Permanent bridge-credit loss (A8) | Stalls the affected vault's engine; an ecosystem-wide venue failure by assumption, not a B4-specific bug |
| `USDC = 1 USD` fixed, no depeg cross-check (C3); no oracle sanity band (C4) | Avoids a second trust dependency and a halt path; the execution price envelopes are the defense |
| Funding income untaxed while funding losses are borne (C1) | Documented economic asymmetry, not a safety defect |
| Exit-time reward weight valued at the live oracle (C2) | No mid-interval snapshot exists; accepted as economically inert under a deep venue |
| **Settle-timing discretion** — since the C-1 fix, settlement values the vault at the price of the instant it runs (the only way the entry ledger and the NAV share one basis), so the permissionless `settle` has a caller-dependent outcome: two vaults on the same asset settling at different moments of the same window report different weight | Bounded to the **settlement day** (24h), once per interval, and pre-emptable by the vault owner. Mark-to-market on a real holding is real profit: the measured figure is always the vault's own P&L, so no weight is created by capital that did not earn it. Pro-rata distribution cancels a *uniform* shift, so only **differential** timing has any effect. A relative-weight fairness question, never a mint. Freezing the price is what produced C-1. The valuation instant is a separate one-shot act, `B4Vault.snapshotNav(id)`, confined to `Calendar.SNAPSHOT_WINDOW`: the owner takes it at `pointTime` and leaves a front-runner nothing to choose, while reporting keeps the full report window and the ordinary keeper path stays one `settle` call. **Do not bound this by asserting the keeper settles a pool in a single pass** — that is an operational expectation, not a code guarantee, and a permissionless one-shot `settle` lets a third party pre-empt the pass and make the shift differential deliberately. Remaining residual, LOW: inside that one day an un-pre-empted vault's instant is still whoever-calls-first, costing one interval's *increment* rather than the standing base. See `spec/SECURITY_MODEL.md` for the alternatives that measured worse — notably that any uniform valuation basis reopens C-1 at 83.3% of the basket, and that gating the *caller* instead of the instant hands each owner a repeatable unpreemptable slice |
| **Crank-timing MEV** — every order-emitting step is permissionless and prices off the live venue read, so its caller picks the block: the moment `foldPenalty` opens a leveraged product sleeve (which fixes that sleeve's effective leverage and liquidation price), and the moment any vault's IOC is emitted | The caller chooses only *when*. Target, market, direction, size rule, sleeve, recipient and fee route are all fixed by immutable descriptors, the calendar and the vault's own key; the crank pays its caller nothing, so any edge must be extracted on the venue against the execution envelope (spot ≤ 500 bps, perp 50 bps of mark). A leveraged size can only anchor on a density-confirmed structural anchor, never on the caller's own print, and the calendar target is a continuous ramp, so a differently-timed crank converges rather than losing exposure. Worst case is a worse fill or entry — market risk, never custody. Mitigation is competitive (an honest keeper on a schedule), not privileged: a privileged scheduler would violate the administrative boundary |
| Wei-scale shortfall dust from per-claim flooring (RAW-B-002) | Bounded ≈1 unit per claim per token, protocol-favoring |
| Operator fee at settle payable only from the EVM basket | Paid in kind, and only from the accounted EVM basket. A vault whose value still sits on Core cannot settle at all — `settle` reverts `FeeNotRepatriated` until it repatriates (V3-ACCT-1), so a vault left uncranked past its report window makes that interval unreportable: delayed liveness, never custody or a waived fee. At exit-finalize the payment is instead carved proportionally in kind from the exiting share, which is reached only after all Core principal has returned |
| Market association (token ↔ perp) | No canonical on-chain statement exists; the immutable descriptor asserts it and **the user must verify it** |
| Liquidity / liquidation | IOC orders may fill partially or not at all; the `1/φ` reserve is a margin, not liquidation protection |

## 6. Audit posture

**What has happened** (full history in [`docs/audits/REGISTRY.md`](audits/REGISTRY.md)):

- Multiple internal adversarial rounds through **V9** — including V3/V4 remediation re-audits, V6/V8 structural-leverage review, and the V9 density/engine closure. Historical round-by-round evidence remains under `docs/audits/`; current code carries focused regressions for every accepted fix.
- A full **12-dimension adversarial audit (2026-07-25)** with per-finding refutation and three-lens verification, and its fix round. It found a **Critical** the eight previous rounds missed: settlement valued the vault's composition *as read at settlement time* against a price fixed up to three days earlier, so any composition change inside that window — including the rotation the calendar itself mandates there — read as profit no capital earned and minted a claim on the shared basket (committed exploit: $676 of cost took $833,333). Fixed by putting the entry ledger and NAV on a single price basis. The round's own first remediation plan was refuted by measurement before it landed. See `docs/audits/REGISTRY.md`; four further fixes are blocked on an EIP-170 size restructure, not on design.
- A separate 19-agent coverage sweep returned zero findings on the same tree in which V4 later found a genuine Medium. The repo records this explicitly: **"looks clean" is not "is clean"**.
- Every confirmed defect carries a **fail-before / pass-after regression**, plus an independent adversarial attempt to break the fix (H1). All 19 §2 invariants are traced to tests, with honest **GAP** markers where the property is venue semantics rather than locally provable ([`INVARIANTS.md`](../INVARIANTS.md)).
- **Static analysis in CI**: `slither --fail-high` runs on every push/PR. `SLITHER.md` records detector-class triage; exact counts are regenerated per release rather than frozen in user-facing docs.

**What has NOT happened, and is mandatory:**

1. An **independent external audit** — with a dedicated round on the async completion/retry, harvest-quota and recovery paths. That is the class in which the prior build's permanent-freeze High survived three audit rounds, and the class in which V4-ENG-1 still surfaced after three internal rounds.
2. The **funded network gates** ([`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §5) — 15 items that no local test can prove, including CoreWriter action atomicity and no delayed double-execution across a resend, fresh-account activation and its fee, reduce-only close to raw `szi == 0`, canonical USDC identity and both class-transfer directions, spot/perp scaling and encoding, light-client publication plus LayerZero delivery with production libraries/DVNs, permanent delegate removal, reproducible-build bytecode equality, and precompile gas calibration.

Mainnet must not proceed until both are recorded and independently reviewed.

## 7. Where to read further

| Document | Content |
|---|---|
| [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) | Normative trust model, the 19 safety invariants, accepted residuals, release gates |
| [`spec/HAZARDS.md`](../spec/HAZARDS.md) | The hazard map: every failure class (A async, B accounting, C economic decisions, D pool, E calendar/cross-chain, F authority, G operations, H process) as a design requirement with rationale |
| [`INVARIANTS.md`](../INVARIANTS.md) | Invariant → test traceability with explicit GAP markers |
| [`docs/audits/REGISTRY.md`](audits/REGISTRY.md) | Security dossier and audit history: rounds, findings, refutations, remediation, what remains unproven |
| [`SLITHER.md`](audits/SLITHER.md) | Per-detector static-analysis triage and the CI gate |
