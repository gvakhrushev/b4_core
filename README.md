# B4 — deterministic infrastructure for Bitcoin-cycle hold strategies

B4 turns a long-horizon, Bitcoin-cycle hold rule into **non-custodial on-chain execution**.
A user deposits a liquid directional asset plus canonical USDC into an isolated vault and
picks two target exposures — one for the growth regime, one for the fall regime. Time since
the latest *proven* Bitcoin halving deterministically selects and interpolates the active
target.

One external fact (the halving), one execution venue (HyperEVM + HyperCore), one accounting
model, and minimal authority: **the vault, pool and factory contracts have no admin, no
upgrade proxy, no pause, and no privileged fund mover.**

Two authority boundaries do exist and are disclosed rather than hidden: each vault's own
fixed **owner** may deposit, re-select a policy, exit, and recover unaccounted assets *from
their own vault only* (they cannot change the fee route or touch another vault); and each
LayerZero-side contract (`HalvingOracle`, `HalvingProver`) carries a temporary **configurator
delegate** that must be permanently renounced via `renounceDelegate()` before production —
verifying that on-chain is a release gate.

> ### ⚠️ Status: pre-mainnet, not externally audited
> This code has **not** had an independent external audit, and the mandatory funded
> network gates (`spec/SECURITY_MODEL.md` §5) are **not** met. Venue semantics — CoreWriter
> action atomicity, fresh-account activation, precompile behavior — cannot be proven off-chain
> and are unverified here. **Do not use with real funds.** See [`REPORT.md`](REPORT.md).

## The product ladder

Each product is the previous one plus one more interior move at the two cycle pivots.
`φ = 1.618033988749894848`.

| Product | Growth target | Fall target | Adds vs. previous |
|---|---:|---:|---|
| Mini | `1` | `1` | hold spot; earns shared-Pool yield, trades nothing |
| B4 | `1` | `0` | a fall-regime rotation into USDC |
| Pro | `1` | `−1/φ` | a hedge (short in the fall regime) |
| Pro Max | `φ` | `−φ` | leveraged expression of the same signs |

A signed target `n` decomposes once, for every product:

```
spot = clamp(n, 0, 1)     // directional spot exposure
perp = n − spot           // residual exposure spot cannot express
```

How much accepted holding risk to keep is the user's dial — the protocol takes no
directional view on their behalf.

## How it fits together

```text
HalvingProver  (Citrea)   proves the Bitcoin halving fact from an 80-byte header
        │ LayerZero
HalvingOracle             holds the proven fact; timeSinceHalving() drives the calendar
        │
B4Factory                 permissionless createPool / createVault; validates descriptors
        │
B4Vault (clone)           isolated custody + accounting + async intent engine
        │                 (B4VaultStorage / B4VaultEngine / B4VaultOps)
        ├── HyperCore     one isolated execution identity per vault (spot + perp)
        └── B4Pool        shared in-kind penalty pool, reward weights, claims

Keeper                    permissionless crank for every step — no privilege
IStrategy                 stateless `pure` (growth, fall) policy — no authority over funds
```

**Execution is asynchronous.** Emitting a CoreWriter action is not evidence it executed; the
effect must be proven by a later Core state read. Accounting measures **actual received
balance deltas**, never requested amounts — donations and favorable overfills stay
unaccounted and separately recoverable.

## Documentation

**Start here:** [`docs/01-overview.md`](docs/01-overview.md) · full index in
[`docs/README.md`](docs/README.md)

| Guide | |
|---|---|
| [01 Overview](docs/01-overview.md) | What B4 is, the ladder, the external anchors |
| [02 Core concepts](docs/02-core-concepts.md) | Calendar, exposure equation, vault vs pool |
| [03 Contract map](docs/03-contracts.md) | What each contract does and may not do |
| [04 Integration](docs/04-integration.md) | Signatures, lifecycle, events — build on B4 |
| [05 Security](docs/05-security.md) | Trust model, invariants, audit posture |
| [06 Deployment](docs/06-deployment.md) | Runbook + the funded release-gate checklist |
| [07 Fees & pool](docs/07-fee-routing.md) | Performance fee, fee route, exit penalty, claims |
| [08 Keeper](docs/08-keeper.md) | Running the permissionless crank |

**Normative specification** (`spec/`) — what the implementation is judged against:

- [`spec/WHITEPAPER.md`](spec/WHITEPAPER.md) — the economics, the thesis, and its limits
- [`spec/REQUIREMENTS.md`](spec/REQUIREMENTS.md) — actors, products, lifecycle, commercial model
- [`spec/SPECIFICATION.md`](spec/SPECIFICATION.md) — normative `MUST`/`MUST NOT` behavior
- [`spec/HAZARDS.md`](spec/HAZARDS.md) — the design traps of the async/accounting layers
- [`spec/SECURITY_MODEL.md`](spec/SECURITY_MODEL.md) — trust model, invariants, **funded release gates**
- [`spec/TEST_PLAN.md`](spec/TEST_PLAN.md) — the regressions the implementation must pass

**Implementation records:** [`ARCHITECTURE.md`](ARCHITECTURE.md) (design decisions, normative
per HAZARDS G3) · [`INVARIANTS.md`](INVARIANTS.md) (invariant → test traceability, with honest
gaps) · [`REPORT.md`](REPORT.md) (security dossier: what is proven locally vs. what remains a
funded gate, plus the full internal audit history) · [`SLITHER.md`](SLITHER.md) (static-analysis
triage).

> Citations in the implementation docs of the form `HAZARDS A2`, `SPECIFICATION §4` or
> `SECURITY_MODEL §5` refer to the corresponding file under [`spec/`](spec/).

## Repository layout

```text
src/
  core/       B4Factory, B4Pool, B4Vault (+Storage/Engine/Ops), HalvingOracle
  venue/      HyperCore types, precompile readers, CoreWriter encoding, descriptors
  libraries/  Phi (fixed point + φ), Calendar, BtcHeader, SafeTransfer
  periphery/  Keeper, reference strategies (Mini/B4/Pro/Pro Max)
  citrea/     HalvingProver (source-chain publisher)
test/
  unit/         per-hazard regressions and component tests
  integration/  full product-ladder lifecycle across a cycle
  invariant/    stateful campaigns over the security-model invariants
  mocks/        adversarial HyperCore mock (exact-ABI shims at precompile addresses)
script/       deployment wiring (ops → implementation → factory)
spec/         the normative specification package
docs/         this documentation set
```

## Build & test

Requires [Foundry](https://book.getfoundry.sh/); Solidity `0.8.28` is pinned in `foundry.toml`.

```bash
forge build --sizes     # every contract must fit EIP-170
forge fmt --check
forge test              # unit + integration + invariant campaigns

# nightly deep invariant profile
FOUNDRY_PROFILE=deep forge test --match-path 'test/invariant/*'
```

Static analysis is a release gate and runs in CI:

```bash
pip install slither-analyzer==0.11.4
slither . --fail-high
```

See [`SLITHER.md`](SLITHER.md) for the per-detector triage.

## Security

Please report vulnerabilities privately — see [`SECURITY.md`](SECURITY.md). Do not open a
public issue for a suspected vulnerability.

## License

[MIT](LICENSE) — matching the `SPDX-License-Identifier: MIT` header carried by every source
file.
