# 06 — Deployment runbook

Operator procedure for building, deploying, configuring and gating a B4 deployment on HyperEVM + HyperCore, ending in the funded release-gate checklist that must be satisfied before any mainnet use.

> **Status.** B4 is **pre-mainnet and not externally audited**. Nothing in this runbook implies
> production-readiness. The venue semantics B4 depends on (CoreWriter action atomicity, fresh-account
> activation, precompile behavior and gas) are **not provable off-chain** and are mandatory funded
> release gates — see [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §3 and §5.

---

## 1. Prerequisites

| Item | Value / source |
| --- | --- |
| Toolchain | Foundry (`forge`, `cast`) |
| Solidity | `0.8.28`, pinned in `foundry.toml` (`solc_version = "0.8.28"`) |
| EVM version | `cancun` (`evm_version` in `foundry.toml`) |
| Optimizer | enabled, `optimizer_runs = 200` |
| Libraries | vendored under `lib/`, locked by `foundry.lock` |

Pre-release checks (every source release, `SECURITY_MODEL.md` §5 preamble): format, EIP-170 size,
full test suite, static analysis with no surviving high-severity findings.

```bash
forge fmt --check
forge build --sizes
forge test
FOUNDRY_PROFILE=deep forge test --match-path 'test/invariant/*'   # deep invariant profile
```

The `deep` profile in `foundry.toml` raises fuzz runs to 4096 and invariant runs/depth to 512/256.
Static-analysis configuration lives in `slither.config.json`; results and their disposition are
recorded in [`SLITHER.md`](../SLITHER.md) and [`REPORT.md`](../REPORT.md).

Record the exact compiler version, optimizer settings, library commits and source hashes — they are
the input to the reproducible-build manifest required by gate §5.14.

---

## 2. Deployment order

`script/Deploy.s.sol` deploys in this order because the later steps consume earlier addresses as
constructor arguments: `B4Vault` takes `ops`, and `B4Factory` takes `oracle` and
`vaultImplementation`. `B4VaultOps` itself takes no constructor arguments.

1. **`HalvingOracle`** — the LayerZero receiver holding the proven halving fact.
2. **`B4VaultOps`** — the delegatecall'd operations module (separate deployment for EIP-170 /
   EIP-3860 headroom).
3. **`B4Vault` implementation** — `constructor(address ops_)`; reverts on a zero ops address and
   sets `_initialized = true` so the implementation itself can never be initialized.
4. **`B4Factory`** — `constructor(address oracle_, CoreTypes.AssetDescriptor memory settlement_,
   address vaultImplementation_)`; the settlement descriptor is validated against the venue by
   `DescriptorLib.verifySettlement` inside the constructor.

```solidity
HalvingOracle oracle = new HalvingOracle(
    lzEndpoint, srcEid, srcSender, genesisHeight, genesisTs, configurator
);
B4VaultOps ops = new B4VaultOps();
B4Vault implementation = new B4Vault(address(ops));
new B4Factory(address(oracle), usdc, address(implementation));
```

`HalvingProver` (`src/citrea/HalvingProver.sol`) is deployed **separately on the Citrea side** —
`constructor(address endpoint_, address lightClient_, uint32 dstEid_, bytes32 receiver_, address
delegate_)` — and is not part of `script/Deploy.s.sol`. The two sides bind each other **immutably**
and mutually: `HalvingOracle.srcSender` and `HalvingProver.receiver`/`dstEid` are all constructor
immutables with no setter, so neither side can be pointed at the other after deployment. Both
addresses must therefore be fixed up front — e.g. via a deterministic (CREATE2) deployment of the
prover — or one side must be redeployed once the other address is final.

The reference strategy contracts in `src/periphery/ReferenceStrategies.sol` (`StrategyMini`,
`StrategyB4`, `StrategyPro`, `StrategyProMax`) and `src/periphery/Keeper.sol` are also **not**
deployed by the script. Deploy them independently; strategies are stateless contracts whose only
function, `targets()`, is `external pure` and returns a constant `(growth, fall)` pair, and hold no
authority over funds, and the Keeper is a permissionless crank with no privileges.

### Environment variables read by `script/Deploy.s.sol`

