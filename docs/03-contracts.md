# Contract map

A contract-by-contract reference of everything that ships under `src/` — what each piece is responsible for, its key entrypoints, who may call them, and what it deliberately cannot do.

> **Status.** B4 is **pre-mainnet and not externally audited**. Venue semantics (CoreWriter action execution and atomicity, Core account activation, precompile ABI/gas) are **not locally provable** and are mandatory funded release gates — see [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §5. Nothing here should be read as a production-readiness claim.
>
> For the design rationale behind these boundaries, read [`ARCHITECTURE.md`](../ARCHITECTURE.md). Normative behavior lives in [`spec/SPECIFICATION.md`](../spec/SPECIFICATION.md); the hazard catalogue in [`spec/HAZARDS.md`](../spec/HAZARDS.md); invariants in [`INVARIANTS.md`](../INVARIANTS.md); the security dossier and internal adversarial-review history in [`REPORT.md`](../REPORT.md) (an independent external audit is still outstanding).

---

## 1. What ships

```
src/
  core/       B4Factory  B4Vault  B4VaultStorage  B4VaultEngine  B4VaultOps  B4Pool  HalvingOracle
  citrea/     HalvingProver
  periphery/  Keeper  ReferenceStrategies (StrategyMini/B4/Pro/ProMax)
  venue/      CoreTypes  CoreReader  CoreWriterLib  DescriptorLib
  libraries/  Phi  Calendar  BtcHeader  SafeTransfer  StructuralLeverage
  interfaces/ IERC20  IStrategy  IHalvingOracle  ILayerZero
```

There is **no admin contract, no upgrade proxy, no pause switch, and no privileged fund mover** anywhere in that list. The only role that can move a vault's value is the vault's own fixed owner, and only along paths the vault itself defines. The one administrative boundary in the system is the temporary LayerZero `delegate` on `HalvingOracle` and `HalvingProver`, which configures endpoint settings only, touches no funds, and is removed one-shot by `renounceDelegate()` (§6, §12).

---

## 2. How they connect

```
              Bitcoin (halving block header)
                        │
                 Citrea light client
                        │  getBlockHash(height)
                 ┌──────▼────────┐
                 │ HalvingProver │  publish(height, header, options)  [permissionless]
                 └──────┬────────┘
                        │ LayerZero V2 message (height, 80-byte header)
                 ┌──────▼────────┐
                 │ HalvingOracle │  halvingTs / timeSinceHalving() / latest()
                 └──────┬────────┘
                        │ (read-only)
        ┌───────────────┼────────────────────────────┐
        │               │                            │
   ┌────▼─────┐   ┌─────▼──────┐               ┌─────▼──────┐
   │ B4Factory│──▶│  B4Pool    │◀── weights ───│  B4Vault   │ (EIP-1167 clone)
   │          │   │  (shared   │   penalties   │  owner=you │
   │createPool│   │   reward   │──── claims ──▶│            │
   │createVault│  │   basket)  │               └──┬───┬─────┘
   └──────────┘   └────────────┘                  │   │ delegatecall
                                                  │   └──▶ B4VaultOps
        ┌─────────────────────────────────────────┘        (settle / exit-finalize
        │ CoreReader (precompile reads)                      / recovery / claimDeferred)
        │ CoreWriterLib (action encoding)
   ┌────▼──────────────────────────┐
   │ HyperCore (spot + perp)       │
   └───────────────────────────────┘

   Keeper — permissionless crank; calls only public functions of B4Pool and B4Vault.
   ReferenceStrategies — pure view sources of a (growth, fall) pair. No authority.
```

The protocol targets **one venue: HyperEVM + HyperCore**. There is no multi-venue routing layer.

---

## 3. `src/core/B4Factory.sol`

**Responsibility.** Permissionless deployment of pools, and atomic creation + binding of vault clones. It holds no funds, has no owner, and stores only two immutables, the write-once settlement descriptor, and two registries (`isPool`, `isVault`).

**Constructor state.** `oracle`, `vaultImplementation` (both `immutable`), and the settlement descriptor, which is validated by `DescriptorLib.verifySettlement` before it is stored.

```solidity
function createPool(CoreTypes.AssetDescriptor[] calldata directional) external returns (address poolAddr);

function createVault(
    address pool,
    bytes32 dirDescriptorHash,
    address strategy,
    uint256 scaleWad,
    uint16 slippageBps,
    B4VaultStorage.FeeRoute calldata route
) external returns (address vault);

function settlementDescriptor() external view returns (CoreTypes.AssetDescriptor memory);
```

| Entrypoint | Caller | Notes |
|---|---|---|
| `createPool` | anyone | Every directional descriptor is checked with `DescriptorLib.verifyDirectional` against the venue before the `B4Pool` is deployed. |
| `createVault` | anyone | `msg.sender` becomes the vault's permanent `owner`. Reverts `NotAPool` / `UnknownDescriptor` if the pool or descriptor hash is unknown. |

The vault is created as a **minimal EIP-1167 clone** of `vaultImplementation` (`_clone`, reverting `CloneFailed` on a failed `create`), then `initialize`d and registered with the pool — owner, pool, oracle, both descriptors, policy, scale, slippage and the immutable fee route are all bound in that single transaction, so there is no half-initialized vault and no front-run window.

**It may NOT:** hold or move user funds; upgrade or re-point `vaultImplementation`; endorse a pool. **Permissionless pool creation is not endorsement** — any descriptor set that passes venue verification can be deployed by anyone (`spec/REQUIREMENTS.md` §1).

---

## 4. The vault: `B4Vault` + `B4VaultStorage` + `B4VaultEngine` + `B4VaultOps`

One user-facing custody container is *one* deployed clone, but its code is split across four Solidity units.

### 4.1 Why the split exists (EIP-170)

`B4Vault` is a single logical contract whose full body — async intent engine, planner, settlement, exit finalization, recovery — exceeds the **EIP-170 24,576-byte deployed-code limit**. The bodies of `settle`, exit finalization, recovery and deferred-payout retry therefore live in `B4VaultOps`, reached by `delegatecall`:

```solidity
address public immutable ops;      // fixed at implementation deployment; rejects address(0)

function _delegate(bytes memory data) internal returns (bytes memory) {
    (bool ok, bytes memory ret) = ops.delegatecall(data);
    ...
}
```

This is **code organization, not an upgrade path.** `ops` is an `immutable` of the vault implementation, set once in the constructor and unreachable by any setter — nothing in the system can re-point it. The implementation's constructor also sets `_initialized = true`, so the implementation itself can never be initialized, and `B4VaultOps` guards every entrypoint with `onlyInitialized` (`NotDelegated`) so a direct call — which would operate on the module's own empty storage — reverts.

The vault implementation and its `B4VaultOps` module are deployed **outside** the factory: the already-deployed implementation address is passed to the `B4Factory` constructor as `vaultImplementation_` and kept as an `immutable` (the constructor NatSpec cites EIP-3860 initcode limits as the reason for deploying it separately), and `ops` is bound to that implementation by the `B4Vault` constructor. Both are part of the reproducible-build manifest (`spec/SECURITY_MODEL.md` §5.14).

### 4.2 Storage-layout requirement

> **`B4Vault` and `B4VaultOps` must share exactly the same storage layout.** A `delegatecall` executes the module's code against the *vault's* storage; any divergence in slot ordering silently corrupts custody accounting.

This is enforced structurally rather than by convention:

```
B4VaultStorage  (abstract) — all config, accounting, intent, exit and deferred-payout state
      ▲
B4VaultEngine   (abstract) — adds exactly one state variable: `uint64 public pendingHarvest6`
      ▲                       plus all pure/internal engine logic
   ┌──┴───────────┐
B4Vault       B4VaultOps    — neither declares any additional state variable
```

Both concrete contracts inherit the identical chain, and **neither adds storage of its own** (`B4Vault` adds only the `immutable ops`, which lives in code, not storage). Any future state variable must be added in `B4VaultStorage` or `B4VaultEngine` — never in `B4Vault` or `B4VaultOps`.

### 4.3 `B4VaultStorage.sol` — layout, types, events, errors

Declares the whole state surface and the shared guards:

- **Config:** `owner`, `pool`, `factory`, `oracle`, `slippageBps` (≤ 500), `route` (`FeeRoute{operator, operatorBps, referrer, referrerBps}`), `_dir` / `_usdc` descriptors, `_dirAssetIndex`, and the resolved policy `growthTarget` / `fallTarget`.
- **Accounting buckets:** `dirEvm`, `usdcRotatedEvm`, `usdcMarginEvm` (EVM units); `coreDirWei`, `coreUsdcRotatedWei`, `coreUsdcMarginWei` (Core spot wei); `perpMargin6` (1e6 USD); `entryLedgerWad` (interval entry ledger E), `rewardBaseWad` (reward base R), `lastSettledPlusOne`.
- **Async intent:** the `IntentKind` / `Purpose` enums and the single `Intent intent` slot — at most one intent is in flight at a time.
- **Exit:** `exitShareWad`.
- **Deferred payouts:** `deferredPayout[recipient][token]` and `deferredPayoutTotal[token]`.
- **Constants:** `RESEND_TIMEOUT = 1 hours`, `EMERGENCY_TIMEOUT = 3 days`, `TOLERANCE_BPS = 100`, `MIN_ORDER_USD_WAD = 10e18`, `PERP_ENVELOPE_BPS = 50`, `ACTIVATION_FEE_USD_WAD = 5e18`.
- **Modifiers:** `onlyOwner`, `nonReentrant`.
- **Views:** `dirDescriptor()`, `usdcDescriptor()`.

Declares no logic beyond those two views. It is `abstract` and never deployed alone.

### 4.4 `B4VaultEngine.sol` — the asynchronous intent engine

The heart of the execution discipline. All members are `internal`/`private` except the single public `pendingHarvest6`; it is reached only through `B4Vault.crank()` and `B4VaultOps`.

What it does:

- **Unit and price plumbing** — `_toWad` / `_fromWad` / `_usd6ToWei` / `_weiToUsd6`, lot↔`1e8` fixed-point conversions, `_livePxWad`, `_spotBal`, `_wd`, `_position`.
- **Valuation** — `_strategyValueWad`, `_marginValueWad`, `_navWad`, and `_reconcile` (write down realized loss before any sizing valuation).
- **Intent starts** — `_startFund`, `_startSpotOrder`, `_startReturn`, `_startToPerp`, `_startFromPerp`, `_startPerpOrder`, `_startRecoverySpot`. Each snapshots the balances it will later compare against and then emits a `CoreWriterLib` action.
- **Intent verification** — `_verifyIntent` dispatching to `_verifyFund`, `_verifySpotOrder`, `_verifyReturn`, `_verifyToPerp`, `_verifyFromPerp`, `_verifyPerpOrder`, `_verifyRecovery`.
- **Planning** — `_currentTarget()` = `Calendar.targetAt(oracle.timeSinceHalving(), growthTarget, fallTarget)`; `_planSyncStep` with the fixed priority order *wrong-sign perp reduce → harvest settle → reconcile → spot rotation → margin → perp sizing*; `_planSpotStep`, `_planPerpStep`.

The rules it encodes (documented in the contract header, catalogued in `spec/HAZARDS.md` §A):

- **Emitting a CoreWriter action is never proof it executed.** Completion is proven only by a later Core state read.
- **Completion keys on the Core spot balance** (which our own actions are the only thing that decreases) plus, for Core→EVM legs, the EVM receipt. The perp `withdrawable` is **never** a completion or retry counter — it only sizes clamps.
- **Accounting credits measured deltas, never requested amounts**, and caps credits at both the intended amount and the price envelope. Anything above that is unaccounted surplus, separately recoverable.
- Every resend condition is the exact complement of its completion condition; a resend re-arms `RESEND_TIMEOUT` so at most one emitted action is ever live.
- A Core→EVM leg is never resent once its source decreased; EVM→Core credits are polled forever, never re-emitted or abandoned.
- The pending harvest claim **gates nothing** and is always settled as `min(claim, available-now)` then cleared.

### 4.5 `B4Vault.sol` — the user-facing container

The address a user funds and the vault's isolated Core execution identity.

```solidity
constructor(address ops_);                       // implementation only; reverts ZeroOps

function initialize(
    address owner_, address pool_, address oracle_,
    CoreTypes.AssetDescriptor calldata dir_, CoreTypes.AssetDescriptor calldata usdc_,
    uint256 dirAssetIndex_, address strategy, uint256 scaleWad,
    uint16 slippageBps_, FeeRoute calldata route_
) external;

function selectPolicy(address strategy, uint256 scaleWad) external;   // onlyOwner
function deposit(uint256 dirAmount, uint256 usdcAmount) external;     // onlyOwner
function initiateExit(uint256 shareWad) external;                     // onlyOwner
function recoverEvm(address token) external;                          // onlyOwner
function recoverCoreSpot(bool dirToken) external;                     // onlyOwner
function recoverPerpSurplus() external;                               // onlyOwner
function emergencyClearRecovery() external;                           // onlyOwner

function crank() external returns (bool progressed);                  // permissionless
function settle(uint256 intervalId) external;                         // permissionless
function claimDeferred(address recipient, address token) external;    // permissionless

function currentTarget() external view returns (int256);
function navWad() external view returns (uint256);
function strategyValueWad() external view returns (uint256);
```

| Entrypoint | Caller | What it may / may not do |
|---|---|---|
| `initialize` | anyone, once — consumed atomically by the factory | One-shot; the guard is `_initialized`, **not** a factory check — re-entry reverts `AlreadyInitialized`. `B4Factory.createVault` clones and initializes in the same transaction, so no third party can ever reach an uninitialized clone. Re-verifies both descriptors against the venue, bounds `slippageBps ≤ 500`, validates the fee route, resolves the policy. |
| `selectPolicy` | owner | Reads `IStrategy.targets()` **once** and stores the resolved `(growthTarget, fallTarget)`. Bounds: `0 < scaleWad ≤ 10e18`, `|base| ≤ 10e18`, `|resolved| ≤ φ`. Blocked while an exit is pending. A later product/scale change rebalances in place — it is never exit or penalty logic. |
| `deposit` | owner | Directional token and/or USDC margin. Only in an open calendar window (`Calendar.depositOpen`, else `DepositWindowClosed`). Credits the **actual received delta** via a balance-before/after measurement, and adds the deposited value to `entryLedgerWad`. |
| `crank` | anyone | Verify a pending intent, else one exit step, else one sync step (delegated to `B4VaultOps.opsPlanStep`). Liveness only. |
| `initiateExit` | owner | Sets `exitShareWad ∈ (0, 1]`; the exit is then driven by the *live* position through permissionless cranks. |
| `settle` | anyone | Delegates to `opsSettle`. |
| `recoverEvm` / `recoverCoreSpot` / `recoverPerpSurplus` | owner | Recovery of **unaccounted** surplus only (see §4.6). |
| `emergencyClearRecovery` | owner | Only for a stuck *surplus-recovery* intent (`RecoverSpotDir`, `RecoverSpotUsdc`, `RecoverPerpPhase1/2`) and only after `EMERGENCY_TIMEOUT` (3 days) — else `NotRecoveryIntent` / `TooEarly`. Asset-transfer intents can never be discarded. |
| `claimDeferred` | anyone | Retries a failed payout; pays **only the recorded recipient**. |

Fee-route validation (`_validateRoute`): `operatorBps ≤ Phi.MAX_OPERATOR_BPS` (3819); a non-zero rate requires a non-zero operator address; a referrer requires a non-zero operator rate and `referrerBps ∈ [3819, 10000]`; a zero referrer must carry a zero `referrerBps`.

**A vault may NOT:** be paused, upgraded, or administered; change its owner, pool, descriptors or fee route after `initialize`; let a keeper choose a target, market, price or recipient; accept a deposit in a closed window; or credit an amount it did not measure.

### 4.6 `B4VaultOps.sol` — settle / exit-finalize / recovery module

Reached only by `delegatecall` from `B4Vault`.

```solidity
function opsSettle(uint256 intervalId) external;                       // onlyInitialized
function opsPlanStep() external returns (bool);                        // onlyInitialized
function opsClaimDeferred(address recipient, address token) external;  // onlyInitialized
function opsRecoverEvm(address token) external;                        // onlyInitialized
function opsRecoverCoreSpot(bool dirToken) external;                   // onlyInitialized
function opsRecoverPerpSurplus() external;                             // onlyInitialized
```

**Settlement (`opsSettle`).** Requires no pending exit (`ExitPending` when `exitShareWad != 0`), an idle engine, an unsettled interval, locked checkpoint prices, and a still-open report window (`NotSettleable` / `AlreadySettled`). A perp position whose sign disagrees with the interval's target reverts `WrongSignPerp` — the previous regime's exposure must pass through a verified zero first. Then: reconcile → value NAV at the pool's **locked** checkpoint price → `profit = max(nav − entryLedger, 0)` → `virtualFee = profit · f` (`Phi.FEE_F = φ⁻⁵/2`) → `operatorCut = virtualFee · operatorBps` → `clientShare = virtualFee − operatorCut`. The operator cut is paid **in kind** proportionally from the EVM basket; if the basket cannot cover it, settle reverts `FeeNotRepatriated` rather than waiving the cut. `entryLedgerWad` is re-anchored to `nav − paid`, `rewardBaseWad += clientShare`, and the new reward base is reported to the pool as this interval's weight — once.

**Exit (`_planExitStep` → `_finalizeExit`).** Flatten the perp to raw zero → settle any harvest claim → reconcile → return **all** Core principal (rotated USDC, margin USDC, directional) → finalize. Finalization values NAV at the live price, then splits the exiting share in kind. Inside a free window (`Calendar.freeExit`) the owner receives the gross less the proportional operator cut. Outside it, **one** penalty `q = Phi.EXIT_Q = φ⁻³/2` of the gross is withheld; the operator payment is *carved from* that penalty, never added, and the remainder is transferred to the pool, which then accounts it via `capture()` (wrapped in `try/catch` so a griefing co-asset can never freeze the exit). Ledgers scale by `(1 − x)` so repeated partial exits can neither mint nor duplicate weight.

**Payouts never freeze the vault.** `_payOut` uses `SafeTransfer.tryTransfer`; a failing recipient (e.g. a blacklisted address) has the amount recorded in `deferredPayout` and emitted as `PayoutDeferred`, retryable permissionlessly. Deferred amounts stay accounted and are explicitly excluded from unaccounted-EVM recovery.

**Recovery is bounded, never a fund-mover.**

| Function | Bound |
|---|---|
| `opsRecoverEvm(token)` | Only the balance above `accounted + deferredPayoutTotal`. For the two accounted tokens it additionally requires an idle engine. |
| `opsRecoverCoreSpot(dirToken)` | Requires idle, **no pending exit** (`ExitPending`) **and** strictly flat (`_position().szi == 0`, else `NotFlat`); recovers only the Core spot balance above recorded principal. |
| `opsRecoverPerpSurplus()` | Same `_requireIdleFlat` gate — idle, no pending exit, strictly flat — reconciles first, and reserves `perpMargin6 + pendingHarvest6`; only genuine funding surplus above both is recoverable. Two-phase perp→spot→EVM→owner. |

All three pay the **owner** only. None of them can touch accounted principal, and none can create authority.

---

## 5. `src/core/B4Pool.sol`

**Responsibility.** The shared reward basket for one descriptor set: settlement intervals, checkpoint prices, per-vault weights, and in-kind distribution. Deployed by `B4Factory.createPool`; `factory`, `oracle` and `assetCount` are immutable. Asset index `0` is always the settlement descriptor; indices `1..N` are the directional descriptors, `N ≤ MAX_DIRECTIONAL = 8`, keyed by full `descriptorHash`. Duplicate descriptors, or two descriptors sharing an `evmToken` or `coreToken`, are rejected at construction.

```solidity
function advance() external returns (bool materialized);            // permissionless
function lockPrices(uint256 id) external;                           // permissionless
function reportWeight(uint256 id, uint256 weight) external;         // registered vaults only
function claimFor(uint256 id, address vault) external;              // permissionless
function sweep(uint256 id) external;                                // permissionless
function capture() external;                                        // permissionless
function registerVault(address vault) external;                     // factory only

// views
function intervalInfo(uint256 id) external view returns (uint64 pointTime, uint64 lockedAt, bool swept, uint256 totalWeight);
function lockedPxWad(uint256 id, uint256 assetIndex) external view returns (uint256);
function bucketOf(uint256 id, uint256 assetIndex) external view returns (uint256);
function remainingOf(uint256 id, uint256 assetIndex) external view returns (uint256);
function weightOf(uint256 id, address vault) external view returns (uint256);
function claimedOf(uint256 id, address vault, uint256 assetIndex) external view returns (bool);
function currentReportable() external view returns (bool exists, uint256 id);
function descriptorIndexPlusOne(bytes32) external view returns (uint256);
function asset(uint256 i) external view returns (CoreTypes.AssetDescriptor memory);
function reportDeadline(uint256 id) external view returns (uint256);
```

Behavior worth knowing:

- **`advance`** materializes at most one passed settlement point per call and turns the accrued inventory into that interval's bucket. `lastPointTime` is monotonic, so points of a superseded epoch that were never reached are skipped by construction.
- **`lockPrices`** is all-or-nothing: it commits only if *every* directional asset prices non-zero inside `Calendar.SNAPSHOT_WINDOW` (24 hours — the settlement day); otherwise it reverts so a later call in the window retries. Settlement USDC is fixed at 1 USD. Missing the window makes that interval unreportable — a liveness cost, not a custody one: settle may skip it, so the fee and reward weight are measured over the combined span at the next checkpoint.
- **`reportWeight`** accepts only registered vaults (`NotAVault`), once per vault per interval, only after prices are locked and before `reportDeadline = pointTime + SNAPSHOT_WINDOW + REPORT_WINDOW` (2 days).
- **`claimFor`** opens after the report window closes and pays the **vault's owner**, in kind, per asset: `nominal = bucket · w / W`, and on shortfall `actual = nominal · balance / liability` — reduced per claim, so the outcome is order-independent. **No internal swap ever happens.** A hostile basket token that reverts on `balanceOf` or on `transfer` defers only its own claim (`ClaimDeferred`) and leaves the healthy tokens payable and itself retryable.
- **`sweep`** rolls an expired interval's unclaimed inventory back into `accruing` exactly once, leaving liability unchanged.
- **`capture`** turns any balance above recorded liability into inventory — measured receipt only. This is also how an exit penalty enters the pool: the vault transfers, then calls `capture()`. A donation becomes pool inventory, never vault profit.
- Untrusted token reads go through `_safeBalanceOf`: a `staticcall` with gas capped at `TOKEN_READ_GAS = 100_000` and the return copy bounded to 32 bytes, so a hostile token can neither revert, OOG, nor return-bomb the loop.

**The pool may NOT:** be administered, paused or upgraded; hold authority over any vault; swap assets; or grow its liability other than by measured receipt.

---

## 6. `src/core/HalvingOracle.sol`

**Responsibility.** Hold the proven Bitcoin halving fact — `halvingHeight`, `halvingTs`, `epoch` — as the single time anchor every calendar computation reads. It is a LayerZero V2 receiver; `endpoint`, `srcEid`, `srcSender` are immutable.

```solidity
function lzReceive(Origin calldata origin, bytes32, bytes calldata message, address, bytes calldata) external payable;
function timeSinceHalving() external view returns (uint256);
function latest() external view returns (uint256 height, uint256 ts, uint256 epoch_);
function renounceDelegate() external;                      // current delegate, one-shot
function allowInitializePath(Origin calldata) external view returns (bool);
function nextNonce(uint32, bytes32) external pure returns (uint64);
```

Acceptance rules in `_accept`:

- `msg.sender` must be the endpoint (`OnlyEndpoint`) and the origin must match `(srcEid, srcSender)` exactly (`UntrustedPath`).
- The header hash and the timestamp are **re-derived from the raw 80-byte header** via `BtcHeader`, never taken from the message envelope.
- Height must be a nonzero multiple of `HALVING_PERIOD = 210_000` and exactly `halvingHeight + 210_000` (`NotNextHeight`); the timestamp must be strictly increasing (`NonMonotonicTimestamp`) and not in the future (`FutureTimestamp`).
- Delivery is idempotent by height: an exact re-delivery is a no-op, a conflicting one reverts `ConflictingFact`.
- **Deliberately no wall-clock interval window** — a predicted-time window could permanently halt an un-upgradeable calendar.

`renounceDelegate()` is the one-shot permanent removal of the temporary LayerZero configurator (`delegate` → `address(0)`, `endpoint.setDelegate(address(0))`, `delegateRenounced = true`). The contract header states the delegate **must** be removed before production; treat this as a deployment gate, not an optional step.

**It may NOT:** custody user funds (none ever pass through it), rewrite or roll back an accepted fact, skip a halving, or accept a fact from any path but the configured one.

---

## 7. `src/citrea/HalvingProver.sol`

**Responsibility.** The Citrea-side publisher of the halving fact. Immutables: `endpoint`, `lightClient`, `dstEid`, `receiver`.

```solidity
function publish(uint256 height, bytes calldata header, bytes calldata options) external payable;  // permissionless
function quote(uint256 height, bytes calldata header, bytes calldata options) external view returns (MessagingFee memory);
function renounceDelegate() external;                                                              // delegate, one-shot
```

`publish` rejects a height that is not a nonzero multiple of 210,000 (`BadHeight`), hashes the supplied header with `BtcHeader.hash`, and requires it to equal `lightClient.getBlockHash(height)` (`HashMismatch`) before sending `(height, header)` over LayerZero. Anyone may publish; the message carries no trusted data beyond the light-client binding, because the receiver re-derives everything. Like the oracle, the prover carries a temporary LayerZero `delegate` set in its constructor and removable only once via `renounceDelegate()` — an endpoint-configuration role that can neither publish nor alter a fact, and the same pre-production removal gate applies.

**Integration caveat carried in the source:** the concrete Citrea light-client identity, the exact selector, and the hash byte-order convention are **funded integration gates** (`spec/SECURITY_MODEL.md` §5.12). A selector mismatch would revert every publication and stall the calendar; the documented remedy is a thin permissionless read adapter, which adds no trust.

**It may NOT:** custody user funds (only the LayerZero gas fee passes through), publish an unproven header, or influence what the receiver derives.

---

## 8. `src/periphery/Keeper.sol`

**Responsibility.** One permissionless crank that touches *every* protocol step. It has **no privilege whatsoever** — every call it makes is a public function anyone could call directly.

```solidity
function crank(B4Pool pool, address[] calldata vaults, uint256 maxVaultSteps) external;

// self-guarded wrappers (require msg.sender == address(this))
function crankVault(B4Vault v, uint256 maxVaultSteps) external returns (uint256 advanced);
function settleVault(B4Vault v, uint256 reportId) external returns (bool);
function retryDeferred(B4Vault v) external returns (uint256);
```

`crank` performs, each step isolated in `try/catch` so one unavailable step never strands the rest: `pool.advance()` in a loop → `pool.lockPrices(latest)` → `pool.sweep(id)` for each expired interval in a bounded catch-up window (`SWEEP_LOOKBACK = 16`, walking back from the second-newest interval) → `pool.capture()` → per vault `crankVault` (up to `maxVaultSteps` `vault.crank()` calls), `settleVault` when an interval is reportable, `pool.claimFor(latest, vault)`, and `retryDeferred`.

The three wrappers are `external` but self-guarded with `require(msg.sender == address(this), "self")`. They exist because a high-level call into a **codeless** address reverts via the compiler's `extcodesize` pre-check in the *caller's* frame, which a local `try/catch` cannot catch — routing through an external self-call keeps that revert inside a catchable external call, so one malformed vault entry can never roll back the whole crank.

`retryDeferred` walks the four route participants (`owner`, `operator`, `referrer`, `pool`) across the two accounted tokens and retries any nonzero deferred payout.

**It may NOT:** choose a target, market, price, size or recipient; move funds to itself; or unlock anything a direct caller could not. The Keeper is a convenience, not a dependency — anyone can drive the same steps by hand.

---

## 9. `src/periphery/ReferenceStrategies.sol`

**Responsibility.** The reference product ladder. Each is a standalone contract implementing a single pure function.

```solidity
interface IStrategy {
    function targets() external view returns (int256 growth, int256 fall);
}
```

| Contract | `(growth, fall)` |
|---|---|
| `StrategyMini` | `(1, 1)` — hold spot in both regimes |
| `StrategyB4` | `(1, 0)` — fall-regime rotation into USDC |
| `StrategyPro` | `(1, −1)` — full `1×` short in the fall regime |
| `StrategyProMax` | `(φ, −φ)` — leveraged expression, `|n| = φ` |

All four are `pure`. **Strategies hold no authority over funds** — they are read exactly once, at `selectPolicy` / `initialize`, and the resolved targets are stored in the vault. Mutating or replacing a strategy contract afterwards cannot change any existing vault's behavior unless its owner re-selects. The core stores no product names; a strategy is just a number pair.

---

## 10. `src/venue/` — the HyperCore boundary

Four libraries; none holds state or funds.

### `CoreTypes.sol`
Venue addresses (`CORE_WRITER = 0x33…33`, the read precompiles `0x800`–`0x810`, `SYSTEM_ADDRESS_BASE = 0x2000…00`), action ids (`ACTION_LIMIT_ORDER = 1`, `ACTION_SPOT_SEND = 6`, `ACTION_USD_CLASS_TRANSFER = 7`, `TIF_IOC = 3`, `SPOT_ASSET_OFFSET = 10_000`), the read shapes (`Position`, `SpotBalance`, `PerpAssetInfo`, `SpotInfo`, `TokenInfo`), the `AssetDescriptor` struct, `descriptorHash`, and `systemAddress(coreToken)`. Its own header states plainly that the **live semantics** of all of this — atomicity, activation, gas, decimals, lot rounding — are funded release gates; local mocks implement the same ABI but cannot prove venue behavior.

### `CoreReader.sol`
`staticcall` wrappers over the read precompiles: `position`, `spotBalance`, `withdrawable`, `markPx`, `oraclePx`, `spotPx`, `perpAssetInfo`, `spotInfo`, `tokenInfo`, `coreUserExists`, plus the price normalizers `spotPxWad` (spot px carries `8 − szDecimals` decimals) and `perpPxWad` (`6 − szDecimals`). Reverts `PrecompileFailed` on a failed read. Its contract comments carry the two load-bearing distinctions: **spot balance is the reliable balance** (decreased only by our own actions; external transfers can only add), while **`withdrawable` is PnL-driven and externally toppable and must never be a completion or retry counter** — it is used only to size clamps and to measure surplus.

### `CoreWriterLib.sol`
Action encoding and emission: `iocOrder(asset, isBuy, limitPx, sz, reduceOnly)` (rejects zero size as defense in depth; `limitPx`/`sz` are `1e8` fixed point, deliberately *unlike* the szDecimals-scaled read conventions — callers convert), `spotSend(destination, token, weiAmount)`, `usdClassTransfer(ntl, toPerp)`. Header restates the rule: **emitting an action is not evidence it executed.**

### `DescriptorLib.sol`
Descriptor validation and unit conversion. `verifyDirectional` rejects a `fixedUsd` descriptor or one colliding with the settlement token, verifies the spot pair is exactly `(coreToken, settlement.coreToken)`, bounds `spotSzDecimals ≤ 8`, and for a perp-bearing descriptor rejects ids above `uint16` (`PerpIdUnsupported` — the legacy position precompile takes a `uint16`, so a wider id would silently alias an unrelated market), bounds `perpSzDecimals ≤ 6`, rejects isolated-only perps (`PerpNotCrossMarginable`), and matches `szDecimals` / `maxLeverage`. A spot-only descriptor must zero its perp fields. `verifySettlement` requires `fixedUsd`. `_verifyToken` rejects a `coreToken` wider than `uint32`, sanity-checks decimal spreads, and cross-checks `evmContract` / `weiDecimals` / `szDecimals` / `evmExtraWeiDecimals` against the token-info precompile. `evmToCore` clamps to `uint64` rather than truncating; `coreToEvm` floors.

> **The token↔perp association itself has no canonical on-chain statement.** The immutable descriptor supplies it, and the user must verify it before signing (`spec/SECURITY_MODEL.md` §3).

---

## 11. `src/libraries/`

| Library | Responsibility |
|---|---|
| `Phi.sol` | Fixed-point math and protocol constants. `WAD = 1e18`; `PHI`, `PHI_SQ`, `INV_PHI`; fee `FEE_F = φ⁻⁵/2`; exit penalty `EXIT_Q = φ⁻³/2`; `MAX_OPERATOR_BPS = 3819`, `MIN_REFERRER_BPS = 3819`; policy bounds `MAX_BASE_TARGET = MAX_SCALE = 10e18`. Full-precision `mulDiv` (512-bit product, reverts on overflow or zero divisor), `wmul`, `bps`, `min`, `max`, `abs`. **Every division floors toward the protocol** — fees, penalties, cuts and pool claims never round up. |
| `StructuralLeverage.sol` | Pure leverage math: `L = min(g·p/(p−floor), p/(p−cap))` for a leveraged long, bounded by the cycle's confirmed structural lows ([SPECIFICATION §7b](../spec/SPECIFICATION.md)), with the `(floor, cap)` anchors ratcheted on-chain by `B4Pool.sampleAnchor`. Unit tests pin the March-2020 survival case, the ratchet flip and genesis. **NOT consumed by the engine yet** — the `B4VaultEngine._planPerpStep` wiring was reverted after the 2026-07-21 audit (it never posted `margin = notional/L`, and re-levered a held position at the halving); the engine sizes leveraged perps flat-`φ`. See `../AUDIT-2026-07-structural-leverage.md` and `../PROPOSAL-structural-leverage.md`. |
| `Calendar.sol` | Pure cycle geometry over `t = now − halvingTs`. `CYCLE = 1460 days`, `W = 20 days`, `H = 10 days`, pivots `P = CYCLE/φ²` (growth→fall) and `T = CYCLE/φ` (fall→growth), `SNAPSHOT_WINDOW = 24 hours`, `REPORT_WINDOW = 2 days`, `POST_FACT_FREE_EXIT = W`. `zoneAt` (7 zones), `targetAt` (piecewise split at zero for opposite-sign or zero-endpoint pairs; **strictly same-sign pairs interpolate directly and never synthesize a zero** — so `StrategyMini` (1,1) never trades, yet is still fee'd on interval profit), `decompose(n)` = `spot = clamp(n, 0, 1); perp = n − spot`, `depositOpen`, `freeExit`, `nextSettlementPoint` (the two fixed instants `P−H` and `T+H` per epoch). After `T+W` the calendar rests in terminal growth until the next accepted fact. |
| `BtcHeader.sol` | The 80-byte header binding: `hash` = dSHA256 in Bitcoin-internal byte order, `timestamp` = little-endian `uint32` at offset 68, `HALVING_PERIOD = 210_000`, `HEADER_LENGTH = 80`. The light client's stored byte-order convention is a funded integration gate. |
| `SafeTransfer.sol` | Minimal ERC-20 helpers tolerating missing/malformed return data. `safeTransfer` / `safeTransferFrom` revert on failure; **`tryTransfer` never reverts, whatever the token returns** — the fail-soft pool claim path and the pay-or-defer payout path depend on that. Gas forwarded to a token is capped at 500,000 and the return copy at 32 bytes, so a hostile token can neither return-bomb nor gas-drain a loop. Directional assets are required to be plain ERC-20s; rebasing and fee-on-transfer tokens are excluded by `spec/SECURITY_MODEL.md` §4. |

`src/interfaces/` holds only the minimal external surfaces: `IERC20`, `IStrategy`, `IHalvingOracle`, and the LayerZero V2 structs/interfaces (`Origin`, `MessagingParams`, `MessagingFee`, `MessagingReceipt`, `ILayerZeroEndpointV2`, `ILayerZeroReceiver`).

---

## 12. Authority summary

| Actor | Can do | Cannot do |
|---|---|---|
| Vault owner | `selectPolicy`, `deposit`, `initiateExit`, the three bounded `recover*` calls, `emergencyClearRecovery` | Change owner, pool, descriptors, or fee route; move accounted principal outside the exit path; touch another vault or the pool |
| Anyone (keeper) | `crank`, `settle`, `claimDeferred`, `pool.advance/lockPrices/claimFor/sweep/capture`, `prover.publish` | Choose target, market, price, size or recipient; redirect any payout |
| Operator / referrer | Receive the in-kind performance cut recorded in the immutable route | Alter the route, the policy, or any accounting |
| Factory | Deploy pools, deploy + initialize + register vaults | Hold funds, re-point the vault implementation, endorse anything |
| LayerZero delegate (temporary, deploy-time) | Configure the `HalvingOracle` / `HalvingProver` LayerZero endpoint settings until `renounceDelegate()` is called | Touch funds, vaults, pools, targets or accepted facts; re-acquire the role once renounced |
| Anyone else | — | Outside that one delegate role there is no admin, no pause, no upgrade, and no privileged fund mover; the vault, pool and factory contracts have no administrative surface at all |

Deliberate exclusions matter as much as inclusions: carry-style operation is an explicit **exclusion** (`spec/SECURITY_MODEL.md` §4), and the protocol targets exactly one venue — HyperEVM + HyperCore.

---

## Further reading

- [`ARCHITECTURE.md`](../ARCHITECTURE.md) — deep design rationale for every boundary above
- [`INVARIANTS.md`](../INVARIANTS.md) — the invariant list these contracts are built to preserve
- [`REPORT.md`](../REPORT.md) — status dossier and internal adversarial-review rounds; an independent external audit is a mandatory unmet release gate · [`SLITHER.md`](../SLITHER.md) — static-analysis triage
- [`spec/SPECIFICATION.md`](../spec/SPECIFICATION.md) · [`spec/WHITEPAPER.md`](../spec/WHITEPAPER.md) · [`spec/HAZARDS.md`](../spec/HAZARDS.md) · [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) · [`spec/REQUIREMENTS.md`](../spec/REQUIREMENTS.md) · [`spec/TEST_PLAN.md`](../spec/TEST_PLAN.md)
