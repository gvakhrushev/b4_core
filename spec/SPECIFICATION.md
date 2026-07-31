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
  undetected — see `SECURITY_MODEL.md`). Binding MUST verify that the settlement descriptor
  IS the venue's quote asset, not merely that it is flagged fixed-USD: the perp class
  transfer moves the venue's USDC unconditionally, so any other linked token would leave the
  funding leg watching a balance the transfer never touches — no completion, and since an
  asset-transfer intent may never be discarded, an unhealable freeze.
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
- Execution MUST decompose the current signed target `n`: an **unlevered long** (`0 ≤ n ≤ 1`)
  is held as spot (`spot = n`, no funding, no liquidation); any **leverage** (`|n| > 1`) or any
  **short** (`n < 0`) is a **pure perp** (`spot = 0`, `perp = n`), so the whole leveraged
  position self-funds from USDC margin (a leveraged product is a USDC-margined perp — never spot
  held alongside perp margin, which would double exposure and pay funding on borrowed notional).
- In a legacy generic Pool, policy/scale change MUST update the same vault with no withdrawal,
  exit, or penalty. A strict Product Pool MUST accept only its immutable canonical scale-`1`
  reference strategies. It MUST expose only the four isolated masks `1/2/4/8` and aggregate
  mask `15`; no partial mixed mask is valid. Aggregate `15` MAY move a vault only to an
  equal-or-higher canonical product; an isolated cross-product change and every downgrade MUST
  use an ordinary exit and a new vault.

## 4. Halving fact and calendar

- The fact MUST be a proof-backed Bitcoin halving (height a positive multiple of 210,000),
  bound cryptographically (light-client hash ⇔ 80-byte header; timestamp from header bytes);
  transported over an immutable-path receiver that binds source EID + sender; idempotent by
  height (conflicting fact reverts).
- The receiver MUST start without a calendar fact and accept only the immutable
  `bootstrapHeight` as its first proof-backed message. `timeSinceHalving()` MUST revert until
  that message arrives; there is no trusted constructor timestamp. Both legacy and strict
  factory paths MUST reject pool creation while `halvingHeight() == 0`.
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
  a fee never forces a sale. Deposits MAY enter throughout the cycle: a late entrant MUST
  start at the current interpolated target and reach the full target at the end of the
  20-day transition. Free exits cover all four transitions plus a fixed post-fact window.

## 5. Vault accounting

- Account **actual received deltas**, never requested amounts; an unsolicited transfer MUST
  NOT increase accounting. All fixed-point division MUST floor toward the protocol.
- Every accepted deposit MUST add its current value to the interval entry ledger. Spot rotation
  and margin movement MUST NOT change the entry ledger by token-form alone.
- **Single price basis.** The entry ledger and the NAV it is subtracted from MUST be taken on
  the same price basis. An implementation MUST NOT value the vault's composition *as read at
  settlement time* against a price fixed at any earlier instant: composition can change in
  between — at a settlement point the calendar requires it to (§4) — and every such change is
  then measured against a stale reference and reads as profit no capital earned. A deposit is
  never a valid place to repair this, because the permissionless crank changes composition on
  the same path without touching the entry ledger.
- A directional price of 0 MUST NOT be used as a cost basis or as a valuation. Deposit of the
  directional leg MUST reject it; settlement MUST reject it; exit finalization MUST defer on
  it rather than revert, and MUST remain cancellable so a permanently dead feed cannot strand
  a vault (the settlement leg is price-independent when no directional asset is held).
