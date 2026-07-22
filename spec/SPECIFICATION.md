# B4 — specification (normative target behavior)

Normative behavior for a fresh implementation. `MUST`/`MUST NOT`/`SHOULD`/`MAY` are binding.
This defines *behavior*, not contract layout — implement it in whatever structure is cleanest,
subject to `HAZARDS.md`. Economic rationale is non-normative (`WHITEPAPER.md`).

## 1. Scope and boundary

- Execution MUST occur only on the target chain + its Core venue. The core MUST NOT contain
  source-chain bridge logic, generic swap routing, arbitrary execution callbacks, an upgrade
  proxy, or an operator fund-mover.
- External interfaces MAY build source-chain swaps/bridges, but the user MUST sign every
  route; accounting begins only when a supported token reaches the vault on the target chain.
- The halving transport MUST carry only the proven halving fact; user funds MUST NOT pass
  through the oracle/relay/receiver.

## 2. Immutable configuration

- Each vault MUST be an isolated instance with one directional descriptor (`fixedUsd=false`)
  and the settlement descriptor (`fixedUsd=true`), one fixed owner, one isolated execution
  identity, one immutable fee route.
- A Pool whitelist MUST key on the full descriptor hash, not just the token address; one token
  MUST NOT have two descriptors in a Pool; a Pool admits 1–N directional descriptors.
- Settlement MUST be canonical linked USDC with a fixed `1 USD` valuation (a depeg is
  undetected — see `SECURITY_MODEL.md`).
- Before a vault accepts funds, its execution identity MUST verify against the venue that the
  descriptor's token/decimals/spot-pair/perp identities are internally consistent and the
  perp is cross-marginable.
- The fee route MUST be fixed at creation and signed by the user; no party may change it.
  `operatorBps ≤ 3819` (= 38.19%); a referrer requires a non-zero operator rate and
  `3819 ≤ referrerBps ≤ 10000`; the referral is carved only from the operator payment.

## 3. Policy and exposure

- A policy is a stored `(growth, fall)` pair of signed WAD targets; a strategy is read only at
  selection. For base `b`, scale `k`: `resolved = b·k/WAD`, with `|b| ≤ 10·WAD`,
  `0 < k ≤ 10·WAD`, `|resolved| ≤ φ` (`φ = 1_618033988749894848`). Mini is the canonical
  special case resolving to `(1,1)`. The stored magnitude is the product's **base** leverage
  `g`; for a leveraged long the *effective* exposure at entry is `g` amplified by proximity to
  the cycle's structural low (§7b) and MAY exceed `φ` — the `|resolved| ≤ φ` bound is on the
  stored base, not the effective leverage.
- Execution MUST decompose the current signed target `n` as `spot = clamp(n,0,1)`,
  `perp = n − spot`.
- Policy/scale change MUST update the same vault with no withdrawal, exit, or penalty.

## 4. Halving fact and calendar

- The fact MUST be a proof-backed Bitcoin halving (height a positive multiple of 210,000),
  bound cryptographically (light-client hash ⇔ 80-byte header; timestamp from header bytes);
  transported over an immutable-path receiver that binds source EID + sender; idempotent by
  height (conflicting fact reverts).
- Acceptance of the next height MUST require `height = current + 210000`, a **strictly
  monotonic** timestamp (> current), and a **not-in-future** timestamp — and MUST NOT gate on
  any wall-clock interval window (see `HAZARDS.md` E1). Acceptance increments the epoch and is
  permissionless.
- Zones over `t = now − halvingTs`, with `W = 20d`, `H = 10d`, and pivots `P = cycle/φ²`,
  `T = cycle/φ`: `[0,P−W)` growth; `[P−W,P−H)` growth→0; `[P−H,P)` 0→fall; `[P,T)` fall;
  `[T,T+H)` fall→0; `[T+H,T+W)` 0→growth; `[T+W, next halving)` growth. Interpolation depends
  only on time. Zone boundaries and windows are product-independent; interpolation of the
  stored pair depends on its signs. The `…→0→…` split applies when the two targets differ
  in sign or either is zero — it exists so a derivative SIGN CHANGE always passes through a
  verified zero. When growth and fall targets have strictly the same sign there is no sign
  change: the target MUST interpolate directly `growth→fall` across the full transition
  `[P−W,P)` (and `fall→growth` across `[T,T+W)`), never visiting a synthetic zero. Equal
  targets (Mini) therefore stay constant and MUST trade nothing after deposit; the
  performance fee still applies to their interval profit at settlement (§8), paid in kind —
  a fee never forces a sale. Deposits MUST be closed in the two `0→…` sub-windows. Free
  exits MUST cover all four transitions plus a fixed window after each accepted fact.

