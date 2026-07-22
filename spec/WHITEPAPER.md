# B4: deterministic infrastructure for hold strategies

## Abstract

B4 converts a long-horizon, Bitcoin-cycle hold rule into non-custodial on-chain execution.
A user deposits a liquid directional asset plus canonical USDC into an isolated vault and
selects two target exposures — one for the growth regime, one for the fall regime. Time
since the latest proven Bitcoin halving deterministically selects and continuously
interpolates the active target. Spot represents exposure in `[0, 1]`; a perpetual position
represents only the residual exposure spot cannot express. There is one external fact
(the halving), one execution venue (HyperCore), one accounting model, and no admin.

## 1. The problem and the baseline

The reference participant is not a flat position — it is a **long-horizon holder who
already bears the full cyclical drawdown** (historically up to roughly `80%` peak-to-trough
per four-year cycle) as the standing cost of long exposure. B4 is evaluated against that
holder. Its objective is to **reduce already-accepted holding risk without surrendering
custody**, answering four questions with the smallest trusted surface:

1. Which market regime is active?
2. What exposure should the user hold?
3. How is that exposure executed and verified?
4. How are long-term participation and early exit accounted for?

## 2. The product ladder

The reference products are one ladder that reduces the holder's baseline drawdown in steps,
each adding one interior action to a plain hold (one entry, one exit, full drawdown
between):

| Product | Growth target | Fall target | Adds vs. previous |
|---|---:|---:|---|
| Mini | `1` | `1` | hold spot; earns shared-Pool yield, no trade |
| B4 | `1` | `0` | a fall-regime rotation into USDC |
| Pro | `1` | `-1` | a full `1×` short in fall |
| Pro Max | `φ` | `-φ` | leveraged expression of the same signs |

Each product is the previous one plus one more interior move at the two cycle pivots. How
much accepted holding risk to keep is the user's dial; the protocol takes no directional
view on their behalf. `φ = 1.618033988749894848` (WAD).

Where a product carries leverage, the leverage is *designed* to be a **safety mechanism**
(`SPECIFICATION.md` §7b): the position's liquidation is placed by margin size at a
*structurally confirmed* extreme — the cycle's confirmed low for a long, its confirmed peak
for a short — a price the market has already printed and failed to regain. Across every
completed cycle that stop is never touched, while a flat-`φ` position is liquidated by the
recorded +99–103 % bear-market rallies (short side) or the −64 % COVID crash (long side); deep
entries deliberately de-lever rather than chase. **Implementation status:** the sizing math and
the anchor mechanism are specified and unit-tested, but the vault-engine sizing currently uses
the flat base `φ` — the structural sizing is the pending §7b redo, and until it lands a
leveraged product's realized liquidation is the flat-base distance, not the structural stop.

## 3. The exposure equation

For a signed target `n` (WAD directional beta), every product uses one decomposition:

```
spot = clamp(n, 0, 1)
perp = n - spot
```

`spot` is directional spot exposure; `perp` is residual perpetual exposure. A product is a
`(growth, fall)` pair resolved and stored when the user selects it; a scale multiplies both,
subject to the absolute ceiling `φ`.

## 4. Deterministic calendar

The cycle contains a growth regime, a fall regime, and two 20-day transitions. When the
two targets differ in sign or either is zero, the transition is split at zero so a
derivative sign change always passes through a verified zero; strictly same-sign target
pairs interpolate directly and never visit a synthetic zero (equal targets, as in Mini,
stay constant and trade nothing — the performance fee still applies to their interval
profit at settlement). Boundaries are a
pure function of block time; a keeper only advances asynchronous execution and cannot choose
the target, speed, market, or slippage. The reference geometry uses a four-year (`1460`-day)
cycle with `growth→fall` pivot at `cycle/φ²` and `fall→growth` pivot at `cycle/φ`.

## 5. The structural thesis and its limits

The geometry rests on a supply argument, not numerology. A programmed, irreversible
reduction in new issuance at each halving is a persistent contraction of new supply against
continuing demand, which under a fixed issuance schedule exerts sustained upward pressure
that has historically resolved through appreciation, excess demand, overextension, and
reversion. The mechanism derives from the issuance schedule — which cannot be altered — and
is therefore insensitive to the *composition* of demand (spot ETFs, for example, were absent
from the first three cycles yet the pattern preceded them).

The golden-ratio division of the cycle is used because it is the only internally justified
self-division of an interval and introduces **zero fitted parameters** — any alternative
boundary would be calibrated against only a handful of completed cycles, i.e. overfitting.
Structure fixes the *direction* of pressure, not the *precision* of timing; the fixed pivots
may lead or lag the realized turn. The protocol pays for that error in the right currency:
the worst case of a mistimed boundary is under-collection relative to an ideal exit, bounded
by the user's chosen exposure, and for Mini it does not fall below hold-equivalence plus Pool
inventory. The error reduces return, not principal. Because only on the order of thirty
halvings will ever occur, a large statistical sample is impossible in principle; the design
rests on this structural argument, not on an asymptotic history that cannot be assembled.

## 6. The forced external anchors

Decomposing this design determines exactly three external objects, and in each case the
trust-minimizing choice is effectively unique:

- **A regime clock** needs Bitcoin block height and time proven on-chain — a finalized
  Bitcoin light client (Citrea), whose 80-byte header is re-verified.
- **Negative exposure** needs the deepest perpetual venue (HyperCore); a shallower or
  self-created market would add liquidity/integrity assumptions rather than remove them.
- **Settlement** needs a fiat-reachable, Core/EVM-fungible USD asset — canonical USDC.

These are the termini of forced choices; the corresponding trust is disclosed as residual
after an optimal, and here essentially unique, selection.

## 7. Custody, execution and accounting (summary)

Each vault is an isolated clone owning one directional asset descriptor, canonical USDC, and
one isolated HyperCore execution identity. Execution is **asynchronous**: emitting a
CoreWriter action is not evidence it executed; the effect must be proven by a later Core
state read. Accounting measures **actual received balance deltas**, never requested amounts;
donations and favorable overfills stay unaccounted and separately recoverable. Early exit
outside a free window withholds a single in-kind penalty that funds a shared Pool; profitable
interval participants receive Pool inventory pro rata to recorded reward weight, in kind, with
no internal swap. The full normative behavior is in `SPECIFICATION.md`; the design traps that
make the async and accounting layers hard are in `HAZARDS.md`.

## 8. Minimal authority

No governance executor, upgrade proxy, pause, or privileged fund transfer. Pool creation is
permissionless and is not endorsement. Operators provide interfaces, routing, and keepers and
compete on a client-signed, per-vault fee route, but cannot move funds or choose the halving
fact. Minimalism makes the trust assumptions finite and explicit.
