# B4

**Deterministic, non-custodial execution of a Bitcoin-cycle hold strategy.**

A user deposits a directional asset plus canonical USDC into an isolated vault and picks two
target exposures — one for the growth regime, one for the fall regime. Time since the last
proven Bitcoin halving selects and interpolates the active target. One external fact, one
venue (HyperEVM + HyperCore), one accounting model, no admin.

> [!WARNING]
> **Pre-mainnet. Not externally audited. Do not use with real funds.**
> The mandatory funded network gates ([`spec/SECURITY_MODEL.md`](spec/SECURITY_MODEL.md) §5)
> are unmet, and venue semantics cannot be proven off-chain. See [`REPORT.md`](REPORT.md) for
> exactly what is and is not proven.

## Documentation

| | |
|---|---|
| **Start here** | [Overview](docs/01-overview.md) → [Core concepts](docs/02-core-concepts.md) |
| **Integrating** | [Integration](docs/04-integration.md) · [Contract map](docs/03-contracts.md) |
| **Auditing** | [Security model](docs/05-security.md) · [`spec/HAZARDS.md`](spec/HAZARDS.md) · [`INVARIANTS.md`](INVARIANTS.md) |
| **Operating** | [Deployment](docs/06-deployment.md) · [Keeper](docs/08-keeper.md) · [Roles](docs/09-roles.md) · [Off-chain stack](docs/10-offchain-architecture.md) |
| **Economics** | [Fees, penalty and the pool](docs/07-fee-routing.md) · [Backtest](docs/11-backtest.md) · [`spec/WHITEPAPER.md`](spec/WHITEPAPER.md) |

Full index: [`docs/README.md`](docs/README.md). The normative specification the
implementation is judged against lives in [`spec/`](spec/) — citations of the form
`HAZARDS A2` or `SPECIFICATION §4` refer to it.

Implementation records: [`ARCHITECTURE.md`](ARCHITECTURE.md) (design decisions) ·
[`REPORT.md`](REPORT.md) (security dossier + audit history) ·
[`SLITHER.md`](SLITHER.md) (static-analysis triage).

## How it works

```mermaid
flowchart TB
    BTC["Bitcoin halving block"]

    subgraph CIT ["Citrea"]
        PROVER["HalvingProver<br/><i>re-verifies the 80-byte header</i>"]
    end

    subgraph HE ["HyperEVM"]
        ORACLE["HalvingOracle<br/><i>drives the calendar</i>"]
        FACTORY["B4Factory<br/><i>permissionless pool / vault creation</i>"]
        VAULT["B4Vault clone<br/><i>custody + accounting + async engine</i>"]
        POOL["B4Pool<br/><i>penalty inventory, weights, claims</i>"]
    end

    CORE[("HyperCore<br/>one execution identity per vault")]
    OWNER(["Owner"])
    KEEPER(["Keeper — anyone"])

    BTC --> PROVER
    PROVER -- "LayerZero" --> ORACLE
    ORACLE --> VAULT
    FACTORY -. clones .-> VAULT
    FACTORY -. deploys .-> POOL
    VAULT -- "emits actions" --> CORE
    CORE -- "state reads prove execution" --> VAULT
    VAULT -- "penalty, in kind" --> POOL
    POOL -- "claims, in kind" --> OWNER
    OWNER -- "deposit · selectPolicy · exit" --> VAULT
    KEEPER -. crank .-> VAULT
```

Three properties define the system:

- **The calendar is a pure function of block time.** Nobody — owner, operator or keeper —
  chooses the regime, the target, the market or the price.
- **Execution is asynchronous and proven, never assumed.** Emitting a CoreWriter action is not
  evidence it executed; the effect must be proven by a later Core state read, and accounting
  credits the *measured balance delta*, never the requested amount. Donations and favourable
  overfills stay unaccounted and separately recoverable.
- **Authority is minimal.** No upgrade proxy, no pause, no privileged fund mover. The worst
  case of any stalled step is delayed liveness, never loss of funds.

## The products

Each product is the previous one plus one more interior move at the two cycle pivots.
`φ = 1.618033988749894848`.