## 5. Vault accounting

- Account **actual received deltas**, never requested amounts; an unsolicited transfer MUST
  NOT increase accounting. All fixed-point division MUST floor toward the protocol.
- Every accepted deposit MUST add its current value to the interval entry ledger. Spot rotation
  and margin movement MUST NOT change the entry ledger by token-form alone.
- State categories: directional capital; rotated capital (settlement from Close sales); owner
  margin reserve; verified Core principal. Unrealized PnL / unverified surplus MUST NOT enter
  the realized ledger; owner margin MUST NOT increase strategy notional.
- When flat, if withdrawable Core settlement is below recorded principal, principal MUST be
  written down **before any NAV valuation** — settle, exit, AND sync (see `HAZARDS.md` B2).
  Every valuation path MUST run only at an idle execution engine (no action in flight), so
  the write-down always reflects a genuine loss: a self-initiated perp-side transfer in
  flight moves the withdrawable by design, and its value is conserved in the bucket the
  completion read will prove. In particular, settlement — which irreversibly pays the
  performance fee and reports reward weight — MUST reject an in-flight engine rather than
  value a mid-transfer ledger (else returning principal reads as fee-bearing "profit").
  Completing an in-flight action takes far less than the report window, so this is
  liveness-only.

## 6. Asynchronous safety (the core discipline — see `HAZARDS.md` A)

- Action success MUST NOT finalize accounting; a later block MUST prove the effect.
- Completion/retry MUST key only on the balance the protocol's own action reliably moves
  (Core spot: decreased only by us). The perp `withdrawable` (PnL-driven, externally toppable)
  MUST NOT be a completion/retry counter. Concretely: `spot→perp` completes on spot
  net-decrease; `perp→spot` on spot net-increase reaching the full amount; `spot→EVM` on spot
  net-decrease + destination received the full amount. Each resend condition MUST be the exact
  complement of its completion condition.
- A recorded harvest/settlement claim MUST NOT be able to exceed what a single later call can
  settle: settle `min(claim, available now)` and always be able to clear the residual claim
  (it becomes recoverable surplus, not a blocking phantom). No pending claim/intent may gate
  the operation that resolves it.
- After a timeout, a silent action MAY be resent. A Core→EVM leg MUST NOT resend once its
  source decreased (it executed; wait for delivery). Emergency clearing MAY abandon a
  surplus-recovery intent (funds stay on Core, re-recoverable) but MUST NOT discard an
  asset-transfer intent. Custody flatness MUST be strict (raw position == 0).
- These properties rely on the atomicity of intra-Core transfers and on account activation —
  funded gates.

## 7. Spot and perpetual execution

- Only the vault MAY drive its execution identity. A spot trade MUST: remove exact input from
  accounting and send it to the venue; prove funding; snapshot balances and price; submit one
  IOC order; measure input spent and output received; **cap credited output by measured input
  and the price envelope**; return output + unspent input; prove both debit and EVM receipt;
  update accounting once. Slippage ≤ 500 bps; sizes/prices rounded to venue lot/price rules;
  zero-size orders MUST NOT be sent.
- Margin/perp: standard-mode separate spot/perp USDC; margin moves EVM→spot→perp and back with
  every arrow proven. A non-reduce open MUST have ≥ `10 USD` notional; perp IOC uses ≤ 50 bps
  mark envelope; `notional ≤ margin·maxLeverage/φ` (a safety reserve, not liquidation
  protection). A sign change MUST go `reduce→verify→harvest→open opposite`; every reduction is
  reduce-only; no order crosses zero. Harvest credit ≤ min(measured surplus above principal,
  positive mark PnL snapshotted, that PnL × fraction actually reduced).
