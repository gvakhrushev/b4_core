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

How much accepted holding risk to keep is the user's dial — the protocol takes no
directional view on their behalf.

### One exposure equation for every product

A signed target `n` decomposes exactly once. Spot carries what spot can express; the
perpetual carries only the residual.

```mermaid
flowchart LR
    N["<b>signed target n</b><br/>|n| ≤ φ"]
    S["<b>spot</b> = clamp(n, 0, 1)<br/><i>directional spot on HyperCore</i>"]
    P["<b>perp</b> = n − spot<br/><i>residual perpetual only</i>"]
    N --> S
    N --> P
```

| Target `n` | → spot | → perp | Meaning | Where it occurs |
|---:|---:|---:|---|---|
| `1` | `1` | `0` | plain hold, no perp | Mini (both regimes), B4/Pro growth |
| `0` | `0` | `0` | fully rotated into USDC | B4 fall |
| `−1/φ` | `0` | `−1/φ` | net short, spot sold | Pro fall |
| `φ` | `1` | `φ − 1` | levered long | Pro Max growth |
| `−φ` | `0` | `−φ` | levered short | Pro Max fall |

### The deterministic calendar

`t` is time since the latest accepted halving fact — a pure function of block time. Nobody
chooses the regime: not the owner, not a keeper, not an operator.

The two pivots are **not fitted to price history** — they are the golden-ratio self-division
of the interval, which is why the model has **zero tuned parameters**:

| Pivot | Formula | Share of cycle | Nominal day |
|---|---|---:|---:|
| `P` growth → fall | `cycle/φ²` = `1/φ² × cycle` | **38.20 %** | ≈ 557.7 d |
| `T` fall → growth | `cycle/φ` = `1/φ × cycle` | **61.80 %** | ≈ 902.3 d |

Any other boundary would have to be calibrated against the handful of completed cycles —
i.e. overfitting. These two are the only division where `whole / larger = larger / smaller`.
Transitions are `W = 20 d` wide with halves `H = 10 d`; the nominal cycle is `1460 d`.

```mermaid
flowchart LR
    G["<b>Growth</b> — 1.47 y<br/>0 – 537.7 d<br/><i>target = growth</i>"]
    CG["<b>Closing growth</b> — 10 d<br/>537.7 – 547.7 d<br/><i>growth → 0</i><br/>✅ free exit"]
    S1{{"⚑ <b>Settlement</b><br/>P−H = 547.7 d"}}
    OF["<b>Opening fall</b> — 10 d<br/>547.7 – 557.7 d<br/><i>0 → fall</i><br/>✅ free exit · ⛔ deposits closed"]
    F["<b>Fall</b> — 0.94 y<br/>557.7 – 902.3 d<br/><i>target = fall</i>"]
    CF["<b>Closing fall</b> — 10 d<br/>902.3 – 912.3 d<br/><i>fall → 0</i><br/>✅ free exit"]
    S2{{"⚑ <b>Settlement</b><br/>T+H = 912.3 d"}}
    OG["<b>Opening growth</b> — 10 d<br/>912.3 – 922.3 d<br/><i>0 → growth</i><br/>✅ free exit · ⛔ deposits closed"]
    TG["<b>Terminal growth</b> — 1.47 y<br/>922.3 d → next accepted fact"]

    G --> CG --> S1 --> OF --> F --> CF --> S2 --> OG --> TG
    TG -. "next halving accepted<br/>⇒ t resets to 0" .-> G
```

Two things the picture encodes:

- **A sign change always passes through a verified zero.** When the two targets differ in sign
  (or one is zero), the transition is split at the settlement point, so the previous regime's
  exposure fully unwinds before the opposite one opens. Strictly same-sign pairs — Mini's
  `(1, 1)` — interpolate directly and never visit a synthetic zero, so Mini never trades; its
  interval profit is still fee'd.
- **Settlement points are fixed and product-independent** (`P−H` and `T+H`). An interval runs
  from one point to the next; the one beginning at `T+H` crosses the epoch boundary.

The calendar rests in terminal growth until the *next real halving fact* is accepted — no
wall-clock window ever gates acceptance, and nothing depends on the realized interval matching
the nominal 1460 days.

## How it fits together

```mermaid
flowchart TB
    BTC["Bitcoin<br/>halving block"]

    subgraph CIT ["Citrea"]
        PROVER["HalvingProver<br/><i>re-verifies the 80-byte header</i>"]
    end

    subgraph HE ["HyperEVM"]
        ORACLE["HalvingOracle<br/><i>timeSinceHalving() drives the calendar</i>"]
        FACTORY["B4Factory<br/><i>permissionless createPool / createVault</i>"]
        VAULT["B4Vault clone<br/><i>custody + accounting + async intent engine</i>"]
        POOL["B4Pool<br/><i>penalty inventory, weights, in-kind claims</i>"]
    end

    CORE[("HyperCore<br/>one execution identity per vault<br/>spot + perp")]
    OWNER(["Vault owner"])
    KEEPER(["Keeper — anyone"])
    STRAT["IStrategy<br/><i>pure (growth, fall)</i>"]

    BTC --> PROVER
    PROVER -- "LayerZero<br/>authenticated channel" --> ORACLE
    ORACLE -- "the one external fact" --> VAULT
    FACTORY -. clones .-> VAULT
    FACTORY -. deploys .-> POOL
    STRAT -. "read once at selection<br/>no authority over funds" .-> VAULT
    VAULT -- "emits async actions" --> CORE
    CORE -- "later state reads<br/><i>prove what actually executed</i>" --> VAULT
    VAULT -- "early-exit penalty, in kind" --> POOL
    POOL -- "claims, in kind, pro rata" --> OWNER
    OWNER -- "deposit / selectPolicy / exit" --> VAULT
    KEEPER -. "crank — no privilege" .-> VAULT
    KEEPER -. crank .-> POOL
```

