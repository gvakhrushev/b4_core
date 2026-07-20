# Keeper operations

How to run B4's permissionless crank: what `Keeper.crank` does, in what order, how often to call it, and why a keeper never holds any authority over funds.

> Status: B4 is **pre-mainnet and not externally audited**. Venue semantics (CoreWriter action execution, Core account activation, precompile behaviour) are not locally provable and are mandatory funded release gates — see [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §5.

---

## 1. Why a crank exists at all

Two properties of the protocol make an external, permissionless prod necessary.

**Execution is asynchronous.** A vault interacts with HyperCore by emitting CoreWriter actions. Emitting an action is *not* proof that it executed. Completion is proven only by a later read of Core state showing a self-moved balance, and accounting always measures the *actual* received delta, never the requested amount. So a vault step is inherently two-phase: something is emitted in one transaction, and verified in a later one. `B4Vault.crank()` is that later transaction:

```solidity
/// @notice Permissionless: advance the pending intent, else one exit step, else one
///         sync step. Liveness only — a keeper cannot choose target, market, price or
///         recipient (F2).
function crank() external nonReentrant returns (bool progressed);
```

It verifies a pending intent if one exists (`_verifyIntent`), otherwise delegates one planning step to `B4VaultOps.opsPlanStep` — an exit step when `exitShareWad != 0`, else a sync step toward the current calendar target.

**The calendar has to be materialized.** Settlement points derive from the proven halving fact in `HalvingOracle`, but nothing in the EVM fires at a timestamp. `B4Pool.advance()` is what turns a passed point into an on-chain interval:

```solidity
function advance() external nonReentrant returns (bool materialized);
```

Everything downstream — price locking, weight reporting, distribution, sweeping — is likewise a call somebody has to make. `Keeper` is the single contract that makes all of them, in the right order, in one transaction.

---

## 2. `Keeper.crank` step by step

```solidity
function crank(B4Pool pool, address[] calldata vaults, uint256 maxVaultSteps) external;
```

Pool-level phase, then a per-vault loop. Every per-vault call and every optional pool step is individually `try`/`catch`-wrapped, so an unavailable step is skipped rather than reverting the batch. There is exactly one unwrapped call: `pool.intervalCount()` (`Keeper.sol:33`). The `pool` argument is assumed to be a genuine `B4Pool`, so a pool address that is codeless or reverts on that view reverts the whole crank instead of degrading. Only the caller-supplied `vaults[]` entries are protected against being malformed — see §3.

| # | Call | Effect |
|---|---|---|
| 1 | `pool.advance()` in a loop until it returns `false` | Materializes every passed settlement point (bounded — 2 points per epoch) |
| 2 | `pool.lockPrices(count - 1)` | Locks checkpoint prices for the newest interval; all-or-nothing, reverts unless every directional asset prices non-zero |
| 3 | `pool.sweep(count - back)` for `back = 2 .. window + 1` | Rolls unclaimed inventory of expired intervals back into the accruing basket; `window = min(count - 1, SWEEP_LOOKBACK = 16)` |
| 4 | `pool.capture()` | Turns any balance above recorded liability (donations, exit penalties) into pool inventory |
| 5 | `pool.currentReportable()` | Reads `(exists, id)` — the latest interval whose report window is still open |
| 6 | `this.crankVault(v, maxVaultSteps)` | Up to `maxVaultSteps` vault cranks; stops early on the first non-progressing or reverting step |
| 7 | `this.settleVault(v, reportId)` | Only if step 5 said reportable — `v.settle(reportId)` |
| 8 | `pool.claimFor(count - 1, vaults[i])` | Distributes the latest interval in kind to that vault's recorded owner |
| 9 | `this.retryDeferred(v)` | Retries every deferred payout for the vault's route participants |

Steps 6–9 run per entry of `vaults[]`. The function ends with `emit Cranked(address(pool), vaults.length, advanced)`, where `advanced` counts the steps that actually made progress — a useful health signal for an operator's monitoring.

Two details worth internalising:

- **The sweep window is a catch-up window, not a single interval.** If several intervals materialized while no keeper was running, each expired-unswept one still has to roll its inventory forward. `sweep()` is idempotent — `AlreadySwept` / `NotExpired` revert into the `try`/`catch` — so the loop only ever advances legitimate state, and `SWEEP_LOOKBACK = 16` keeps it bounded.
- **Only the latest interval is claimed.** Older intervals were served while they were the latest and are swept before they fall to `count - 2`, so claiming further back would be a no-op.

### `retryDeferred` in detail

A payout is deferred when its ERC-20 transfer fails, so the failing token never blocks the healthy ones. The keeper walks the full recipient × token matrix:

```solidity
(address operator,, address referrer,) = v.route();
address[4] memory recipients = [v.owner(), operator, referrer, v.pool()];
address[2] memory tokens = [v.dirDescriptor().evmToken, v.usdcDescriptor().evmToken];
```

Zero-address recipients and zero balances are skipped; each `v.claimDeferred(recipient, token)` is `try`/`catch`-ed. The recipient set is read from immutable vault state — the keeper cannot introduce one.

---

## 3. The self-guarded wrapper pattern

Three per-vault calls go through external wrappers on the keeper itself:

```solidity
function crankVault(B4Vault v, uint256 maxVaultSteps) external returns (uint256 advanced);
function settleVault(B4Vault v, uint256 reportId) external returns (bool);
function retryDeferred(B4Vault v) external returns (uint256);
```

Each begins with `require(msg.sender == address(this), "self")`, so they are not an external surface — they exist purely so `crank` can `try this.crankVault(...) { } catch { }`.

**Why the indirection.** `vaults[]` is caller-supplied and unvalidated. A high-level Solidity call to a codeless address reverts on the compiler's `extcodesize` pre-check, and that revert happens in the **caller's** frame — a `try`/`catch` written inline in `crank` does *not* catch it. Routing through an external self-call moves the pre-check inside a real `CALL`, where the revert is contained and caught. Result: one malformed, self-destructed, or simply wrong `vaults[]` entry degrades to a skipped entry instead of rolling back the entire crank, including all the pool-level work already done for everyone else.

The same isolation is applied to the pool's optional steps: even `pool.currentReportable()` is wrapped, so a transient pool revert leaves `reportable == false` and the crank continues with the remaining steps. The one exception remains `pool.intervalCount()` (§2), which is called bare.

---

## 4. Cadence

Timing constants live in `src/libraries/Calendar.sol`:

| Constant | Value | Meaning |
|---|---|---|
| `CYCLE` | `1460 days` | Nominal cycle length (geometry only — the realized halving interval need not match it; the epoch is anchored on the accepted fact from `HalvingOracle`) |
| `W` | `20 days` | Transition width |
| `H` | `10 days` | Half-transition. Fixes the zone boundaries and the two settlement points (`t = P−H`, `t = T+H`) for **all** pairs; it is additionally the split-at-zero midpoint only on the piecewise (opposite-sign / zero-endpoint) interpolation path |
| `SNAPSHOT_WINDOW` | `24 hours` | The **settlement day** — the window after a point in which `lockPrices` is accepted (the first 24h of the opening half-transition) |
| `REPORT_WINDOW` | `2 days` | Window after the snapshot window in which vaults may report weight |
| `POST_FACT_FREE_EXIT` | `W` | Free-exit window following the proven fact |

Recommended operating pattern:

- **Baseline:** run `crank` on a routine schedule (minutes-level) whenever any pool has live vaults. Idle cranks are cheap — `advance()` returns `false`, vault cranks return `false`, everything else reverts into a `catch`.
- **Around transitions:** during a 20-day transition window — which `H` always divides into two 10-day halves, and which an opposite-sign or zero-endpoint pair additionally crosses zero at — the calendar target moves continuously, so vaults are actively re-syncing. Minutes-level cadence here keeps each async leg verified promptly and keeps rebalances near their target.
- **At and immediately after a settlement point:** `lockPrices` is accepted only within `SNAPSHOT_WINDOW = 24 hours` of the point — the settlement day. Lock **early**, ideally at `pointTime`: the window's width is deliberate slack for recovering from a dead cron, not licence to shop for a price, and locking early is in the vault owner's own interest (a lower locked price means a smaller fee). Missing the day entirely is not catastrophic — see below.
- **Through the report window:** `settle` requires an idle engine, and it must land before `reportDeadline(id) = pointTime + SNAPSHOT_WINDOW + REPORT_WINDOW`. An in-flight leg completes within `RESEND_TIMEOUT ≈ 1 hour`, comfortably inside a >2-day window, so steady cranking through the window is enough.
- **After the report window closes:** claims open (`claimFor` reverts with `ReportWindowOpen` until then). Keep cranking so distribution happens before the interval expires and is swept.

Sizing `maxVaultSteps`: it bounds the vault cranks per vault per transaction. Small values (a handful) keep gas predictable across a large `vaults[]`; larger values let a single vault burn through a backlog. Since `crankVault` breaks on the first non-progressing step, an over-large value costs nothing in the steady state.

---

## 5. A keeper has no privilege

Everything `Keeper` calls is permissionless by design. There is no keeper allowlist, no registration, no reward wired into the contract, and no way for the caller to influence outcomes:

- **Targets** come from the stored policy (`growthTarget` / `fallTarget`, resolved by a single `IStrategy.targets()` read at vault initialization and re-resolvable only by the vault owner via `selectPolicy`, which is blocked while an exit is pending — never by a keeper) interpolated by `Calendar` against the oracle fact. Strategies in `ReferenceStrategies` are view-only and hold no authority over funds.
- **Markets** come from the descriptors the factory validated against the venue at deployment.
- **Prices** come from Core reads (`CoreReader.spotPxWad`) inside `lockPrices` and from venue execution — never from a keeper argument.
- **Recipients** are fixed vault state: `claimFor` pays `IB4VaultOwner(vault).owner()`, and `claimDeferred` pays only the recorded recipient.

The only caller-supplied inputs to `crank` are *which* pool, *which* vault addresses, and *how many* steps — i.e. which permissionless work to perform, not what that work does. Anybody can run a keeper; running one confers nothing. This is consistent with the protocol's authority posture: no admin, no upgrade proxy, no pause, no privileged fund mover, and permissionless pool creation that is not endorsement.

---

## 6. Failure posture

**Worst case of any stalled step is delayed liveness, never fund loss.**

| Stalled step | Consequence | Recovery |
|---|---|---|
| `advance()` late | Points materialize late | Loop catches up; `lastPointTime` is monotonic |
| `lockPrices` misses the 1h window | That interval is unreportable | Its inventory is swept forward into the next accruing basket |
| A vault crank reverts | That vault's intent stays pending | Any later call retries; other vaults are unaffected |
| `settle` misses the report window | No reward weight for that interval | Ledger unchanged; the next checkpoint settles normally |
| `claimFor` token transfer fails | That token's payout is deferred | `ClaimDeferred` emitted; `claimed`/`remaining`/`liability` untouched, fully retryable |
| A vault payout transfer fails | Deferred per recipient/token | `claimDeferred` retries it, permissionlessly |
| Keeper contract itself unused | Nothing happens | Every underlying function is independently callable |

Two structural guarantees back this table:

1. **Every step is independently callable.** `Keeper` is periphery convenience only. `pool.advance()`, `pool.lockPrices(id)`, `pool.sweep(id)`, `pool.capture()`, `pool.claimFor(id, vault)`, `vault.crank()`, `vault.settle(id)` and `vault.claimDeferred(recipient, token)` are all permissionless entry points that can be invoked directly from any address. If `Keeper` were unusable, the protocol would still be fully operable one call at a time.
2. **Isolation is enforced at every boundary.** Per-step `try`/`catch`, the self-call wrappers, per-token deferral in `claimFor`, and the revert-free, gas-capped, return-bomb-capped `_safeBalanceOf` used for untrusted basket tokens all exist so that a hostile or broken component degrades to *skipped work*, not to a bricked pool.

Residual liveness risk lives at the venue: an ecosystem-wide HyperCore failure could stall an in-flight intent past a report window. That is documented as a liveness residual, not a custody one.

---

## Further reading

- [`spec/SPECIFICATION.md`](../spec/SPECIFICATION.md) — normative calendar, settlement and exit semantics
- [`spec/HAZARDS.md`](../spec/HAZARDS.md) — hazard register (async execution, keeper liveness, deferred payouts)
- [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) — trust boundaries, deliberate exclusions (§4), funded release gates (§5)
- [`INVARIANTS.md`](../INVARIANTS.md) — invariants a crank must never violate
- [`REPORT.md`](../REPORT.md) — security dossier and internal adversarial audit rounds (an independent external audit and the funded venue gates are still outstanding)