- Favorable overfill and donations remain unaccounted and separately recoverable (bounded,
  flat/idle, no accounting callback) for spot AND perp surplus.

### 7b. Structural sizing — leverage bounded by confirmed extremes

The protocol's leverage is a **safety mechanism**, not a bet-sizing dial. Every leveraged
position's liquidation MUST sit at a *structurally confirmed* price — a level the market has
already printed and failed to regain — never at a distance an ordinary adverse swing can reach.
The stop is realized by **margin size** (`margin = notional/L`, the venue's own liquidation is
the stop; no stop orders, which would break the async fill-completion discipline). One reflected
rule covers both sides:

|  | **Long (bottom)** | **Short (top)** |
|---|---|---|
| Anchors | `floor` = previous confirmed bottom; `cap` = most recent confirmed bottom | `prevPeak` = previous confirmed peak; `C` = this cycle's confirmed peak |
| Confirmation window | 62-window `[T, T+W]` and post-halving `[halving, halving+W]` (min close) | the `W` days ending at the 38.2% pivot (max close) |
| Sizing | `stop = min(p − (p − floor)/g, cap)` | window: `stop = p + (p − prevPeak)·(g−1)` (DCA slices); after the pivot: `MaxStop = C + (C − prevPeak)·(g−1)`, `stop = max(p + (MaxStop − p)·(g−1), C)` |
| Leverage | `L = p/(p − stop)`, clamped by the venue max | `L = p/(stop − p)`, clamped by the venue max, **no 1× floor** |
| Depth behaviour | grows toward the confirmed low, decays for a late entry | decreases monotonically with depth; pins to `C` deep; exceeds the base `g` for any entry above `maxStop/2` (which lies **below** `C`, since `g·(g−1) = 1`), reaching ≈ 4.8× at the cycle-4 pivot |
| Refusal | `p ≤ floor` → un-leveraged spot leg | `p ≥ MaxStop` → flat base |
| Genesis | `floor = 0` → flat base `g` | no `prevPeak` → flat base `g` |

`W ≈ 20 days` is structural, not tuned: `W = q²·cycle` with `q = φ⁻³/2 = 0.118` — the same
quantum that places the 38.2/61.8 pivots (`0.5 ∓ q`); the peak forms at `0.382 − q² ≈ 0.368`
of the cycle, the bottom at `0.618 + q² ≈ 0.632`.

**Normative rules (bind the engine sizing):**

- **Sized once, then held.** A position MUST be sized when opened or materially re-targeted
  (entry, deposit, calendar zone change) and MUST NOT be re-sized against a moving NAV or a
  moving anchor within a zone: the sizing price and its anchors are captured **together** and
  frozen for the position's life. Window entries open in daily DCA slices (the extreme cannot
  be caught; the window average is the entry — the calendar knows *when*, not *at what price*).
- **`margin = notional/L`, whole deposit deployed.** No split-out reserve. On a long's stop the
  perp margin is consumed but the spot leg survives (`stop/p` of the directional retained —
  never zero). A deep short is deliberately sized below `1×`: the small position with its stop
  pinned to the far confirmed peak is what survives the bear-market rallies that liquidate a
  flat-`φ` short.
- **One shared pure function.** Engine, tests and the historical benchmark MUST use
  `StructuralLeverage` — the sizing math cannot drift from what is tested and demonstrated.
- **Anchor ratchets are permissionless, sampling-only, and advance at structural events.**
  Within a window the recorded extreme only improves (min down / max up); across windows the
  long pair `(floor, cap)` advances at the halving flip, which MUST promote only a
  62-window-confirmed cap (an unsampled 62-window MUST NOT poison the floor with a post-halving
  low). Sampling more makes the anchors more accurate ⇒ **less** leverage; under-sampling is
  NOT fail-safe, so an unconfirmed anchor MUST fall back to the flat base `g`, never to an
  assumed extreme.
- **The window regime is bounded by a structural cap, not just the venue max.** With `C` not
  yet confirmed the short window stop `p + (p − prevPeak)·(g−1)` is an extrapolation from the
  *previous* peak; if a cycle tops near `prevPeak` the leverage grows large. The redo MUST cap
  it structurally so a diminishing-returns cycle de-levers rather than over-levers — the venue
  `maxLeverage` alone is insufficient (it can exceed the base by many multiples below the max).