| Variable | Type | Meaning |
| --- | --- | --- |
| `LZ_ENDPOINT` | address | LayerZero V2 endpoint on the target network |
| `CITREA_EID` | uint | source endpoint id of the Citrea side |
| `PROVER_ADDRESS_B32` | bytes32 | `HalvingProver` address, bytes32-encoded — the only accepted sender |
| `GENESIS_HALVING_HEIGHT` | uint | deploy-time anchor height; must be non-zero and a multiple of 210000 |
| `GENESIS_HALVING_TS` | uint | timestamp taken from that halving header; non-zero, not in the future |
| `LZ_CONFIGURATOR` | address | temporary LayerZero delegate — removed one-shot after configuration |
| `USDC_EVM` | address | canonical linked USDC EVM token |
| `USDC_CORE_INDEX` | uint | its Core token index |

The settlement descriptor built by the script hard-codes `evmDecimals = 6`, `coreWeiDecimals = 8`,
`spotSzDecimals = 0`, `spotMarket`/`perpMarket` = `CoreTypes.NO_MARKET`, `perpMaxLeverage = 0` and
`fixedUsd = true`. These are placeholders in the script's own words and **must** be confirmed against
the live venue (gates §5.1) — `verifySettlement` will revert on a mismatch with the token-info
precompile, which is the intended failure mode.

```bash
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast --verify
```

---

## 3. What is immutable after deployment

There is **no admin, no upgrade proxy, no pause, and no privileged fund mover** anywhere in the
system (`SECURITY_MODEL.md` §1, "administrative boundary"). Consequently, a mistake in any of the
following requires a full redeployment:

| Fixed at | What is frozen |
| --- | --- |
| `HalvingOracle` constructor | `endpoint`, `srcEid`, `srcSender` (immutables); genesis height/timestamp anchor |
| `B4Vault` implementation constructor | `ops` (the delegatecall target) |
| `B4Factory` constructor | `oracle`, `vaultImplementation`, the stored settlement descriptor |
| `B4Pool` constructor | the full descriptor set (settlement + up to `MAX_DIRECTIONAL = 8` directional assets); duplicate EVM or Core tokens are rejected |
| `B4Factory.createVault` | owner, pool, execution identity, directional descriptor, `slippageBps`, and the `FeeRoute` — all bound atomically in one transaction (no front-run window, no half-initialized state) |

The only mutable per-vault setting is the policy: `selectPolicy(address strategy, uint256 scaleWad)`,
owner-only, and rejected while an exit is pending (`ExitPending`). It re-reads `targets()` once and
re-validates it under the same bounds as creation.

The temporary LayerZero configurator is the single exception to "no privileged role", and it exists
only until step 4.

---

## 4. LayerZero configuration and the mandatory `renounceDelegate()`

Both LayerZero-side contracts (`HalvingOracle` on the destination, `HalvingProver` on Citrea) set
their `delegate_` as the endpoint delegate in their constructors:

```solidity
delegate = delegate_;
ILayerZeroEndpointV2(endpoint_).setDelegate(delegate_);
```

Use that delegate to configure send/receive libraries, DVNs and executor options with the production
stack. Then, **on both sides**, execute the one-shot renouncement:

```solidity
function renounceDelegate() external;   // onlyDelegate, once
// sets delegateRenounced = true, delegate = address(0),
// calls endpoint.setDelegate(address(0)), emits DelegateRenounced()
```

```bash
cast send "$ORACLE" "renounceDelegate()" --rpc-url "$RPC_URL" --private-key "$DELEGATE_KEY"
cast send "$PROVER" "renounceDelegate()" --rpc-url "$CITREA_RPC" --private-key "$DELEGATE_KEY"
```

Verify on-chain — do not trust the transaction receipt alone:

```bash
cast call "$ORACLE" "delegate()(address)"          # expect 0x000...0
cast call "$ORACLE" "delegateRenounced()(bool)"    # expect true
cast call "$PROVER" "delegate()(address)"
cast call "$PROVER" "delegateRenounced()(bool)"
```

Also confirm the endpoint's own delegate mapping for each contract is zero. Renouncement is
irreversible and cannot be repeated (`AlreadyRenounced`). **A deployment whose delegate is still set
is not a production deployment** — this is release gate §5.13.

