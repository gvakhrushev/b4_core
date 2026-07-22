# Overview

One page of orientation: what B4 is, the problem it addresses, the product ladder, the three
external anchors it is forced into, and how little authority anyone holds over your funds.

> **Status: pre-mainnet, not externally audited.** Nothing here implies production-readiness.
> Several venue semantics (CoreWriter action atomicity, fresh-account activation, precompile
> behavior and gas) are not provable off-chain and are mandatory funded release gates —
> see [`../spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §5 and
> [`../REPORT.md`](../REPORT.md).

## What B4 is

B4 is non-custodial on-chain infrastructure that executes a long-horizon, Bitcoin-cycle hold
rule. You deposit a liquid directional asset plus canonical USDC into an isolated vault you
own, and you select two target exposures — one for the growth regime, one for the fall regime.
Time since the latest *proven* Bitcoin halving deterministically selects and continuously
interpolates the active target. There is one external fact (the halving), one execution venue
(HyperEVM + HyperCore), one accounting model, and no admin.

A vault is an EIP-1167 clone of `B4Vault` produced by the permissionless `B4Factory`:

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
```

`msg.sender` becomes the fixed owner and signs the entire configuration — pool, asset
descriptor, policy, scale, slippage, and the immutable fee route — by sending that one
transaction.

## The problem

The reference participant is not flat. They are a **long-horizon holder who already bears the
full cyclical drawdown** (historically on the order of 75–85% peak-to-trough per four-year
cycle — an external observation, not a protocol-derived figure) as the standing cost of long
exposure. B4 is evaluated against *that* holder, not against cash.
Its objective is to reduce already-accepted holding risk without surrendering custody, by
answering four questions with the smallest trusted surface: which regime is active, what
exposure to hold, how that exposure is executed and verified, and how long-term participation
and early exit are accounted for.

## The product ladder

Reference strategies live in [`src/periphery/ReferenceStrategies.sol`](../src/periphery/ReferenceStrategies.sol).
They are **view-only**: each returns a `(growth, fall)` target pair via `targets()` and holds no
authority over funds. The core stores no product names — the pair is read once, at selection.

| Product | Growth | Fall | Adds vs. previous |
|---|---:|---:|---|
| `StrategyMini` | `1` | `1` | hold spot in both regimes; earns shared-Pool yield, trades nothing |
| `StrategyB4` | `1` | `0` | a fall-regime rotation into USDC |
| `StrategyPro` | `1` | `-1` | a full `1×` short in fall — the mirror of the long |
| `StrategyProMax` | `φ` | `-φ` | leveraged expression of the same signs, `\|n\| = φ` |

`φ = 1.618033988749894848` (WAD). Each rung is the previous one plus one more interior move at
the two cycle pivots. How much accepted holding risk to keep is your dial; the protocol takes no
directional view on your behalf.

Where a rung carries leverage, the leverage is itself a safety mechanism: the position's
liquidation is placed by margin size at a *structurally confirmed* extreme — the cycle's
confirmed low for a long, its confirmed peak for a short — never at a distance an ordinary
swing can reach ([SPECIFICATION §7b](../spec/SPECIFICATION.md); verified on every completed
cycle in [the benchmark](11-backtest.md)).

Every product uses the same decomposition for a signed WAD target `n`:

```
spot = clamp(n, 0, 1)
perp = n - spot
```

Spot expresses exposure in `[0, 1]`; a perpetual position expresses only the residual that spot
cannot. A scale multiplies both, subject to the absolute ceiling `φ`.

Boundaries are a pure function of block time. The reference geometry
([`src/libraries/Calendar.sol`](../src/libraries/Calendar.sol)) is a `1460`-day cycle with the
growth→fall pivot at `cycle/φ²`, the fall→growth pivot at `cycle/φ`, and 20-day transitions
(`W`), split at zero (`H = 10 days`) whenever the two targets differ in sign or one is zero — so
a derivative sign change always passes through a verified zero. Strictly same-sign pairs
interpolate directly and never synthesize a zero; Mini therefore stays constant and trades
nothing, while its interval profit is still fee'd at settlement.

## The three forced external anchors

Decomposing the design determines exactly three external objects, and in each case the
trust-minimizing choice is effectively unique
([`../spec/WHITEPAPER.md`](../spec/WHITEPAPER.md) §6):

| Anchor | Why it is forced | Where it lands |
|---|---|---|
| Regime clock | needs Bitcoin height + time proven on-chain | Citrea light client; `src/citrea/HalvingProver.sol` publishes the fact, `src/core/HalvingOracle.sol` receives it over LayerZero and exposes `timeSinceHalving()` / `latest()`; the 80-byte header is re-verified |
| Negative exposure | needs the deepest perpetual venue; a shallower or self-made market adds assumptions | HyperCore, reached through `src/venue/*` (precompile reads, CoreWriter action encoding) |
| Settlement | needs a fiat-reachable, Core/EVM-fungible USD asset | canonical USDC, fixed once as the factory's settlement descriptor and validated by `DescriptorLib` for the fixed-USD flag and venue-consistent token/decimals; that the configured token *is* canonical USDC is a deployment parameter and a funded verification gate ([`SECURITY_MODEL`](../spec/SECURITY_MODEL.md) §5) |

Trust in these is disclosed as *residual after an optimal, and here essentially unique,
selection* — not as an accident of convenience.

## Execution and accounting, in one breath

Execution is **asynchronous**. Emitting a CoreWriter action is not evidence it executed;
completion must be proven by a later Core state read of a self-moved balance, and accounting
measures **actual received balance deltas**, never requested amounts. Donations and favorable
overfills stay unaccounted and separately recoverable (`recoverEvm`, `recoverCoreSpot`,
`recoverPerpSurplus`). At a checkpoint, profit over the entry ledger is fee'd: the operator cut
is paid in kind from the EVM basket, and the client share becomes reward weight in the shared
`B4Pool`. Early exit outside a free window withholds a single in-kind penalty; the
operator/referrer payment is carved *out of* that penalty (never added to it) and only the
residual funds the Pool. Pool inventory is distributed in kind, pro rata to recorded weight,
with no internal swap.

Anyone can push the machine forward — `crank()`, `settle(intervalId)`, `claimDeferred(...)` on
the vault, and `advance()` / `lockPrices(id)` / `claimFor(id, vault)` / `sweep(id)` /
`capture()` on the pool — batched by the permissionless
[`Keeper`](../src/periphery/Keeper.sol):

```solidity
function crank(B4Pool pool, address[] calldata vaults, uint256 maxVaultSteps) external;
```

Weight is *not* in that list: `reportWeight` is reported by the vault itself from inside
`settle`, and the pool rejects any other caller (`NotAVault`). A keeper cannot choose the
target, speed, market, or slippage.

## Minimal authority

There is no governance executor, no upgrade proxy, no pause, and no privileged fund transfer.
Owner-only vault entrypoints are `selectPolicy`, `deposit`, `initiateExit`, `recoverEvm`,
`recoverCoreSpot`, `recoverPerpSurplus`, and `emergencyClearRecovery`; everything else is
permissionless or a view (`currentTarget`, `navWad`, `strategyValueWad`), except the one-shot
`initialize`, which the factory calls atomically at creation and which can never run twice
(`AlreadyInitialized`). Operators supply interfaces, routing, and keepers and compete on a
client-signed, per-vault fee route fixed at creation — they cannot move funds or choose the
halving fact. **Pool creation is permissionless
and is not endorsement**: a pool's asset descriptors are validated against the venue, and
nothing more. Each LayerZero-side contract has one temporary configurator whose delegate must be
permanently removed before production (`renounceDelegate()`).

## Where to go next

- [`../spec/WHITEPAPER.md`](../spec/WHITEPAPER.md) — the thesis, the ladder, and why the three
  anchors are forced.
- [`../spec/SPECIFICATION.md`](../spec/SPECIFICATION.md) — normative behavior: policy, calendar,
  settlement, exit arithmetic.
- [`../spec/HAZARDS.md`](../spec/HAZARDS.md) — the design traps that make the async and
  accounting layers hard.
- [`../spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) — trust model, safety invariants,
  deliberate exclusions (§4), and the funded release gates (§5).
- [`../spec/REQUIREMENTS.md`](../spec/REQUIREMENTS.md) and
  [`../spec/TEST_PLAN.md`](../spec/TEST_PLAN.md) — requirements and the mandatory regression plan.
- [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — contract map, async discipline, design decisions.
- [`../INVARIANTS.md`](../INVARIANTS.md) — invariant → test traceability, with honest gaps.
- [`../REPORT.md`](../REPORT.md) — the security dossier: what is proven locally vs. what remains
  a funded gate, plus the internal audit history.
- [`../SLITHER.md`](../SLITHER.md) — static-analysis triage.
