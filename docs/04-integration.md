# Integration guide

How to create a B4 pool and vault, drive the owner and permissionless lifecycles, use the recovery entrypoints, and index the protocol — every signature below is read from the source in this repository.

> **Status.** B4 is **pre-mainnet and not externally audited**. Venue semantics (CoreWriter atomicity, Core account activation, precompile behaviour) are not locally provable and are mandatory funded release gates — see [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §5. No addresses or networks are published here. Do not treat anything in this guide as production-readiness.

---

## 1. What you are integrating against

| Contract | Role |
| --- | --- |
| `B4Factory` | Permissionless `createPool` / `createVault`; holds no funds, has no owner |
| `B4Pool` | Shared reward basket: intervals, checkpoint prices, weights, claims |
| `B4Vault` | The user-facing custody container — an EIP-1167 clone, one fixed owner |
| `B4VaultEngine` / `B4VaultOps` | Async intent engine and the delegatecall'd ops module (EIP-170 split) |
| `HalvingOracle` | The proven Bitcoin halving fact (`timeSinceHalving()`, `latest()`) |
| `Keeper` | Permissionless crank wrapper for pools and batches of vaults |
| `StrategyMini` / `StrategyB4` / `StrategyPro` / `StrategyProMax` | View-only `(growth, fall)` target pairs |

In the vault, pool and factory contracts there is **no admin, no upgrade proxy, no pause and no privileged fund mover**. The one administrative boundary in the system is `HalvingOracle.delegate` (and its counterpart on `HalvingProver`) — a temporary LayerZero configurator set in the constructor and removable only by a one-shot `renounceDelegate()`. It configures endpoint settings only: it cannot touch funds, vaults, pools, targets or accepted facts, but until it is renounced it is a live privileged role, so check `delegateRenounced()` on any deployment you integrate with. Strategies hold no authority over funds; a keeper holds no authority at all. Pool creation is permissionless and **is not endorsement** (`B4Factory.createPool` NatSpec, `REQUIREMENTS §1`).

---

## 2. Descriptors

Both factory entrypoints work on `CoreTypes.AssetDescriptor` (`src/venue/CoreTypes.sol`):

```solidity
struct AssetDescriptor {
    address evmToken;
    uint8   evmDecimals;
    uint64  coreToken;
    uint32  spotMarket;      // token/USDC spot pair index
    uint32  perpMarket;      // type(uint32).max (CoreTypes.NO_MARKET) when no perp
    uint8   coreWeiDecimals;
    uint8   spotSzDecimals;
    uint8   perpSzDecimals;
    uint8   perpMaxLeverage;
    bool    fixedUsd;
}
```

The settlement descriptor (`fixedUsd = true`, canonical USDC valued at a fixed 1 USD) is fixed in the factory constructor and readable via:

```solidity
function settlementDescriptor() external view returns (CoreTypes.AssetDescriptor memory);
```

A pool's directional assets are keyed by the **full descriptor hash** `CoreTypes.descriptorHash(d) = keccak256(abi.encode(d))`; `createVault` takes that hash only to resolve which pool asset the vault binds to, and the vault then stores the resolved descriptor and its pool index. Vaults themselves are identified by address (`B4Factory.isVault`, `B4Pool.isVault`). Every directional descriptor is validated against the venue by `DescriptorLib.verifyDirectional` before it is bound; a directional descriptor may not be `fixedUsd` and may not reuse the settlement token.

---

## 3. Creating a pool

```solidity
function createPool(CoreTypes.AssetDescriptor[] calldata directional)
    external
    returns (address poolAddr);
```

- The settlement descriptor is inserted at index `0`; your directional descriptors follow at `1..N`.
- `B4Pool.MAX_DIRECTIONAL == 8`; the constructor reverts `TooManyAssets` outside `1..8` directional entries, and `DuplicateAsset` if a descriptor hash, `evmToken` or `coreToken` repeats.
- Emits `PoolCreated(address indexed pool, uint256 directionalAssets)` and sets `B4Factory.isPool[pool] = true`.

`B4Pool.descriptorIndexPlusOne(bytes32) → uint256` returns *index + 1* into the full asset array (settlement at `0`, directional at `1..N`); `0` means unknown. Read the descriptor back with `B4Pool.asset(indexPlusOne - 1)` — this is exactly what `B4Factory.createVault` does.

---

## 4. Creating a vault

```solidity
function createVault(
    address pool,
    bytes32 dirDescriptorHash,
    address strategy,
    uint256 scaleWad,
    uint16  slippageBps,
    B4VaultStorage.FeeRoute calldata route
) external returns (address vault);
```

`msg.sender` becomes the **fixed owner** and signs the whole configuration in one transaction — clone, owner, pool, execution identity, resolved targets and the immutable fee route are bound atomically (no half-initialized state, no front-run window).

| Parameter | Meaning / constraint |
| --- | --- |
| `pool` | Must satisfy `isPool[pool]`, else `NotAPool()` |
| `dirDescriptorHash` | Must resolve in the pool, else `UnknownDescriptor()` |
| `strategy` | Any `IStrategy`; `targets()` is read **once** here and stored |
| `scaleWad` | `0 < scaleWad ≤ Phi.MAX_SCALE (10e18)`, else `BadPolicy()` |
| `slippageBps` | Spot IOC envelope, `≤ 500`, else `BadSlippage()` |
| `route` | Immutable fee route (below), validated by `_validateRoute` |

```solidity
struct FeeRoute {
    address operator;
    uint16  operatorBps;  // share of the virtual performance fee, ≤ Phi.MAX_OPERATOR_BPS (3819)
    address referrer;
    uint16  referrerBps;  // share of the OPERATOR payment, ∈ [3819, 10000] when referrer != 0
}
```

Route rules enforced in `B4Vault._validateRoute`: `operatorBps > 0` requires a non-zero `operator`; a non-zero `referrer` requires `operatorBps > 0` and `referrerBps ∈ [Phi.MIN_REFERRER_BPS, Phi.BPS]`; a zero `referrer` requires `referrerBps == 0`. Violations revert `BadRoute()`.

Policy resolution at creation and on every `selectPolicy`: with `(g, f) = IStrategy(strategy).targets()`, both `|g|` and `|f|` must be `≤ Phi.MAX_BASE_TARGET (10e18)`, and after scaling `rg = g·scale/WAD`, `rf = f·scale/WAD` both `|rg|, |rf| ≤ Phi.PHI` — otherwise `BadPolicy()`.

Reference ladder (`src/periphery/ReferenceStrategies.sol`), as `(growth, fall)`:

| Strategy | growth | fall |
| --- | --- | --- |
| `StrategyMini` | `1` | `1` |
| `StrategyB4` | `1` | `0` |
| `StrategyPro` | `1` | `−1/φ` |
| `StrategyProMax` | `φ` | `−φ` |

Emits `VaultCreated(address indexed vault, address indexed owner, address indexed pool, bytes32 dirHash)` from the factory and `Initialized(owner, pool, dirDescriptorHash)` plus `PolicySelected(strategy, growth, fall, scaleWad)` from the vault.

---

## 5. Owner lifecycle

All three are `onlyOwner` (`OnlyOwner()` otherwise).

```solidity
function deposit(uint256 dirAmount, uint256 usdcAmount) external;      // nonReentrant
function selectPolicy(address strategy, uint256 scaleWad) external;
function initiateExit(uint256 shareWad) external;
```

**`deposit`** — pull directional capital and/or USDC margin. Requires prior ERC-20 approval to the vault. Reverts: `ExitPending()` if an exit is in progress, `ZeroDeposit()` if both amounts are zero, `DepositWindowClosed()` when `Calendar.depositOpen(oracle.timeSinceHalving())` is false (deposits are closed in the two `0 → target` opening sub-windows: `OpeningFall` and `OpeningGrowth`). Accounting uses the **actual received delta**, not the requested amount, so fee-on-transfer tokens cannot inflate the ledger. Emits `Deposited(dirAmount, usdcAmount, valueWad, entryWad)`.

**`selectPolicy`** — re-read a strategy and store new resolved targets. Blocked while `exitShareWad != 0`. A product/scale change rebalances the same vault in place through ordinary sync steps; it is never exit or penalty logic. Emits `PolicySelected`.

**`initiateExit`** — begin exiting share `x ∈ (0, WAD]`. Reverts `ExitPending()` if one is already open, `BadShare()` outside the range. This only *arms* the exit: it is then driven by the live position through permissionless cranks. Emits `ExitInitiated(shareWad)`, and eventually `ExitFinalized(shareWad, grossWad, ownerWad, penaltyWad, free)`.

Whether an exit is free is decided at finalization by `Calendar.freeExit(timeSinceHalving())` — true inside the four transition zones and for `POST_FACT_FREE_EXIT` (= `W` = 20 days) after each accepted halving fact. Outside a free window one in-kind penalty (`Phi.EXIT_Q` of gross) is withheld; the operator payment is *carved from* that penalty, never added, and the remainder is pushed to the pool as inventory.

---

## 6. Permissionless lifecycle — you must crank

**Execution is asynchronous.** Emitting a CoreWriter action is not proof it executed. A leg completes only when a later Core state read of a self-moved balance proves it, and accounting always measures the actual received delta. That means a vault does **not** advance by itself: after a deposit, after a policy change, across calendar transitions, and throughout an exit, someone must call `crank()` repeatedly. As an owner you either run this yourself or rely on a third-party keeper — but you should never assume a keeper exists.

```solidity
function crank() external returns (bool progressed);   // nonReentrant
function settle(uint256 intervalId) external;          // nonReentrant
function claimDeferred(address recipient, address token) external; // nonReentrant
```

`crank()` performs exactly one step, in priority order: verify/advance the pending intent if `intent.kind != IntentKind.None`; else one exit step if `exitShareWad != 0`; else one sync step toward the time-derived target. Loop until it returns `false`.

`settle(intervalId)` values NAV at the interval's **locked checkpoint price**, fees profit over the entry ledger, pays the operator cut **in kind from the EVM basket**, re-anchors the entry ledger, adds the client share to `rewardBaseWad`, and reports that as pool weight. It requires an **idle engine** and reverts otherwise: `IntentPending()`, `ExitPending()`, `AlreadySettled()`, `NotSettleable()` (prices not locked or report deadline passed), `WrongSignPerp()` (a perp position whose sign disagrees with the decomposed target for the interval), or `FeeNotRepatriated()` (the accounted EVM basket cannot cover the operator cut — repatriate first by cranking). Emits `Settled(intervalId, navWad, profitWad, feePaidWad)` and `FeePaid(operator, operatorValueWad, referrer)`.

`claimDeferred(recipient, token)` retries a payout that was deferred because its ERC-20 transfer failed (e.g. a blacklisted recipient). It is permissionless but pays **only the recorded recipient**; reverts `NothingToRecover()` when nothing is owed, and reverts (retryably) if the transfer still fails. Emits `DeferredPayoutClaimed(to, token, amount)`. Read the ledger with `deferredPayout(address recipient, address token)` and `deferredPayoutTotal(address token)`.

### Pool-side permissionless calls

```solidity
function advance() external returns (bool materialized);  // materialize one passed settlement point
function lockPrices(uint256 id) external;                 // within Calendar.SNAPSHOT_WINDOW (1 hour)
function claimFor(uint256 id, address vault) external;    // pays the vault's fixed owner, in kind
function sweep(uint256 id) external;                      // roll an expired interval's inventory forward
function capture() external;                              // account any balance above liability
```

`lockPrices` is **all-or-nothing**: it commits only if every directional asset prices non-zero, otherwise reverts (`ZeroPrice()`) so a later call inside the window retries. Weights are reported by vaults themselves via `reportWeight(uint256 id, uint256 weight)` — external callers cannot report. Claims open only after `reportDeadline(id)` (= `pointTime + SNAPSHOT_WINDOW + REPORT_WINDOW`, i.e. 1 hour + 2 days) and pay pro rata in kind, with no internal swap — and they close when the interval is swept: `sweep(id)` is permissionless and callable as soon as a later interval exists, after which `claimFor` reverts `NothingToClaim()` and the unclaimed inventory has rolled forward into the next basket. Claim promptly after `reportDeadline(id)`.

### Keeper

```solidity
function crank(B4Pool pool, address[] calldata vaults, uint256 maxVaultSteps) external;
function crankVault(B4Vault v, uint256 maxVaultSteps) external returns (uint256 advanced);
function settleVault(B4Vault v, uint256 reportId) external returns (bool);
function retryDeferred(B4Vault v) external returns (uint256);
```

`Keeper.crank` drives the whole pipeline — `advance` loop, `lockPrices`, a bounded `sweep` catch-up window (`SWEEP_LOOKBACK = 16`), `capture`, then per vault: `crankVault`, `settleVault` when the pool reports an open interval, `claimFor`, `retryDeferred`. Every step is wrapped in `try/catch` so one unavailable step never strands the rest. The three wrappers are self-guarded (`require(msg.sender == address(this), "self")`) — call them through `crank`. Emits `Cranked(pool, vaults, stepsAdvanced)`.

---

## 7. Recovery entrypoints

All four are `onlyOwner`. None of them can create authority or move accounted client funds.

```solidity
function recoverEvm(address token) external;        // nonReentrant
function recoverCoreSpot(bool dirToken) external;   // nonReentrant
function recoverPerpSurplus() external;             // nonReentrant
function emergencyClearRecovery() external;
```

| Entrypoint | Recovers exactly | Preconditions |
| --- | --- | --- |
| `recoverEvm(token)` | The EVM balance **above** what is accounted for that token, minus `deferredPayoutTotal[token]`. For the directional token: `bal − min(dirEvm + deferred, bal)`. For USDC: `bal − min(usdcRotatedEvm + usdcMarginEvm + deferred, bal)`. For any other token: `bal − min(deferred, bal)` — i.e. the whole stray balance | Idle engine required for the two accounted tokens; `NothingToRecover()` when the excess is zero |
| `recoverCoreSpot(dirToken)` | Core **spot** balance above recorded principal — `coreDirWei` for the directional token, `coreUsdcRotatedWei + coreUsdcMarginWei` for USDC. Works with zero recorded principal | Idle **and** strictly flat perp (`NotFlat()` if `position().szi != 0`), no exit pending |
| `recoverPerpSurplus()` | Perp withdrawable above `perpMargin6 + pendingHarvest6`. Losses are reconciled first, so the surplus is honest; the pending harvest claim is reserved because it belongs to the taxed strategy ledger. Two-phase perp → spot → EVM → owner | Idle and strictly flat; `NothingToRecover()` when withdrawable ≤ reserved |
| `emergencyClearRecovery()` | Nothing — it **discards a stuck surplus-recovery intent** only (`RecoverSpotDir`, `RecoverSpotUsdc`, `RecoverPerpPhase1`, `RecoverPerpPhase2`) after `EMERGENCY_TIMEOUT` (3 days). The funds stay on Core and remain re-recoverable | `NotRecoveryIntent()` for any other intent kind; `TooEarly()` before the timeout |

Asset-transfer intents can never be discarded — they always progress after the resend timeout. Donations and overfills stay unaccounted and are separately recoverable through the table above; they never become vault profit.

---

## 8. Read surface

Vault (`B4Vault` / `B4VaultStorage`):

```solidity
function currentTarget() external view returns (int256);       // signed WAD target now
function navWad() external view returns (uint256);             // NAV at the live price
function strategyValueWad() external view returns (uint256);   // strategy notional at the live price

function owner() external view returns (address);
function pool() external view returns (address);
function oracle() external view returns (address);
function route() external view returns (address, uint16, address, uint16);
function growthTarget() external view returns (int256);
function fallTarget() external view returns (int256);
function slippageBps() external view returns (uint16);
function dirDescriptor()  external view returns (CoreTypes.AssetDescriptor memory);
function usdcDescriptor() external view returns (CoreTypes.AssetDescriptor memory);

function dirEvm() external view returns (uint256);
function usdcRotatedEvm() external view returns (uint256);
function usdcMarginEvm() external view returns (uint256);
function coreDirWei() external view returns (uint64);
function coreUsdcRotatedWei() external view returns (uint64);
function coreUsdcMarginWei() external view returns (uint64);
function perpMargin6() external view returns (uint64);
function pendingHarvest6() external view returns (uint64);
function entryLedgerWad() external view returns (uint256);
function rewardBaseWad() external view returns (uint256);
function lastSettledPlusOne() external view returns (uint256);
function exitShareWad() external view returns (uint256);
function intent() external view returns (...);                 // the Intent struct
function deferredPayout(address, address) external view returns (uint256);
function deferredPayoutTotal(address) external view returns (uint256);
```

`currentTarget()` returns the signed WAD exposure `n` for *now*; decompose it exactly as the protocol does: `spot = clamp(n, 0, 1)`, `perp = n − spot` (`Calendar.decompose`).

Pool (`B4Pool`):

```solidity
function intervalCount() external view returns (uint256);
function intervalInfo(uint256 id)
    external view returns (uint64 pointTime, uint64 lockedAt, bool swept, uint256 totalWeight);
function reportDeadline(uint256 id) external view returns (uint256);
function currentReportable() external view returns (bool exists, uint256 id);
function lockedPxWad(uint256 id, uint256 assetIndex) external view returns (uint256);
function bucketOf(uint256 id, uint256 assetIndex) external view returns (uint256);
function remainingOf(uint256 id, uint256 assetIndex) external view returns (uint256);
function weightOf(uint256 id, address vault) external view returns (uint256);
function claimedOf(uint256 id, address vault, uint256 assetIndex) external view returns (bool);
function accruing(uint256 assetIndex) external view returns (uint256);
function liability(address token) external view returns (uint256);
function descriptorIndexPlusOne(bytes32 hash) external view returns (uint256);
function asset(uint256 i) external view returns (CoreTypes.AssetDescriptor memory);
function isVault(address) external view returns (bool);
function assetCount() external view returns (uint256);
```

Oracle — `IHalvingOracle` carries the four functions the vault itself uses: `halvingHeight()`, `halvingTs()`, `epoch()`, `timeSinceHalving()`. The concrete `HalvingOracle` additionally exposes `latest() → (height, ts, epoch)`, `factHash(uint256 height) → bytes32` (0 for the deploy-time genesis anchor, which carries no header), the immutable path getters `endpoint()` / `srcEid()` / `srcSender()`, and the administrative-boundary getters `delegate()` / `delegateRenounced()` — check that `delegate() == address(0)` before treating a deployment as fully immutable.

Factory: `oracle()`, `vaultImplementation()`, `settlementDescriptor()`, `isPool(address)`, `isVault(address)`.

---

## 9. Events an indexer should follow

**Factory:** `PoolCreated(pool, directionalAssets)`, `VaultCreated(vault, owner, pool, dirHash)`.

**Vault (`B4VaultStorage`):**

| Event | Why it matters |
| --- | --- |
| `Initialized(owner, pool, dirDescriptorHash)` | Vault genesis |
| `PolicySelected(strategy, growth, fall, scaleWad)` | Stored targets changed |
| `Deposited(dirAmount, usdcAmount, valueWad, entryWad)` | Entry ledger moved |
| `IntentCreated` / `IntentCompleted` / `IntentResent` / `IntentCleared` | The async execution state machine |
| `SpotTraded(isBuy, inWei, outWei, creditedOutWei)` | Measured fill, not requested amount |
| `HarvestRecorded(claim6)` / `HarvestSettled(settled6, residualAbandoned6)` | Realized perp PnL routing |
| `LossReconciled(writtenDown6)` | Silent value movement made visible |
| `MarginReturned(amount6)` | Margin repatriation |
| `Settled(intervalId, navWad, profitWad, feePaidWad)` | Checkpoint accounting |
| `FeePaid(operator, operatorValueWad, referrer)` | In-kind operator/referrer payment |
| `ExitInitiated(shareWad)` / `ExitFinalized(shareWad, grossWad, ownerWad, penaltyWad, free)` | Exit lifecycle and penalty |
| `SurplusRecovered(kind, amount, to)` / `UnaccountedEvmRecovered(token, amount)` | Recovery outcomes |
| `EmergencyCleared(kind)` | A stuck recovery intent was discarded |
| `PayoutDeferred(to, token, amount)` / `DeferredPayoutClaimed(to, token, amount)` | Failed-transfer bookkeeping |

**Pool:** `IntervalMaterialized(id, pointTime)`, `PricesLocked(id, lockedAt)`, `WeightReported(id, vault, weight)`, `Claimed(id, vault, assetIndex, nominal, paid)`, `ClaimDeferred(id, vault, assetIndex)`, `Swept(id)`, `Captured(assetIndex, amount)`, `VaultRegistered(vault)`.

**Keeper:** `Cranked(pool, vaults, stepsAdvanced)`.

An indexer that wants NAV history should key off `Settled` (checkpoint-priced, authoritative) rather than polling `navWad()` (live-priced, informational).

---

## 10. End-to-end sketch

```solidity
// 1. Pool (permissionless — creating one is not endorsement).
CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
dirs[0] = myDirectionalDescriptor;              // validated against the venue by the factory
address pool = factory.createPool(dirs);
bytes32 dirHash = CoreTypes.descriptorHash(dirs[0]);

// 2. Vault — msg.sender becomes the fixed owner and signs the whole configuration.
B4VaultStorage.FeeRoute memory route = B4VaultStorage.FeeRoute({
    operator:    operatorAddr,
    operatorBps: 3819,        // <= Phi.MAX_OPERATOR_BPS
    referrer:    address(0),
    referrerBps: 0
});
address vault = factory.createVault(pool, dirHash, address(strategyB4), 1e18, 100, route);

// 3. Fund it (deposit windows are closed in the two opening sub-windows).
IERC20(dirToken).approve(vault, dirAmount);
IERC20(usdc).approve(vault, usdcAmount);
B4Vault(vault).deposit(dirAmount, usdcAmount);

// 4. Execution is ASYNC — drive it until it stops progressing.
while (B4Vault(vault).crank()) {}

// 5. At a checkpoint: pool side first, then settle the vault.
B4Pool(pool).advance();
uint256 id = B4Pool(pool).intervalCount() - 1;   // the just-materialized interval
B4Pool(pool).lockPrices(id);                     // within Calendar.SNAPSHOT_WINDOW (1 hour)
(bool ok, uint256 rid) = B4Pool(pool).currentReportable();  // only true once prices are locked
while (B4Vault(vault).crank()) {}      // reach an idle engine before settling
if (ok) B4Vault(vault).settle(rid);

// 6. After reportDeadline(id): pull the in-kind pool reward to the vault owner.
B4Pool(pool).claimFor(id, vault);

// 7. Exit — arm it, then crank it to completion.
B4Vault(vault).initiateExit(1e18);     // full exit
while (B4Vault(vault).crank()) {}
```

In practice steps 4–6 are what `Keeper.crank(pool, vaults, maxVaultSteps)` does for a batch of vaults in one transaction.

---

## 11. Integrator checklist

- [ ] Approve the vault before `deposit`; expect the **received delta** to be what is accounted.
- [ ] Handle `DepositWindowClosed()` — check `Calendar.depositOpen(oracle.timeSinceHalving())` first.
- [ ] Never assume an emitted action executed; poll a vault's `intent()` and `crank()` until idle.
- [ ] Reach an idle engine before calling `settle` — otherwise `IntentPending()`.
- [ ] Budget for `FeeNotRepatriated()`: the operator cut is paid in kind from the **EVM** basket.
- [ ] Time exits against `Calendar.freeExit` if you want to avoid the `Phi.EXIT_Q` penalty.
- [ ] Watch `PayoutDeferred` and retry via `claimDeferred` — a failed transfer never freezes the vault.
- [ ] Run (or contract) a keeper; do not assume one exists for your vault.
- [ ] Re-read `spec/SECURITY_MODEL.md` §5 before assuming any venue behaviour holds on-chain.

## Further reading

- Normative package: [`spec/WHITEPAPER.md`](../spec/WHITEPAPER.md), [`spec/SPECIFICATION.md`](../spec/SPECIFICATION.md), [`spec/HAZARDS.md`](../spec/HAZARDS.md), [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md), [`spec/REQUIREMENTS.md`](../spec/REQUIREMENTS.md), [`spec/TEST_PLAN.md`](../spec/TEST_PLAN.md)
- Repository root: [`ARCHITECTURE.md`](../ARCHITECTURE.md), [`INVARIANTS.md`](../INVARIANTS.md), [`REPORT.md`](../REPORT.md), [`SLITHER.md`](../SLITHER.md)