Independently of the delegate, the oracle's acceptance rules are fixed in code: only
`srcEid`/`srcSender` may deliver; the next accepted height must be exactly `current + 210000`; the
timestamp must be strictly monotonic and not in the future; delivery is idempotent by height and a
conflicting fact reverts. There is deliberately no wall-clock interval window. User funds never pass
through the oracle.

---

## 5. Creating the first pool and vault

Pool creation is **permissionless and is not endorsement** — the factory holds no funds and grants no
authority.

```solidity
function createPool(CoreTypes.AssetDescriptor[] calldata directional)
    external returns (address poolAddr);
```

Each directional descriptor is checked by `DescriptorLib.verifyDirectional` against the venue before
binding:

- it must not be the settlement asset — `fixedUsd` must be `false` and both `evmToken` and
  `coreToken` must differ from settlement (`BadDirectional`);
- token/EVM-contract identity, `weiDecimals`/`szDecimals` and `evmExtraWeiDecimals` against the
  token-info precompile, a `coreToken` that fits `uint32`, `spotSzDecimals ≤ coreWeiDecimals`, and a
  decimal spread ≤ 30;
- `spotSzDecimals ≤ 8`, and the spot market's pair must be exactly (`coreToken`, settlement
  `coreToken`) (`SpotPairMismatch`);
- with a perp (`perpMarket != NO_MARKET`): `perpMarket ≤ type(uint16).max` (`PerpIdUnsupported`),
  `perpSzDecimals ≤ 6`, cross-marginability (an `onlyIsolated` perp is rejected), and
  `szDecimals`/`maxLeverage` matching the venue with a non-zero `maxLeverage` (`PerpMismatch`);
- spot-only (`perpMarket == NO_MARKET`): `perpSzDecimals` and `perpMaxLeverage` must both be zero.

A pool carries the settlement descriptor at index 0 plus 1..8 directional assets; one token may
appear only once.

```solidity
function createVault(
    address pool,
    bytes32 dirDescriptorHash,
    address strategy,
    uint256 scaleWad,
    uint16 slippageBps,
    B4VaultStorage.FeeRoute calldata route
) external returns (address vault);
```

Constraints enforced at creation:

| Parameter | Constraint |
| --- | --- |
| `pool` | must be `isPool[pool]` |
| `dirDescriptorHash` | must resolve via `B4Pool.descriptorIndexPlusOne` (else `UnknownDescriptor`) |
| `strategy` | `targets()` is read once at creation; `abs(growth)` and `abs(fall)` must be `≤ Phi.MAX_BASE_TARGET` (`10e18`) and, after scaling, `abs(g·scale/WAD)` and `abs(f·scale/WAD)` must be `≤ Phi.PHI` (`1.618033988749894848e18`) — else `BadPolicy` |
| `scaleWad` | non-zero, `≤ Phi.MAX_SCALE` (`10e18`) |
| `slippageBps` | `≤ 500` |
| `route.operatorBps` | `≤ Phi.MAX_OPERATOR_BPS` (`3819`); a non-zero value requires a non-zero `operator` |
| `route.referrerBps` | when a referrer is set: `operatorBps` non-zero and `referrerBps ∈ [3819, 10000]`; when no referrer is set, `referrerBps` MUST be `0` (else `BadRoute`) |

`msg.sender` becomes the fixed vault owner and signs the entire configuration by sending the
transaction. The vault is an EIP-1167 clone of the implementation; the factory registers it with the
pool (`registerVault`) in the same call. Record `PoolCreated` and `VaultCreated` events, the pool
descriptor set and every constructor argument for publication (gate §5.14).

After creation, the owner funds the vault with `deposit(uint256 dirAmount, uint256 usdcAmount)`, and
anyone may drive it with `crank()` / `settle(uint256 intervalId)` / `claimDeferred`, or via
`Keeper.crank(pool, vaults, maxVaultSteps)`.

`deposit` is owner-only and accepted only while the calendar deposit window is open — deposits are
closed in the two 0→target sub-windows `[P−H, P)` and `[T+H, T+W)` (`Calendar.depositOpen`, else
`DepositWindowClosed`) — and only while no exit is pending (`exitShareWad == 0`, else
`ExitPending`).

---

## 6. Funded release gates (mandatory)

`SECURITY_MODEL.md` §5 lists fifteen items that **cannot be proven off-chain** and must be
demonstrated with funded transactions on the target network. Restated as operator checks, each
producing a recorded transaction hash and observed values:

