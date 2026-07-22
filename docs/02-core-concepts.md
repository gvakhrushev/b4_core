# Core concepts

The six ideas you need before reading any B4 contract: the deterministic calendar, the exposure equation, policy resolution, vault vs pool, asynchronous execution, and fees.

> Status: B4 is **pre-mainnet and not externally audited**. Venue semantics (CoreWriter action atomicity, account activation, precompile behavior) are not locally provable and are mandatory funded release gates — see [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §5. Nothing here implies production readiness.

Normative source: [`spec/SPECIFICATION.md`](../spec/SPECIFICATION.md). Code referenced below: `src/libraries/Calendar.sol`, `src/libraries/Phi.sol`, `src/core/B4Vault.sol`, `src/core/B4Pool.sol`, `src/periphery/ReferenceStrategies.sol`.

---

## 1. The deterministic calendar

Everything time-dependent in B4 is a pure function of one number:

```
t = block.timestamp − halvingTs
```

`halvingTs` is the timestamp of the latest **accepted** Bitcoin halving fact held by `HalvingOracle` (published from Citrea by `src/citrea/HalvingProver.sol`, delivered over LayerZero). A vault reads it through `IHalvingOracle.timeSinceHalving()`. Facts delivered after deployment are bound to their 80-byte header — re-hashed and their timestamp re-derived on the receiving side, then stored in `factHash[height]`. The *initial* value is different: a deploy-time genesis anchor `(genesisHeight, genesisTs)` asserted by the deployer, checked only for non-zero, `height % 210000 == 0` and not-in-future, and carrying **no** header hash (`factHash` stays 0 for it). Verifying that anchor is a deployment-review item, not something the code proves.

No keeper, operator or vault owner can move the calendar: acceptance requires exactly `halvingHeight + 210000`, a strictly monotonic and non-future header timestamp, and there is no wall-clock window that could stall it. One residual administrative boundary exists pre-launch — `HalvingOracle.delegate` (and its `HalvingProver` counterpart): a temporary LayerZero configurator set at deployment that controls the messaging path's endpoint configuration until `renounceDelegate()` permanently removes it. It holds no power over funds, vaults, pools or targets, and cannot rewrite a fact already accepted (delivery is idempotent by height; a conflicting fact reverts). Its permanent removal is a pre-production requirement.

### Constants (`Calendar.sol`)

| Symbol | Definition | Value |
|---|---|---|
| `CYCLE` | nominal cycle | `1460 days` |
| `P` | growth→fall pivot = `CYCLE/φ²` (floor) | ≈ day 557.67 |
| `T` | fall→growth pivot = `CYCLE/φ` (floor) | ≈ day 902.33 |
| `W` | full transition width | `20 days` |
| `H` | half transition = `W/2` | `10 days` |

`φ` is the golden ratio in WAD: `Phi.PHI = 1_618033988749894848`, `Phi.PHI_SQ = φ+1`, `Phi.INV_PHI = φ−1`.

### Zones

`Calendar.zoneAt(t)` returns exactly one of seven zones. Boundaries are **product-independent** — the same instants for every vault:

| Zone | Interval | Meaning |
|---|---|---|
| `Growth` | `[0, P−W)` | growth target held |
| `ClosingGrowth` | `[P−W, P−H)` | leaving the growth target |
| `OpeningFall` | `[P−H, P)` | entering the fall target — **deposits closed** |
| `Fall` | `[P, T)` | fall target held |
| `ClosingFall` | `[T, T+H)` | leaving the fall target |
| `OpeningGrowth` | `[T+H, T+W)` | entering the growth target — **deposits closed** |
| `TerminalGrowth` | `[T+W, next accepted fact)` | growth target held indefinitely |

`TerminalGrowth` is deliberate: the calendar **rests** in growth after `T+W` until the next real halving fact is accepted. Nothing requires the realized halving interval to match the nominal 1460 days, and no wall-clock window ever gates acceptance of a halving fact.

`Calendar.depositOpen(t)` is false exactly in `OpeningFall` and `OpeningGrowth` — the two `0→…` sub-windows.

### Interpolation: split at zero vs. direct

`Calendar.targetAt(t, growth, fall)` returns the current signed WAD target. Which path it takes depends on the **signs of the stored pair**:

```solidity
bool sameSign = (growth > 0 && fall > 0) || (growth < 0 && fall < 0);
```

- **Opposite signs, or either endpoint is zero** → the piecewise path, **split at zero**:
  `growth → 0` over `[P−W, P−H)`, then `0 → fall` over `[P−H, P)`; symmetrically `fall → 0` over `[T, T+H)` and `0 → growth` over `[T+H, T+W)`. This exists so that a derivative **sign change always passes through a verified zero**.
- **Strictly same-sign pairs** → direct linear interpolation `growth → fall` across the whole of `[P−W, P)` and `fall → growth` across `[T, T+W)`. No synthetic zero is ever visited. `StrategyMini` `(1,1)` is the degenerate case: the target is constant, so **Mini trades nothing after deposit** — and is still fee'd on interval profit at settlement (a fee is paid in kind and never forces a sale).

### Settlement points

```solidity
function nextSettlementPoint(uint256 halvingTs, uint256 after_) internal pure returns (uint256)
```

Two fixed, product-independent instants per epoch: `t = P−H` and `t = T+H`. For opposite-sign / zero-endpoint pairs these coincide with the target's zero-crossing, so "profit measured against entry" and the still-wrong-sign perp rejection at settlement are exact. Same-sign pairs settle at the same instants with their (right-sign) exposure legitimately open. An interval runs point to point; the interval beginning at `T+H` crosses the epoch boundary and ends at the next epoch's `P−H`.

Around each point: a settlement-day price snapshot window (`SNAPSHOT_WINDOW = 24 hours`), then a report window (`REPORT_WINDOW = 2 days`), then distribution, then expiry.

### Free-exit windows

`Calendar.freeExit(t)` is true in all four transition zones (`ClosingGrowth`, `OpeningFall`, `ClosingFall`, `OpeningGrowth`) **plus** `t < POST_FACT_FREE_EXIT` (= `W`, 20 days after each accepted halving fact). Exiting anywhere else incurs the penalty of §6.

---

## 2. The exposure equation

A single signed WAD number `n` describes the whole desired position. Execution decomposes it once:

```solidity
/// spot = clamp(n, 0, 1); perp = n − spot
function decompose(int256 n) internal pure returns (int256 spot, int256 perp)
```

`spot` is the fraction of capital held as the directional token; `perp` is signed perpetual notional as a fraction of capital (negative = short). There is no third leg. Settlement currency is canonical linked USDC, valued at a fixed `1 USD`.

Worked values for the reference ladder at scale `k = 1`:

| Product | `(growth, fall)` | Regime | `n` | `spot` | `perp` |
|---|---|---|---|---|---|
| `StrategyMini` | `(1, 1)` | both | `1` | `1` | `0` |
| `StrategyB4` | `(1, 0)` | growth | `1` | `1` | `0` |
| | | fall | `0` | `0` | `0` (all USDC) |
| `StrategyPro` | `(1, −1)` | growth | `1` | `1` | `0` |
| | | fall | `−1` | `0` | `−1` (full short) |
| `StrategyProMax` | `(φ, −φ)` | growth | `1.618033988749894848` | `1` | `+0.618033988749894848` |
| | | fall | `−1.618033988749894848` | `0` | `−1.618033988749894848` |

Mid-transition example — `StrategyB4` (`fall = 0`, so the split-at-zero path applies) at `t = P − 15 days`, i.e. halfway through `ClosingGrowth`:

```
targetAt = growth · (P − H − t)/H = 1 · (5d / 10d) = 0.5
decompose(0.5) → spot = 0.5, perp = 0
```

Mid-transition example — `StrategyMini` at the same instant: same-sign path, `growth + (fall − growth)·(…)/W = 1`. Unchanged, no trade.

Strategies are **view-only**. `IStrategy.targets()` returns a pair of `int256`; a strategy holds no authority over funds and is never called again after selection.

### Structural sizing — leverage bounded by confirmed extremes

A leveraged position's liquidation is placed at a *structurally confirmed* price — a level the market already printed and failed to regain — realized by **margin size** (`margin = notional/L`), never by stop orders. One reflected rule covers both sides ([SPECIFICATION §7b](../spec/SPECIFICATION.md); pure math in [`StructuralLeverage.sol`](../src/libraries/StructuralLeverage.sol)):

- **Long (bottom):** `stop = min(p − (p−floor)/g, cap)` — anchored to the confirmed lows (`floor` = previous cycle bottom, `cap` = most recent confirmed low, ratcheted by [`B4Pool.sampleAnchor`](../src/core/B4Pool.sol)). Leverage is highest near the confirmed low, decays for a late entry, refuses below the floor.
- **Short (top):** `stop = max(p + (MaxStop−p)·(g−1), C)` with `MaxStop = C + (C−prevPeak)·(g−1)` — anchored to the confirmed highs (`C` = this cycle's peak-window max, `prevPeak` = the previous cycle's). Leverage decreases with entry depth, pins its stop to the confirmed peak, and deliberately sizes below `1×` deep in the fall — the small position with the far stop is what survives bear-market rallies.

Positions are sized **once per regime and held** — the sizing price and its anchors are captured together and frozen; the calendar, not NAV drift, is the rebalance schedule. Verified on every completed cycle: the structural stop was never touched, while a flat-`φ` position is liquidated by the +99–103 % bear rallies (short) or the −64 % COVID crash (long).

> **Status:** `StructuralLeverage` (both sides, unit-tested) and the low-side ratchet are on-chain; the engine sizing is flat-`φ` pending the §7b redo, whose requirements are bound by [`../AUDIT-2026-07-structural-leverage.md`](../AUDIT-2026-07-structural-leverage.md).

---

## 3. Policy = a pair × a scale, resolved at selection

A policy is a stored `(growth, fall)` pair of signed WAD targets. `B4Vault._setPolicy` reads the strategy **once** and stores the resolved numbers:

```solidity
function selectPolicy(address strategy, uint256 scaleWad) external onlyOwner;

// inside _setPolicy:
(int256 g, int256 f) = IStrategy(strategy).targets();
if (scaleWad == 0 || scaleWad > Phi.MAX_SCALE) revert BadPolicy();          // 0 < k ≤ 10·WAD
if (Phi.abs(g) > Phi.MAX_BASE_TARGET || Phi.abs(f) > Phi.MAX_BASE_TARGET)   // |b| ≤ 10·WAD
    revert BadPolicy();
int256 rg = g * int256(scaleWad) / int256(Phi.WAD);
int256 rf = f * int256(scaleWad) / int256(Phi.WAD);
if (Phi.abs(rg) > Phi.PHI || Phi.abs(rf) > Phi.PHI) revert BadPolicy();     // |resolved| ≤ φ
growthTarget = rg;
fallTarget   = rf;
```

Consequences worth internalizing:

- The core stores **no product names** — only two signed numbers. A strategy address is an input, not a dependency.
- The hard cap is `|resolved| ≤ φ`. `StrategyProMax` already sits at `|φ|`, so **any** `scaleWad > 1e18` on ProMax reverts with `BadPolicy`. `StrategyPro` (`{1, −1}`) at `k = 1.5` resolves to `(1.5, −1.5)` — a `1.5×` long / `1.5×` short — accepted because `1.5 < φ ≈ 1.618`.
- A later `selectPolicy` (or a scale change) **rebalances this same vault in place**. It is never an exit and never a penalty; the resulting trades are ordinary sync steps. It is rejected while an exit is pending (`ExitPending`).

---

## 4. Vault vs. Pool

Two different objects. Do not conflate them.

| | `B4Vault` | `B4Pool` |
|---|---|---|
| What | isolated custody container, one per user position (an EIP-1167 clone from `B4Factory`) | shared in-kind reward basket for the vaults registered to it |
| Custody | holds the owner's assets, one directional descriptor + the settlement descriptor | holds reward/penalty inventory, owes it to weights |
| Authority | one fixed owner, one immutable fee route, no admin | no admin over funds; `registerVault` is factory-only and `reportWeight` is callable only by a registered vault. Creation is permissionless and **is not endorsement** |
| Owner-only | `selectPolicy`, `deposit`, `initiateExit`, `recoverEvm`, `recoverCoreSpot`, `recoverPerpSurplus`, `emergencyClearRecovery` | — |
| Permissionless | `crank`, `settle`, `claimDeferred` | `advance`, `lockPrices`, `claimFor`, `sweep`, `capture` |
| Views | `currentTarget()`, `navWad()`, `strategyValueWad()` | `intervalInfo`, `lockedPxWad`, `bucketOf`, `remainingOf` |

The vault is split across three files purely for EIP-170 code size: `B4VaultStorage.sol` (shared storage base), `B4VaultEngine.sol` (the async intent engine), and `B4VaultOps.sol` (settle, the crank's plan-step dispatch and the exit machine, exit-finalize, deferred-payout retry and recovery bodies, reached by `delegatecall` through an address fixed at implementation deployment — code organization, **not** an upgrade path; `B4Factory` deploys nothing upgradeable and there is no proxy admin, no pause, and no privileged fund mover).

Pool mechanics in one paragraph: a pool admits 1–8 directional descriptors (`MAX_DIRECTIONAL = 8`) plus the settlement descriptor at index 0, keyed on the **full descriptor hash** (not just the token address) — and additionally rejects any repeated `evmToken` or `coreToken` within the pool. `advance()` materializes the next passed settlement point; `lockPrices(id)` commits checkpoint prices **all-or-nothing**, only after every directional asset prices non-zero; each vault reports weight once per interval via `reportWeight`; `claimFor(id, vault)` pays the vault's fixed owner `nominal = B·w/W` **in kind**, pro rata, with no internal swap, and on shortfall scales by `balance/liability` in an order-independent way. Unclaimed inventory of an expired interval `sweep`s once into the accruing basket with liability unchanged. `capture()` folds any balance above liability into the accruing interval — a donation becomes pool inventory, never vault profit.

---

## 5. Asynchronous execution, and why deltas

B4 drives HyperCore from HyperEVM by emitting CoreWriter actions. **Emitting an action is not proof that it executed.** The whole engine is built around that fact:

1. A step creates an **intent**, snapshots the relevant balances, and emits the action.
2. A later block reads Core state and checks a completion condition on a balance **the protocol's own action reliably moves** — e.g. `spot→perp` completes on a spot net-decrease; `perp→spot` on a spot net-increase reaching the full amount; `spot→EVM` on a spot net-decrease *plus* the EVM destination receiving the full amount. The perp `withdrawable` is PnL-driven and externally toppable, so it is never used as a completion or retry counter.
3. Each resend condition is the exact complement of its completion condition. After a timeout a silent action may be resent; a Core→EVM leg is never resent once its source decreased (it executed — wait for delivery).
4. Accounting updates **once**, from the **measured received delta**, never from the requested amount. Deposits do the same: `_pull` measures `balanceOf` before and after.

Direct consequences:

- An unsolicited transfer or a favorable overfill **does not increase accounting**. It stays unaccounted and is separately recoverable — bounded, with no accounting callback, but the bounds differ per path. `recoverEvm` sweeps EVM balance above the accounted buckets plus `deferredPayoutTotal`; it requires an idle engine only for the two accounted tokens (directional and USDC) and requires no flatness at all, so an arbitrary third-party token is recoverable with an intent in flight. `recoverCoreSpot` and `recoverPerpSurplus` require idle **and** no pending exit **and** strict raw flatness (`_position().szi == 0`, else `NotFlat`).
- All fixed-point division floors toward the protocol (`Phi.mulDiv`, `Phi.wmul`, `Phi.bps`): fees, penalties, cuts and pool claims never round up.
- Every valuation path runs only at an **idle** engine (no action in flight), so a mid-transfer ledger is never valued. `settle` rejects an in-flight engine rather than mistake returning principal for fee-bearing profit.
- Progress is a **permissionless crank**: anyone can call `B4Vault.crank()` (advance the pending intent, else one exit step, else one sync step) or drive many vaults through `Keeper.crank(pool, vaults, maxVaultSteps)`. A keeper is liveness only — it cannot choose target, market, price, or recipient.
- `emergencyClearRecovery()` can abandon a stuck **surplus-recovery** intent only, after a timeout; the funds stay on Core and remain re-recoverable. Asset-transfer intents can never be discarded.

The sync planner walks a fixed priority order: wrong-sign (or should-be-zero) perp reduced to exact zero → harvest settle → reconcile realized loss → spot rotation → margin movement → perp sizing. That is how "a sign change always passes through a verified zero" is enforced at execution, not just in the calendar.

---

## 6. Fees and the early-exit penalty

Both rates are φ-derived constants in `Phi.sol`:

| Constant | Definition | WAD value |
|---|---|---|
| `FEE_F` | virtual performance-fee rate `f = φ⁻⁵/2` | `45084971874737120` |
| `EXIT_Q` | exit penalty rate `q = φ⁻³/2` | `118033988749894848` |
| `MAX_OPERATOR_BPS` | operator cut ≤ 38.19% of the virtual fee | `3819` bps |
| `MIN_REFERRER_BPS` | referrer share of the operator payment ∈ [38.19%, 100%] | `3819` bps |

**At a settlement point** (`settle(intervalId)`, permissionless): profit is measured over the interval **entry ledger**,

```
profit      = max(NAV − E, 0)
virtualFee  = profit · f
operatorCut = virtualFee · operatorBps / 10000
clientShare = virtualFee − operatorCut
reportedWeight = priorRewardBase + clientShare
```

`NAV` is `_navWad` — recorded strategy value + margin value, recorded amounts only — and `E` is the entry ledger. The **pricing basis differs by path**: at settlement `NAV` is taken at the interval's **locked checkpoint** price (`pool.lockedPxWad(intervalId, dirAssetIndex)`); at exit-finalize the same arithmetic runs at the **live** oracle price.

Only the **operator cut is physically paid**, in kind from the accounted EVM basket; Core principal must return through the verified machine first. This is enforced, not merely expected: `settle` reverts `FeeNotRepatriated` unless the accounted EVM basket covers the operator cut, so a vault whose value still sits on Core cannot settle at all until it repatriates (liveness, not custody). A referral is carved *out of* the operator cut, never added. The `clientShare` is not paid out here — it becomes **reward weight** in the shared pool, and is later claimed in kind via `claimFor`. One weight report per interval.

**On exit** (`initiateExit(shareWad)`, `x ∈ (0,1]`, then driven by the live position through permissionless cranks): the perp is reduced to strictly zero, PnL is harvested under bound, realized loss is reconciled, all Core principal is returned — and only then are EVM assets paid.

- Inside a free window (§1): `owner = gross − proportional operatorCut`, `Pool = 0`.
- Outside: `penalty = gross · q`; `operator = min(proportional cut, penalty)`; `owner = gross − penalty`; `Pool = penalty − operator`. There is exactly **one** withholding — the operator payment is carved from it, never stacked on top. The pool's share arrives in kind (the vault transfers, then calls `capture()`), and is distributed in kind to recorded weight with no internal swap.
- Ledgers scale rather than re-anchor: `nextEntry = E·(1−x)`, `nextRewardBase = (R + C·x)·(1−x)`, so each share's profit earns client share exactly once and repeated partial (including dust) exits cannot duplicate reward weight.

A failed payout token transfer does not revert the rest — it is recorded and retried permissionlessly via `claimDeferred(recipient, token)`.

---

## Boundary

B4 targets **one** venue: HyperEVM + HyperCore. There is no multi-network abstraction, no DEX router adapter layer, and no generic swap routing in the core. Deriving carry from the perpetual funding rate is a **deliberate exclusion**, not an omission — see [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §4.

## Next

- [03 Contract map](03-contracts.md) — what each contract does and may not do
- [04 Integration](04-integration.md) — signatures, lifecycle, events
- [07 Fees & pool](07-fee-routing.md) — the fee route, penalty and claims in detail
- Normative package: [`spec/SPECIFICATION.md`](../spec/SPECIFICATION.md), [`spec/HAZARDS.md`](../spec/HAZARDS.md), [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md), [`spec/REQUIREMENTS.md`](../spec/REQUIREMENTS.md), [`spec/TEST_PLAN.md`](../spec/TEST_PLAN.md), [`spec/WHITEPAPER.md`](../spec/WHITEPAPER.md)
- Root: [`ARCHITECTURE.md`](../ARCHITECTURE.md), [`INVARIANTS.md`](../INVARIANTS.md), [`REPORT.md`](../REPORT.md), [`SLITHER.md`](../SLITHER.md)
