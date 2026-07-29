# B4 — requirements (ТЗ)

Functional and business requirements for a fresh implementation. Normative wording
(`MUST`/`MUST NOT`) is refined in `SPECIFICATION.md`; this document states *what the system
does* and *what an interface must present*.

## 1. Actors

- **User / owner** — owns one or more vaults; selects Pool, directional asset, policy,
  scale, and fee route; the fixed beneficiary of every payout. The only party who may
  deposit, change policy, initiate exit, or recover unaccounted assets on their vault.
- **Pool creator** — permissionlessly fixes a Pool's exact asset whitelist. Creation is not
  endorsement and confers no ongoing authority.
- **Operator** — proposes a signed commercial offer (fee route), provides UI / source-chain
  routing / keepers. May receive the configured fee. Cannot custody funds, move a vault's
  assets, choose the halving fact, or mutate stored targets.
- **Referrer** — optionally distributes an operator's offer and receives a protected share of
  that operator's payment (never a second charge on the user).
- **Keeper** — permissionlessly advances the deterministic asynchronous state machines and
  the calendar. Has no privilege; liveness only.
- **Fact submitter / relay caller** — permissionlessly publishes or transports the
  proof-backed Bitcoin halving fact.

No actor is a protocol administrator. There is no admin, upgrade, pause, or privileged fund
mover.

## 2. Products and exposure

Reference products at scale `1` (an unlevered long is spot; every short or leverage is a pure
USDC-margined perp):

| Product | Growth | Fall | Markets used |
|---|---|---|---|
| Mini | `1 spot` | `1 spot` | none after deposit |
| B4 | `1 spot` | `1 USDC` | directional/USDC spot |
| Pro | `1 spot` | `−1 perp` | spot in growth; pure USDC-margined perp short in fall |
| Pro Max | `φ perp` | `−φ perp` | pure USDC-margined structural perp; base `φ` |

- A **product is a `(growth, fall)` pair**; the core stores no product names. A strategy
  contract is read once at selection; later strategy mutation MUST NOT change stored targets
  unless the user re-selects.
- A **scale** `k` multiplies both targets, bounded so `0 < k ≤ 10·WAD` and `|resolved| ≤ φ`,
  and the raw base target is bounded `|b| ≤ 10·WAD` before scaling.
- In a legacy generic Pool, product/scale changes rebalance the **same** vault in place —
  no withdrawal or exit penalty. A strict Product Pool accepts only the exact canonical
  scale-`1` reference strategy bound at creation. Its only valid choices are one isolated
  product (`Mini=1`, `B4=2`, `Pro=4`, `Pro Max=8`) or aggregate `15`; partial mixed masks
  are not a product. Aggregate `15` permits only an equal-or-higher product in place; any
  downgrade, and every cross-product change in an isolated pool, requires the ordinary exit
  and a new vault.
- The interface MUST display resolved numeric targets, not rely on product names.

## 3. Vault and pool structure

- Each vault: exactly one directional descriptor (`fixedUsd = false`) + the settlement
  descriptor (`fixedUsd = true`, canonical USDC), one isolated execution identity, one fixed
  owner, one immutable fee route.
- A Pool whitelists 1–N directional assets. A vault is never multi-token on its directional
  side. Pool shape changes only the shared reward basket:
  - single-asset Pool distributes its directional token + settlement;
  - multi-asset Pool distributes every admitted token + settlement, and an eligible vault
    receives its weight-proportional share of **every** basket token (it may receive assets
    it never deposited — MUST be disclosed before creation).
- Separate Pools share no balances, weights, or liabilities. Multiple vaults of one owner are
  independent accounting/execution domains even in the same Pool with the same descriptor.
- `B4ProductFactory` may create the four isolated product masks (`1/2/4/8`) or aggregate
  mask `15`. In a strict pool, each non-free penalty is measured and retained in
  `(product, directional asset, token)` escrow for settlement + the vault's own directional
  token. A different whitelisted token at the pool is ordinary donation inventory. Only the matching pool-owned sleeve may
  receive it; that sleeve has the same canonical strategy, live price and confirmed structural
  anchors as a vault opened at the fold. It may return capital to common claimable inventory
  only after a full free-window sleeve exit. While it trades, neither it nor a different
  product's sleeve changes ordinary claimant liability.