| Product | Growth | Fall | Adds |
|---|---:|---:|---|
| Mini | `1` | `1` | holds spot, trades nothing; earns pool yield |
| B4 | `1` | `0` | a fall-regime rotation into USDC |
| Pro | `1` | `−1/φ` | a hedge — short in the fall regime |
| Pro Max | `φ` | `−φ` | leveraged expression of the same signs |

A signed target `n` decomposes exactly once, identically for every product:

```
spot = clamp(n, 0, 1)     // directional spot
perp = n − spot           // residual the spot leg cannot express
```

How much accepted holding risk to keep is the user's dial; the protocol takes no directional
view on their behalf.

## The cycle

The two pivots are **not fitted to price history** — they are the golden-ratio self-division
of the interval, so the model carries **zero tuned parameters**. Any other boundary would have
to be calibrated against the handful of completed cycles.

| Pivot | Formula | Share of cycle | Nominal day |
|---|---|---:|---:|
| `P` growth → fall | `cycle/φ²` | 38.20 % | ≈ 557.7 d |
| `T` fall → growth | `cycle/φ` | 61.80 % | ≈ 902.3 d |

```mermaid
flowchart LR
    G["<b>Growth</b><br/>1.47 y"]
    CG["Closing<br/>10 d ✅"]
    S1{{"⚑ Settlement<br/>P−H"}}
    OF["Opening fall<br/>10 d ✅ ⛔"]
    F["<b>Fall</b><br/>0.94 y"]
    CF["Closing<br/>10 d ✅"]
    S2{{"⚑ Settlement<br/>T+H"}}
    OG["Opening growth<br/>10 d ✅ ⛔"]
    TG["<b>Terminal growth</b><br/>1.47 y"]

    G --> CG --> S1 --> OF --> F --> CF --> S2 --> OG --> TG
    TG -. "next halving ⇒ t = 0" .-> G
```

✅ free exit · ⛔ deposits closed · nominal cycle `1460 d`, transitions `W = 20 d`, halves
`H = 10 d`. A sign change always passes through a verified zero at a settlement point;
strictly same-sign pairs interpolate directly and never synthesise one — which is why Mini
never trades, yet is still fee'd on interval profit.

Details: [Core concepts](docs/02-core-concepts.md).

## Historical demo

The four products over real BTC daily closes, sized once per regime and **held** (fixed
units, no daily rebalance), with Pro Max's leverage from `StructuralLeverage` — the
protocol's own function, bounded by the cycle's confirmed lows.

```bash
forge test --match-path 'test/backtest/*' -vv
```

**Return** by cycle, each starting at `1.0x`, against raw buy-and-hold (`HODL`). Returns
include the Pool income (below). **Read the `vs deposit` column, not the return column** — it
is the worst the position ever fell below the deposit:

| Cycle | Mini | B4 | Pro | Pro Max | HODL | Pro Max vs deposit |
|---|---:|---:|---:|---:|---:|---:|
| 2012→2016 | 52.9x | 145.1x | 193.1x | 471.0x | 52.3x | **−0.6 %** |
| 2016→2020 | 13.8x | 40.3x | 54.2x | 209.9x | 13.6x | **−33.6 %** |
| 2020→2024 | 7.4x | 21.4x | 28.7x | 150.6x | 7.3x | **−1.0 %** |
| 2024→now\* | 1.0x | 1.7x | 2.1x | 3.7x | 1.0x | **−41.7 %** |

<sub>\* cycle in progress, one settlement so far. Pro Max entry leverage per cycle:
1.6× / 2.5× / 2.7× / 2.2× — structural, not flat.</sub>

**Less drawdown than holding.** HODL eats a 53–84 % top-to-bottom crash every cycle. B4 and
Pro hold spot only through the *rise* and sit in **USDC through the fall**, so they sidestep
the bear entirely — their max drawdown is intra-bull volatility, 10–25 pp below HODL's:

| Cycle | HODL max DD | B4 / Pro | Pro Max | B4 vs HODL |
|---|---:|---:|---:|---:|
| 2012→2016 | 84.2 % | 73.9 % | 75.5 % | **−10.3 pp** |
| 2016→2020 | 83.2 % | 64.2 % | 67.9 % | **−18.9 pp** |
| 2020→2024 | 76.5 % | 53.1 % | 58.9 % | **−23.4 pp** |
| 2024→now | 53.0 % | 28.2 % | 51.9 % | **−24.7 pp** |

<sub>Mini stays `1×` long through the bear (like HODL), so its drawdown tracks HODL's — the
price of the simplest product. Pro Max's leverage lifts its drawdown back toward HODL's on the
interim dips, which is why `vs deposit` is the number that matters for it.</sub>

**Pool income — the core value capture.** Every return above already includes it: the
assumption is **20 % of the cohort exits through the `q = 11.8 %` penalty door each cycle**,
redistributed to the ~80 % who stay — **+0.25·q ≈ +2.95 % per cycle to every stayer**. Mini
holds exactly HODL's exposure, so **Mini beating HODL (52.9x vs 52.3x) is nothing but the Pool
income net of fees** — the mechanism by which stayers are paid by leavers, visible in isolation.

The point of the `vs deposit` column: B4's **max drawdown is ~74 % peak-to-trough** yet it
sits at **−0.3 % vs the deposit** — the swing gives back *profit*, not principal, if you
entered at the halving. Pro Max, by contrast, genuinely risks a third to a half of the
deposit — leverage cuts both ways, and the demo shows it rather than hiding it.

> [!IMPORTANT]
> **Illustration of the mechanism — not evidence of edge, and not a forecast.** Three
> completed cycles is not a statistical sample and never can be (~32 halvings will ever
> occur). Multiples are *arithmetic under perfect timing* — entry at the halving, infinite
> depth at any size, no slippage or market impact — not outcomes. Perps were not liquid
> before ~2016, so Pro/Pro Max in the early cycles are historical hypotheticals. Pool income
> rests on a behavioural assumption (20 % exit penalised per cycle).

Method, the structural-leverage mechanism, and every omitted cost: [Backtest](docs/11-backtest.md).

## Versioning: no upgrade path, by design

Every contract is immutable — no proxy, no pause, no admin who can reach into a live vault.
Safety comes from correctness by construction plus the owner's exit right, the same model as
Bitcoin and Uniswap V1/V2/V3.

The consequence is explicit: **a fix is a new deployment, not a patch.** A defect in `v1` is
addressed by deploying a re-audited `v2` alongside it; `v1` keeps running exactly as written.
Vaults are clones bound to their implementation and do not migrate automatically — a user
moves by exiting and re-entering, which is free inside a transition window and otherwise costs
the ordinary exit penalty.

## Build & test

Requires [Foundry](https://book.getfoundry.sh/); Solidity `0.8.28` is pinned in `foundry.toml`.

```bash
forge build --sizes   # every contract must fit EIP-170
forge fmt --check
forge test            # unit + integration + invariant campaigns

FOUNDRY_PROFILE=deep forge test --match-path 'test/invariant/*'   # nightly deep profile
slither . --fail-high                                            # release gate, also in CI
```

## Repository layout

```text
src/
  core/       B4Factory · B4Pool · B4Vault (+Storage/Engine/Ops) · HalvingOracle
  venue/      HyperCore types, precompile readers, CoreWriter encoding, descriptors
  libraries/  Phi (fixed point + φ) · Calendar · BtcHeader · SafeTransfer
  periphery/  Keeper · reference strategies
  citrea/     HalvingProver (source-chain publisher)
test/         unit · integration · invariant campaigns · adversarial HyperCore mock
script/       deployment wiring
data/         BTC daily closes used by the historical demo
spec/         the normative specification package
docs/         guides
```

## Security

Report vulnerabilities privately — see [`SECURITY.md`](SECURITY.md). Please do not open a
public issue for a suspected vulnerability.

There is no admin key and no pause, so a live deployment cannot be halted; that is precisely
why pre-deployment reports matter.

## License

[MIT](LICENSE) — matching the SPDX header on every source file.
