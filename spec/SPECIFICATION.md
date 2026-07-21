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

### 7b. Position sizing and structural leverage (long side)

- **Sized once, then held.** A directional/perp position MUST be sized when it is opened or
  materially re-targeted (an entry, a deposit, or a calendar zone change) and MUST NOT be
  continuously re-sized against a moving NAV within a zone. The calendar is the rebalance
  schedule; a running NAV-relative target is NOT. A tolerance band still suppresses dust
  re-trades, but the trigger is a target change, not price drift.
- **Structural leverage floor.** For a leveraged long product (base leverage `g = |growth| >
  1`, e.g. Pro Max `g = φ`), the effective leverage at entry price `p` MUST be bounded by the
  cycle's confirmed structural lows, not by a flat multiple:

  ```
  stop = min( p − (p − floor)/g ,  cap )
  L    = p / (p − stop)          (then clamped by the venue maxLeverage)
  ```

  where `floor` and `cap` are two ratcheted anchors (below). The uncapped stop sits `1/φ` of
  the delta `(p − floor)` below `p` for `g = φ`, so `L = g·p/(p − floor)` uncapped — leverage
  grows as the entry approaches the structural low and decays toward `1×` for a late entry.
  Implementations MUST use the shared pure function (`StructuralLeverage`) so the sizing math
  is identical to what is tested and demonstrated.
- **`cap` limits maximum leverage, not the right to enter.** Any `p > floor` MAY open; `cap`
  only lowers the stop (⇒ lower leverage). Only `p ≤ floor` MUST refuse a leveraged open
  (fall back to the un-leveraged spot leg). `floor == 0` (genesis, before the first window
  closes) MUST degrade to the flat base `L = g`.
- **The stop is realized by margin size, not a stop order.** The posted perp margin MUST equal
  `notional / L`, so the venue's own liquidation sits at `stop`. The whole deposit is deployed
  (no split-out reserve). On a stop the perp margin is consumed but the spot leg survives, so
  the position degrades to spot-only with `stop/p` of the directional retained — never zero.
- **Anchors — two confirmed structural lows, ratcheted UP only.** The minimum directional
  price is recorded by a permissionless ratchet within two calendar windows: the 62-window
  `[T, T+W]` (the cycle bottom) and the post-halving window `[halving, halving+W]`. The
  recorded minimum only moves down *within its own window*; across windows the pair
  `(floor, cap)` ratchets up at each structural event — at the halving the previous `cap`
  becomes the new `floor` and the post-halving low becomes the new `cap`. **Sampling more
  lowers the anchors and therefore lowers leverage** — the recorded minimum is an *upper*
  bound on the true low, so a diligently-sampled window records a lower anchor (larger delta,
  less leverage) than an under-sampled one. Under-sampling is therefore NOT fail-safe on its
  own; the mechanism depends on the low being sampled (a keeper does this each window, and
  it is in the pool's interest). Until a window is sampled at all, a leveraged product MUST
  fall back to the flat base leverage `g` (the pre-mechanism behaviour) rather than assume a
  cap that does not exist. A new low observed WITHIN a window only lowers the anchor; across
  windows the pair advances only at the halving flip (never sideways to a higher value).
- **Short side.** A short leg (fall regime) uses the flat base `g` with no structural
  multiplier in this version — there is no structural ceiling above a short.

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