### Execution is asynchronous — and that is the hard part

Emitting a CoreWriter action is **not** evidence it executed. Every effect must be proven by a
later Core state read, and accounting only ever credits the **actual measured balance delta** —
never the requested amount. Donations and favorable overfills stay unaccounted and separately
recoverable.

```mermaid
sequenceDiagram
    autonumber
    actor K as Keeper — anyone
    participant V as B4Vault
    participant C as HyperCore

    K->>V: crank()
    V->>V: plan a step, snapshot own balances
    V->>C: emit CoreWriter action
    Note over V,C: emitting ≠ executed — nothing is credited yet

    K->>V: crank() (a later block)
    V->>C: read Core state
    C-->>V: actual balances

    alt a self-moved balance proves the effect
        V->>V: credit the MEASURED delta, clear the intent
    else nothing moved, and the resend timeout passed
        V->>C: resend the exact complement (never a double-spend)
    else moved, but the EVM receipt is still pending
        V->>V: keep waiting — never resend after a debit
    end
```

Worst case of any stalled step is **delayed liveness, never loss** — every step stays
independently callable by anyone.

## Versioning: there is no upgrade path, by design

Every contract is immutable. There is no proxy, no `pause`, and no admin who can intervene —
the same model as Bitcoin and Uniswap V1/V2/V3. Safety comes from *correctness by
construction plus the owner's exit right*, not from a multisig that can reach into a live
vault.

The consequence is explicit: **a fix is a new deployment, not a patch.**

- A defect found in `v1` is addressed by deploying `v2` — re-audited — alongside it. `v1`
  keeps running exactly as written; nothing about it silently changes under its users.
- Existing vaults are EIP-1167 clones bound to their implementation. **They do not migrate
  automatically.** A user moves by exiting their `v1` vault and entering a `v2` one.
- Exiting inside a **free window** costs no penalty (`✅` above — the two 20-day transitions
  plus 20 days after each accepted halving fact). Outside one, the ordinary `q` penalty
  applies — that penalty *is* the protocol's core mechanic, not a migration toll.

So the natural migration moment is a transition window, which is also when a
calendar-driven strategy is flat or rotating anyway. Expecting a protocol to be refined
indefinitely before it ever ships is not a safety model; shipping immutable versions that
users can leave on their own terms is.

## Where value flows

Two moments move value: a **settlement checkpoint** (performance fee on interval profit) and
an **exit**. In both, the operator payment is carved *out of* the amount — never added on top —
and the referral is carved out of the operator's share in turn.

**At settlement** — `f ≈ 4.5084971874737120%` of profit over the entry ledger:

```mermaid
flowchart LR
    NAV["interval profit<br/>NAV − entry ledger"] --> VF["virtual fee<br/>= f × profit"]
    VF --> OC["<b>operator cut</b><br/>= operatorBps × virtual fee<br/><i>paid in kind from the EVM basket</i>"]
    VF --> CS["<b>client share</b><br/>= virtual fee − operator cut<br/><i>becomes pool reward weight</i>"]
    OC --> REF["referrer<br/><i>carved out of the operator cut</i>"]
    OC --> OP["operator"]
    CS --> W["B4Pool weight → in-kind claims"]
```

Settlement **reverts** (`FeeNotRepatriated`) unless the EVM basket can cover the operator cut,
so a Core-heavy vault must repatriate before it can settle — it cannot dodge the fee while
still reporting full reward weight.

**At exit** — a free window costs no penalty; outside one, a single in-kind penalty
`q ≈ 11.8033988749894848%` of the exiting gross applies:

```mermaid
flowchart TB
    G["gross exiting value<br/>= NAV × exit share x"] --> Q{"in a free-exit<br/>window?"}

    Q -- "yes" --> FO["owner: gross − operator cut"]
    Q -- "yes" --> FP["operator: operator cut<br/><i>pool receives nothing</i>"]

    Q -- "no" --> PEN["penalty = q × gross"]
    Q -- "no" --> PO["owner: gross − penalty"]
    PEN --> POP["operator: min(operator cut, penalty)<br/><i>carved out of the penalty</i>"]
    PEN --> PPOOL["<b>B4Pool</b>: the residual<br/><i>in kind — funds other participants' claims</i>"]
```

In both branches `owner + operator + pool = gross` exactly. Free windows are the two `20 d`
transitions plus `20 d` after each newly accepted halving fact.

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
| [09 Roles](docs/09-roles.md) | Owner / operator / referrer / keeper — flows, earnings, limits |

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