| # | Gate | Actionable check |
| --- | --- | --- |
| 1 | USDC identity/decimals | Confirm the canonical linked USDC EVM address and Core index; confirm `evmDecimals`/`coreWeiDecimals` against the token-info precompile; execute **both** class-transfer directions (EVM→Core, Core→EVM) and record received deltas. |
| 2 | Directional decimals | For every directional token in the pool: signed decimal conversion and a full round trip, comparing actual received amounts to expectations. |
| 3 | Account activation | Send to a **fresh** Core account and observe the activation/one-time-fee behavior (`HAZARDS.md` A9); confirm actions are rejected before activation and accepted after. |
| 4 | Spot execution | Verify spot asset id, lot rounding, IOC encoding and price bounds with a live order; confirm the `slippageBps` envelope is respected. |
| 5 | Perp scaling | Verify perp price, size, entry-notional and position scaling against live precompile reads. |
| 6 | Margin + harvest | Move margin in and out; realize a positive harvest and a realized loss; reconcile principal exactly. |
| 7 | Partial exit | Execute a partial exit: full flatten to raw zero, complete margin return, proportional payment, and correct resync of the remaining vault. |
| 8 | Fill/retry behavior | Force partial fill, no fill and delayed fill; confirm the retry path resends the **exact complement** of completion and never double-counts. |
| 9 | Return paths | On every Core→EVM return, confirm **both** the Core debit and the EVM receipt before accounting moves. |
| 10 | CoreWriter atomicity | Prove action atomicity and the absence of delayed double-execution across a resend (`HAZARDS.md` A7/A11). |
| 11 | Reduce-only to zero | Prove a reduce-only order can close a position to raw `szi == 0` (`HAZARDS.md` A10). |
| 12 | Light client + LZ | End-to-end: light-client publication on Citrea → LayerZero delivery → `HalvingAccepted` on the oracle, using **production** libraries and DVNs. |
| 13 | Delegate removal | `delegate() == address(0)` and `delegateRenounced() == true` on both sides, plus a zero delegate at the endpoint (section 4). |
| 14 | Reproducible build | Deployed-runtime-bytecode equality for **every** contract via a reproducible-build manifest — including contracts carrying constructor immutables — with published constructor args and pool descriptors. |
| 15 | Gas calibration | Calibrate precompile gas costs against live values and confirm any per-call gas caps. |

**Mainnet MUST NOT proceed until these are recorded and independently reviewed.** Given the earlier
engagement (a permanent-freeze High that survived three audit rounds), `SECURITY_MODEL.md` §5 further
recommends that the async completion/retry, harvest-quota and recovery paths receive a **dedicated
independent audit round of their own**. Audit history and disposition are in [`REPORT.md`](../REPORT.md).

Additionally, unresolved by any gate and accepted as residuals: market association (no canonical
token↔perp statement exists — the immutable descriptor supplies it and **the user must verify it**),
fixed USDC = 1 USD (a depeg is undetected), and liquidity/liquidation risk (the `1/φ` reserve is a
margin, not liquidation protection).

---

## 7. Post-deployment record

Publish, for the deployment to be reviewable:

- compiler version, optimizer settings, `evm_version`, library commits, source tree hash;
- every deployed address with its constructor arguments (oracle, ops, vault implementation, factory,
  prover, strategies, keeper);
- each pool's full descriptor set and the `dirDescriptorHash` of every directional asset;
- the LayerZero configuration (endpoint, EIDs, libraries, DVNs) and both `DelegateRenounced`
  transactions;
- the transaction hashes and observed values for all fifteen funded gates.

## Further reading

- [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) — trust model, invariants, residuals, gates
- [`spec/HAZARDS.md`](../spec/HAZARDS.md) — hazard register (A7/A9/A10/A11, E1–E4, F1/F3)
- [`spec/SPECIFICATION.md`](../spec/SPECIFICATION.md) · [`spec/REQUIREMENTS.md`](../spec/REQUIREMENTS.md) · [`spec/TEST_PLAN.md`](../spec/TEST_PLAN.md)
- [`ARCHITECTURE.md`](../ARCHITECTURE.md) · [`INVARIANTS.md`](../INVARIANTS.md) · [`REPORT.md`](../REPORT.md) · [`SLITHER.md`](../SLITHER.md)