- State categories: directional capital; rotated capital (settlement from Close sales **and
  direct settlement-token deposits**); owner margin reserve; verified Core principal. Unrealized
  PnL / unverified surplus MUST NOT enter the realized ledger; owner margin MUST NOT increase
  strategy notional.
  A deposited settlement token is strategy capital, not margin. It has to be: a pure-perp
  product returns settlement at exit, so if a re-deposit landed in the margin reserve it would
  be inert — the reserve is excluded from `_strategyValueWad`, so notional would size off zero
  directional capital and the position would never reopen. The margin rule above is unaffected
  and still holds literally: the reserve itself never enters notional; what changed is only
  which bucket a deposit lands in.
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
| Confirmation window | 62-window `[T, T+W]` and post-halving `[halving, halving+W]` (min close) | the `W` days ending at the 38.2% pivot (max close, corroborated — see below) |
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
- **The peak anchor is the max over daily CLOSES, corroborated by two of them.** A "close" is a
  fixed, public instant, not whatever a caller chose to read: an observation may set the peak
  value only inside `ANCHOR_CLOSE_WINDOW` of a daily close, on a day grid anchored to the
  sampling window's own opening (so close `k` is exactly `P − W + k days`, and a `W`-wide window
  holds exactly `W` closes). A level MUST be reached at TWO DISTINCT close-days before it is
  served by `peaks()` or promoted into `prevPeak`. Value binding MUST be independent of the
  density counter: conflating them gives the caller who wins the daily counting slot ownership of
  the day's value, which is suppression (AUDIT-2026-07-29 F2), and gating on nothing at all
  admits any wick (M-3). The window's opening observation carries no served value.
  Two costs, stated rather than hidden: a top printing at exactly one close is served one close
  late, bounded by the gap between the two highest closes; and a fixed instant is predictable and
  therefore easier to target than a random one — what it buys is that an attacker must hold a
  price at a published time instead of choosing their moment. Both errors understate `C`, which
  pushes the short's stop further out and LOWERS leverage: the conservative direction.
  The LOW side is deliberately NOT mirrored — it ratchets on every observation, because a lower
  low moves a long's stop further from price and lowers leverage, so every-observation is a
  superset of daily closes in exactly the safe direction.
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

Implementation status: the §7b engine sizing is **shipped** by MARGIN CONTROL — `StructuralLeverage`
(both sides), the low- AND high-side ratchets (`B4Pool.sampleAnchor` / `peaks`), and the engine
planner (`B4VaultEngine._planPerpStep`) size a leveraged long or short so the venue's own
liquidation sits at the structural stop; a single frozen stop, captured once at open and cleared
at flip / exit / liquidation, means a held position is never re-adjusted (no re-lever on a price
move or a permissionless anchor flip). The exact state machine, the worked acceptance numbers, and
the remaining interims (the halving volume-add, the growth-rise ratchet floor, per-slice DCA) are
`docs/design/STRUCTURAL-STATE-MACHINE.md`; the derivation is `docs/design/PROPOSAL-structural-leverage.md`.

## 8. Checkpoints, fees, reward weight

- Each settlement point: a settlement-day price snapshot, a report window, a distribution window,
  then expiry. Price locking is permissionless and MUST commit **only after all assets price**
  (a transient zero on one asset MUST NOT poison the interval — see `HAZARDS.md` D1). Missing
  the snapshot window makes the interval unreportable (liveness, not custody).
- **The settlement day is one named day of the transition's twenty, and the two clocks agree.**
  Since `W − H = 10 days` exactly, the settlement point opens precisely on the transition's tenth
  daily close, so the day the interval is valued on is itself a close day — the anchor sampler's
  close grid (anchored to the window opening `P − W`) puts its close 10 inside this day's first
  `ANCHOR_CLOSE_WINDOW`. Any change to `W`, `H` or the snapshot width MUST preserve that: a
  settlement point landing between two closes would give the protocol two disagreeing day grids,
  one for what a price *is* and one for when a vault is *valued*.
- Settlement MUST reject a still-wrong-sign perp for the interval and MUST reconcile realized
  Core loss before computing the ledger.
- **The valuation instant MUST NOT be the settle caller's choice.** Interval NAV and the price it
  is measured at MUST be captured **together, at one instant**, by a one-shot act confined to the
  settlement-day snapshot window (`B4Vault.snapshotNav`); settlement MUST value off that capture,
  and MUST refuse rather than substitute a later price when the window has passed with nothing
  captured (the interval then defers to the next checkpoint — liveness, not custody). The capture
  MUST be permissionless, so that the vault owner can take it at `pointTime` and leave no
  discretion for a front-runner; settlement MAY take it itself while still inside the window, so
  the ordinary keeper path stays a single call. The captured price MUST also be the basis the
  in-kind operator cut values the basket on, or the fee and the NAV it is a fraction of come from
  different prices — the C-1 mismatch in miniature.
  Without this, settlement valued the vault at the price of the instant it ran, anywhere in the
  three-day report window, and because the interval is one-shot a third party could pin another
  vault's minted weight at a trough with no second attempt for the victim (AUDIT-2026-07-29 F4).
  Note what MUST NOT be done instead: freezing a shared per-interval price reopens C-1, and
  restricting the *caller* rather than the instant hands each owner a repeatable, unpreemptable
  slice in which to pick their own peak.