## 4. Commercial model (fee routes)

- A fee route (operator address, operator bps, optional referrer, referrer bps) is **fixed at
  vault creation** and signed by the user. No party may change it afterward.
- Bounds: `operatorBps ≤ 38.19%` of the *virtual performance fee* (not of capital/profit);
  referrer, if present, gets `≥ 38.19%` of the operator payment and requires a non-zero
  operator rate.
- Fee is a performance fee on positive realized interval profit only. Only the operator cut
  is physically paid; the client share becomes reward weight retained in the vault.
- Operators compete by lowering their share. The same owner MAY open a second vault (same
  asset, same Pool) under a different route; a top-up keeps the existing route; earlier
  tranches are never repriced.

## 5. Lifecycle (business processes)

1. **Create Pool** — after the oracle has accepted its proof-backed bootstrap fact, the creator
   fixes the asset whitelist (validated: valid market identities, correct decimals, no duplicate
   token, settlement excluded from directional). Both factory paths reject pool creation while
   `halvingHeight() == 0`.
2. **Create vault** — operator proposes Pool/descriptor/policy/scale/slippage/route; user
   reviews and signs. Creation atomically binds owner, Pool, an isolated execution identity,
   stored targets, and the immutable route.
3. **Deposit** — directional capital and/or USDC margin; accepted throughout the cycle;
   accounted from the actual received delta; a late entry joins the current interpolated target
   and reaches the full target at the end of the 20-day transition.
4. **Sync exposure** — permissionless crank drives spot/perp toward the time-derived target
   in one asynchronous step at a time (rotate spot, allocate/return margin, open/reduce perp,
   harvest). Keepers call again after each step verifies.
5. **Settle** — at each interval settlement point the interval opens for reporting
   (permissionless, within the settlement-day window), profit is measured against entry **on a
   single price basis** — the vault is valued at the moment settlement is performed, never
   against a price fixed earlier — the performance fee is split, and reward weight is reported
   to the Pool. Deposits stay open throughout, including during the settlement window: a
   deposit contributes to profit exactly its own P&L over its own holding period, so it can
   neither create nor destroy weight it did not earn.
6. **Distribute** — permissionless; profitable participants receive Pool inventory pro rata,
   in kind, paid to the fixed owner.
7. **Exit** — full or partial; flattens any perp to a strictly flat account, harvests bounded
   PnL, reconciles realized Core loss, returns Core principal, then pays the requested EVM
   share; a non-free exit withholds one in-kind penalty. In a strict Product Pool that measured
   penalty follows `escrow → matching sleeve → free-window sleeve exit → accruing → claim`, not
   an immediate depositor-proportional distribution.
8. **Recover** — owner may recover unaccounted EVM assets, bounded Core spot surplus, and
   bounded perp surplus above principal, each while idle/flat, with no accounting callback.

## 6. Windows and timing

- Deposits are accepted throughout both 20-day transitions. Day 15 means 50% of the new side;
  day 20 means the full stored target.
- Free exits (no penalty) cover all four transition zones and a fixed window after each
  accepted halving fact. The latter is exactly 20 days, so an exit there cannot simultaneously
  create a penalty sleeve.
- Checkpoint prices MUST be locked within a settlement-day (24h) snapshot window at each settlement
  boundary; missing it makes the interval unreportable (liveness, not custody loss).

## 7. Interface obligations

Before creation or policy change, the interface MUST show: exact Pool and descriptor;
single/multi-asset and the full reward-token set; the unverified token↔perpetual association;
policy, scale, and current time-derived target; expected Close trades; required separate USDC
margin; the full fee route; whether capital tops up an existing route or creates a new vault;
the fixed `USDC = 1 USD` assumption; and all bridge/swap transactions before signature. For a
strict pool it MUST also show its isolated/aggregate choice, allowed upgrade direction, and that
live sleeve capital is not claimable until a free-window sleeve exit.
Interfaces MUST NOT present the mechanical Close profile as tax advice.