**Verified record (all completed cycles, real BTC closes — the safety claims are empirical,
not aspirational):**

1. **The structural stop was never hit.** After the 38.2% pivot the price never returned to
   `C` (post-pivot maximum 2–23% below it); after the 62% window the price never broke the
   confirmed bottom (post-window low 3–4% above the window min, +150% above the long's stop).
2. **The flat alternative dies; the structural one survives.** A flat-`φ` short is liquidated
   by the +99–103% bear-market rallies of cycles 1–2; a flat-`φ` long is liquidated by the
   −64% COVID crash. The structurally-stopped position survives every one of these events.

Implementation status: `StructuralLeverage` (both sides) and the low-side ratchet
(`B4Pool.sampleAnchor`) are shipped and tested; the engine sizing is flat-`φ` pending the §7b
redo (`AUDIT-2026-07-structural-leverage.md` binds it). Full derivation and per-cycle curves:
`PROPOSAL-structural-leverage.md`.

## 8. Checkpoints, fees, reward weight

- Each settlement point: a settlement-day price snapshot, a report window, a distribution window,
  then expiry. Price locking is permissionless and MUST commit **only after all assets price**
  (a transient zero on one asset MUST NOT poison the interval — see `HAZARDS.md` D1). Missing
  the snapshot window makes the interval unreportable (liveness, not custody).
- Settlement MUST reject a still-wrong-sign perp for the interval and MUST reconcile realized
  Core loss before computing the ledger.
- Performance: `profit = max(L−E,0)`; `virtualFee = profit·f` (`f = 0.045084971874737120`);
  `operatorCut = virtualFee·operatorBps/10000`; `clientShare = virtualFee − operatorCut`;
  `reportedWeight = priorRewardBase + clientShare`. Only the operator cut is physically paid,
  from the accounted EVM basket; Core principal MUST return through the verified machine first.
  Referral is carved from the operator cut. One weight report per interval.

## 9. Exits

- Share `x ∈ (0, 1]`. Before paying EVM assets, an exit MUST, driven by the **live** position
  (not a one-shot flag): reduce the perp to strictly zero (resubmitting on partial fill or an
  emergency-cleared reduce); verify and harvest bounded PnL; reconcile realized loss; return
  all Core principal; then pay the same share of each accounted EVM token.
- `q = 0.118033988749894848`. Inside a free window: `owner = gross − proportional operatorCut`,
  `Pool = 0`. Outside: `penalty = gross·q`; `operator = min(proportional cut, penalty)`;
  `owner = gross − penalty`; `Pool = penalty − operator`. The operator payment is carved from
  the single penalty, never added.
- Ledger updates: `nextEntry = E·(1−x)`, `nextRewardBase = (R + C·x)·(1−x)`, where
  `C = virtualFee − operatorCut` is the full-position client share, so `C·x` is the client
  share of the EXITING share — symmetric with the proportional operator cut above. Only the
  exiting share's profit earns client share at exit; the remaining share's open profit
  settles at the next checkpoint (entry is scaled, not re-anchored), so each share's profit
  earns client share exactly once and repeated partial exits — including dust exits — MUST
  NOT create or duplicate reward weight.

## 10. Pool liabilities and distribution

- Record actual received deltas; maintain total nominal liability per token; `balance ≥
  liability` invariant. `nominal claim = B·w/W`. On shortfall, `actual = nominal·balance/
  liability`, recomputed per claim against the reduced pair (order-independent). A failed token
  transfer leaves that token's claim retryable without reverting successful ones. Distribution
  is permissionless and pays the fixed owner. Expired inventory sweeps once, liability
  unchanged. Anyone MAY capture balance-above-liability into the accruing interval (a donation
  becomes inventory, never vault profit).

## 11. Deployment

Production MUST satisfy every gate in `SECURITY_MODEL.md`, including funded proof of Core
action atomicity, fresh-account activation, exact linked-token decimals, precompile gas,
partial/no/delayed-fill behavior, LayerZero DVN/library config + one-shot delegate removal,
and a reproducible deployed-bytecode manifest. Local mocks cannot prove venue semantics.