- Performance: `profit = max(L−E,0)`, where `L` and `E` MUST be on one price basis (§5);
  `virtualFee = profit·f` (`f = 0.045084971874737120`);
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
- Ledger updates: `nextEntry = E·(1−x)`, `nextRewardBase = (R + C·x)·(1−x)`, so a full exit
  (`x = 1`) zeroes the standing base. The reward base is a claim on the shared basket, and the
  basket is funded by LEAVERS for the benefit of STAYERS — a vault holding no capital must
  therefore hold no claim on it. The exiting share's own profit is paid to it in kind by the
  exit itself; what a full exit surrenders is only the claim on other users' exit penalties.
  The call-order asymmetry this leaves — `settle` before exiting reports weight the pool would
  otherwise never hear was abandoned — MUST be closed on the pool side by scaling the reported
  weight (`scaleWeight`), not by letting the base survive the exit: the latter
  inverts the redistribution model and lets a repeatedly-recycled clone accrue standing claims
  against capital it no longer holds.
  The pool side MUST scale by the same `keep` on EVERY exit, not only on a full one, so that
  reported weight always tracks the capital still standing behind it. Gating it on the exact
  boundary `keep == 0` is forbidden: `x` is chosen by the owner, so an equality test at the
  boundary is satisfied by `x = 1 − ε` for any `ε`, which withdraws the whole position while
  keeping the whole claim (AUDIT-2026-07-29 F1). Nor may the condition be taken from the
  post-exit BASE, which the `C·x` term re-inflates with the exiting share's own unsettled
  profit. A full exit is then the endpoint of the ramp rather than a distinct rule. Where
  `C = virtualFee − operatorCut` is the full-position client share, so `C·x` is the client
  share of the EXITING share — symmetric with the proportional operator cut above. Only the
  exiting share's profit earns client share at exit; the remaining share's open profit
  settles at the next checkpoint (entry is scaled, not re-anchored), so each share's profit
  earns client share exactly once and repeated partial exits — including dust exits — MUST
  NOT create or duplicate reward weight.
- A strict Product Pool MUST route a non-free exit's measured pool receipt to escrow keyed by
  the exiting vault's immutable canonical product and directional asset. Only settlement plus
  that vault's directional token are eligible penalty assets; another whitelisted token is an
  ordinary donation. Only that product's
  immutable pool-owned sleeve MAY receive it. The sleeve MUST bind the same product targets and
  use the ordinary engine, current price, and confirmed structural anchors; it is not an
  administrator-selected trade. Its capital MUST NOT become claimable until a full sleeve exit
  during `Calendar.freeExit`; a post-halving exit inside the first 20 days has `Pool = 0` and
  therefore MUST NOT create a penalty sleeve trade.

## 10. Pool liabilities and distribution

- Record actual received deltas; maintain total nominal liability per token; `balance ≥
  liability` invariant. `nominal claim = B·w/W`. On shortfall, `actual = nominal·balance/
  liability`, recomputed per claim against the reduced pair (order-independent). A failed token
  transfer leaves that token's claim retryable without reverting successful ones. Distribution
  is permissionless and pays the fixed owner. Expired inventory sweeps once, liability
  unchanged. Anyone MAY capture balance-above-liability into the accruing interval (a donation
  becomes inventory, never vault profit).
- In a strict Product Pool, live sleeve escrow is excluded from ordinary claim liability and
  from shortfall balances. The pool MUST account it separately by product and directional asset,
  must zero-reset any temporary allowance used to fund a sleeve, and may add its returned balance
  to `accruing` only after the sleeve's free-window exit. This prevents a live Pro Max sleeve
  from diluting either a Mini claim or an isolated Pro pool.

## 11. Deployment

Production MUST satisfy every gate in `SECURITY_MODEL.md`, including funded proof of Core
action atomicity, fresh-account activation, exact linked-token decimals, precompile gas,
partial/no/delayed-fill behavior, LayerZero DVN/library config + one-shot delegate removal,
and a reproducible deployed-bytecode manifest. The factories MAY be deployed before the
proof-backed bootstrap message, but pool creation MUST remain mechanically disabled until it is
accepted. Local mocks cannot prove venue semantics.
