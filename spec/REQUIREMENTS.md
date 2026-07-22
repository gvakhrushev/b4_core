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

Reference products at scale `1` (core derives `spot = clamp(target,0,1)`, `perp = target − spot`):

| Product | Growth | Fall | Markets used |
|---|---|---|---|
| Mini | `1 spot` | `1 spot` | none after deposit |
| B4 | `1 spot` | `1 USDC` | directional/USDC spot |
| Pro | `1 spot` | `1 USDC − 1 perp` | spot + perp (separate margin) |
| Pro Max | `1 spot + (L−1) perp` | `1 USDC − L perp` | spot + perp (separate margin); `L` structural per §7b (base `φ`) |

- A **product is a `(growth, fall)` pair**; the core stores no product names. A strategy
  contract is read once at selection; later strategy mutation MUST NOT change stored targets
  unless the user re-selects.
- A **scale** `k` multiplies both targets, bounded so `0 < k ≤ 10·WAD` and `|resolved| ≤ φ`,
  and the raw base target is bounded `|b| ≤ 10·WAD` before scaling.
- Product/scale changes rebalance the **same** vault in place — no withdrawal, no exit
  penalty, no replacement vault. Resulting trades are ordinary execution events.
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

1. **Create Pool** — creator fixes the asset whitelist (validated: valid market identities,
   correct decimals, no duplicate token, settlement excluded from directional).
2. **Create vault** — operator proposes Pool/descriptor/policy/scale/slippage/route; user
   reviews and signs. Creation atomically binds owner, Pool, an isolated execution identity,
   stored targets, and the immutable route.
3. **Deposit** — directional capital and/or USDC margin; accepted only in open windows;
   accounted from the actual received delta; adds current value to the interval entry ledger.
4. **Sync exposure** — permissionless crank drives spot/perp toward the time-derived target
   in one asynchronous step at a time (rotate spot, allocate/return margin, open/reduce perp,
   harvest). Keepers call again after each step verifies.
5. **Settle** — at each interval settlement point, checkpoint prices are locked (permissionless,
   within the settlement-day window), realized profit is measured against entry, the performance fee
   is split, and reward weight is reported to the Pool.
6. **Distribute** — permissionless; profitable participants receive Pool inventory pro rata,
   in kind, paid to the fixed owner.
7. **Exit** — full or partial; flattens any perp to a strictly flat account, harvests bounded
   PnL, reconciles realized Core loss, returns Core principal, then pays the requested EVM
   share; a non-free exit withholds one in-kind penalty.
8. **Recover** — owner may recover unaccounted EVM assets, bounded Core spot surplus, and
   bounded perp surplus above principal, each while idle/flat, with no accounting callback.

## 6. Windows and timing

- Deposits are closed during the two `OpeningFall`/`OpeningGrowth` (`0→…`) transition
  sub-windows.
- Free exits (no penalty) cover all four transition zones and a fixed window after each
  accepted halving fact.
- Checkpoint prices MUST be locked within a settlement-day (24h) snapshot window at each settlement
  boundary; missing it makes the interval unreportable (liveness, not custody loss).

## 7. Interface obligations

Before creation or policy change, the interface MUST show: exact Pool and descriptor;
single/multi-asset and the full reward-token set; the unverified token↔perpetual association;
policy, scale, and current time-derived target; expected Close trades; required separate USDC
margin; the full fee route; whether capital tops up an existing route or creates a new vault;
the fixed `USDC = 1 USD` assumption; and all bridge/swap transactions before signature.
Interfaces MUST NOT present the mechanical Close profile as tax advice.
