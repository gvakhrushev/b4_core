# B4 — security model

Security = preservation of custody and accounting invariants under untrusted callers, delayed
execution, and bounded external failures. It does NOT mean the strategy avoids market loss,
liquidation, token failure, or tax consequences.

## 1. Trust model

**Trusted external dependencies** (failure can halt execution, misprice, or cause loss; B4
does not reproduce their security internally):
- the execution chain + Core venue consensus, its precompiles and CoreWriter action encoding,
  **and their live semantics** (action atomicity, account activation, gas);
- canonical linked USDC (issuer/admin behavior, Core/EVM fungibility);
- the Bitcoin light client (Citrea) and its consensus;
- the configured LayerZero endpoint, libraries, and DVN stack.

**Untrusted parties — the protocol MUST stay custody-safe against:** operator and keeper;
halving submitter and relay caller; arbitrary spot/verification/distribution callers; direct
EVM **or Core** token transfers to the vault/account (an external Core credit is a standard
operation, not a "donation" — treat it adversarially in async completion, see `HAZARDS.md`
A2/A11); a mutable strategy contract after its targets are stored; the creator/owner of a
different Pool or vault.

**Administrative boundary:** no governance executor, upgrade proxy, pause, or privileged
fund transfer. Each LayerZero-side contract has one temporary configurator whose delegate
MUST be permanently removed before production.

## 2. Safety invariants (assert as stateful campaigns — see `TEST_PLAN.md`)

1. One execution identity belongs to exactly one vault.
2. One vault cannot authorize movement from another vault's EVM or Core account.
3. Accounting never increases from an unmeasured transfer or donation (EVM or Core).
4. Action success never finalizes accounting; later Core state must prove execution.
5. A Core→EVM completion requires both a Core debit and an EVM receipt.
6. Spot credit cannot exceed proven input consumption and the price envelope.
7. Perp harvest cannot exceed measured surplus and proportional positive reduce-PnL, and the
   recorded harvest claim can never exceed what a single later call can settle (no deadlock).
8. Owner margin stays separate from strategy capital.
9. A derivative sign change passes through a verified zero.
10. Pool liability increases only by actual receipt; `balance ≥ liability`.
11. Pool distribution cannot exceed nominal liability; loss socialization is order-independent.
12. A legacy-pool product/scale change never invokes exit or penalty logic. A strict
    Product Pool allows only an equal-or-higher canonical product in aggregate mask `15`;
    any other transition must use the ordinary exit path.
13. A stale emergency action never discards an in-flight asset transfer (but may abandon a
    surplus-recovery intent, whose funds remain on Core and re-recoverable).
14. Any withdrawal with Core exposure first realizes a strictly-flat NAV and returns all Core
    principal before proportional EVM payment.
15. Operator/referral route cannot change after creation.
16. Multiple vaults of one owner remain independent accounting/execution domains.
17. Async completion/retry keys only on a reliable (self-moved) balance, never on a
    PnL-driven or externally-toppable one; every resend is the exact complement of completion.
18. No permissionless entrypoint has an attacker-chosen recipient/direction or an unbounded
    loop; the worst case of any async/gate path is delayed liveness, never freeze or loss.
19. In a strict Product Pool, a non-free exit's measured penalty can fund only its immutable
    matching `(product, directional asset)` sleeve. Live sleeve escrow is not claim liability;
    it joins ordinary distribution only after that sleeve's free-window exit. No caller can
    choose another strategy, recipient, or a live cross-product transfer. A different whitelisted
    token at the pool is ordinary donation inventory, never penalty escrow for this vault.

## 3. External assumptions code cannot prove (accepted residuals — decide/verify)

- **Action atomicity & receipts.** Intra-Core transfers are assumed atomic (all-or-nothing);
  Core→EVM has a debit-deliver window. The residual "≥ amount external top-up fakes a signal
  once" is attacker-funded, recoverable, non-freeze/non-theft; full closure needs a venue
  action receipt/nonce. Prove atomicity funded (gate).
- **Fresh-account activation.** New Core accounts need activation (quote-token fee) before
  actions; prove funded (gate).
- **Reduce-only full close.** Strict custody flatness assumes a reduce-only order can reach raw
  zero; prove funded (gate).
- **Market association.** No canonical token↔perp statement exists; the immutable descriptor
  supplies it; the user MUST verify. The SETTLEMENT side is no longer on trust: binding
  rejects any settlement descriptor that is not the venue quote asset, because that failure
  mode was a freeze rather than a mispricing. The assertion is `coreToken == 0`, so **"the
  venue's quote token is spot index 0" is now an immutable protocol dependency with no
  override** — verify it on the target network under gate §5.1. If it ever failed to hold,
  the consequence is bounded to a clean deployment-time `BadSettlement` revert in the factory
  constructor: no pool, vault or user funds can exist behind the misconfiguration, and no
  runtime path can meet it.
- **Standard account mode.** Prove on funded fresh accounts.
- **Fixed USDC = 1 USD.** A depeg is undetected (economic decision C3).
- **Liquidity / liquidation.** IOC may fill partially or not at all; the `1/φ` reserve is a
  margin, not liquidation protection.
- **Funding-income fee policy** (economic decision C1) and **exit-weight valuation** (C2) are
  documented asymmetries, not safety bugs.
- **Settle-timing discretion (accepted residual, not a defect).** Since AUDIT-2026-07-25 C-1,
  settlement values the vault at the price of the moment it is performed rather than at the
  interval's locked checkpoint price, because that is the only way the entry ledger and the NAV
  it is subtracted from can share one basis (`HAZARDS.md` B4). The consequence is explicit:
  `settle` is permissionless and its OUTCOME is now caller-dependent. There is no frozen
  reference left, so whoever calls it picks the instant and therefore the price, and two vaults
  holding the same directional asset that settle at different moments of the same window report
  DIFFERENT weight for the same interval.
  **The bound is the settle window itself.** Settle requires `lockedAt != 0` and
  `block.timestamp <= reportDeadline(id) = pointTime + SNAPSHOT_WINDOW (24h) +
  REPORT_WINDOW (2 days)`, so the choosable span is at most three days from the settlement
  point, never earlier than the permissionless `lockPrices` that opens it; `lastSettledPlusOne`
  makes the choice once-per-interval and non-repeatable.
  **Why the product owner accepts it.** Mark-to-market on a real holding is real profit: the
  measured figure is always the vault's own P&L against what it actually paid, so no weight can
  be created by capital that did not earn it (invariant 19). The basket is distributed pro rata,
  so a *uniform* price shift cancels and only **differential** timing has any effect at all. This
  is a relative-weight fairness question, never a mint, a freeze, or a custody question. The
  alternative — freezing a reference price for a composition read up to three days later — is
  precisely what produced the C-1 Critical, so it is not available.
  **The residual is now bounded by pre-emption, not by an operational expectation**
  (AUDIT-2026-07-29 F4). **Do not bound this by asserting that "the keeper settles every vault of a
  pool in a single pass, at one block and one price".** That is an operational expectation, not a
  code guarantee: `settle` is permissionless and one-shot per interval, so a third party can
  PRE-EMPT that pass for a vault it does not own and pin that vault's increment at an instant of
  its choosing — the shift is then differential by construction, and the factor that cancelled it
  does not hold.
  **The fix separates the valuation instant from the report.** `B4Vault.snapshotNav(id)` captures
  the interval's NAV and the price it was measured at, together, at one instant; it is
  permissionless, one-shot per interval, and confined to `Calendar.SNAPSHOT_WINDOW` (the
  settlement day). `settle` then values off that capture and takes it itself when it runs inside
  the same window, so the ordinary keeper path is still a single call. Two consequences:
  the choosable span narrows from three days to one, and — the point of it — the vault owner
  removes all discretion by taking the snapshot at `pointTime`, which restores exactly the
  mitigation the `Calendar` docstring relies on. Reporting liveness is untouched: the weight
  report still has until `reportDeadline`, and a vault that misses the snapshot window simply
  defers the interval, which is already the documented cost of missing that window for
  `lockPrices`. The stored price is what lets the in-kind operator cut be paid on the same basis
  the NAV was measured on when settle runs a day later; valuing the basket at the live price
  against a day-old NAV would re-create the C-1 mismatch in miniature.
  **What was rejected, and why**, since each is a plausible-looking alternative that measured
  worse. Any per-interval *uniform* valuation basis reopens C-1 (measured: valuing at the locked
  price mints 1577.97e18 of phantom weight against an honest vault's 315.59e18 — 83.3% of the
  basket, the recorded C-1 exploit exactly; even clamping the live price to ±10% of the locked one
  still yields 79.6%). An owner-preferred *settle* window destroys the uniformity above and hands
  each owner a repeatable, unpreemptable slice to pick their own peak — which is why the fix gates
  the valuation instant rather than the caller. Owner-only settle makes `Keeper.settleVault` revert
  into its catch forever; re-settle best-of gives every active owner a per-interval mint against
  passive co-claimants; re-settle last-write-wins lets a third party force repeated irreversible
  in-kind operator payments at chosen peaks; and a pool-wide consensus-price band lets an attacker
  settle first at a wick and lock every other vault out of the interval. No TWAP basis exists to
  switch to — `CoreReader`'s spot, mark and oracle reads are all instantaneous precompile reads.
  **The residual that remains**, rated LOW and asserted rather than hidden: inside the settlement
  day, a vault whose owner does not pre-empt can still have its instant chosen by whoever calls
  first. What that costs is one interval's *increment*, not the standing base (`reportWeight`
  reports the cumulative `rewardBaseWad`), and `entryLedgerWad` is re-anchored to the same pinned
  NAV, so the chained ledger books the suppressed move at the next settlement.
  (`Settle.t.sol::test_settle_values_at_live_price_real_pnl`, `AuditC1_JitWeight.t.sol` ×4,
  `AuditF4_SettleValuationInstant.t.sol` ×6.)
- **Crank-timing MEV (accepted residual).** Every step that emits a venue order is
  permissionless and prices off the live venue read at the moment it runs, so its CALLER chooses
  the block and therefore the price. Three concrete surfaces:
  (i) `B4Pool.foldPenalty(policy, dirAssetIndex)` moves a measured penalty escrow into its fixed
  product sleeve and immediately cranks it — for Pro / Pro Max the caller therefore picks the
  instant at which a real leveraged position is opened, and because the structural stop is
  (re-)derived at the current price while flat, the entry price sets both the sleeve's effective
  leverage `p/(p − stop)` and its liquidation price;
  (ii) any vault's `crank()` decides and emits its IOC spot/perp orders at the live price, so
  the caller chooses where inside the day's range the order is quoted;
  (iii) `settle` — the bullet above.
  **What a caller cannot choose:** the target, the market, the direction, the size rule, the
  sleeve, the recipient or the fee route. All are fixed by the immutable descriptors, the
  calendar, and the vault's own `(product, directional asset)` key; `foldPenalty` takes only
  that key, never an address. The crank pays its caller nothing — any edge must be extracted on
  the venue, against the envelope.
  **Bounds:** execution stays inside the envelopes (spot ≤ 500 bps, fixed per vault at creation;
  perp 50 bps of mark); the calendar target is a continuous ramp with a dead band, so a
  differently-timed crank converges to the same exposure rather than losing it; a leveraged size
  can only anchor on a density-confirmed structural anchor (`SPECIFICATION.md` §7b), never on
  the caller's own print; and every step is idempotent-by-measurement, so the worst case is a
  worse fill or a worse entry — market risk and delayed liveness, never custody.
  **Mitigation is competitive, not privileged.** An honest keeper cranking on a schedule is a
  standing competitor for every one of these moments — the same argument that makes
  `sampleAnchor` safe. There is no admin, and introducing a privileged scheduler would violate
  the administrative boundary above (F1). Closing it fully would need commit/reveal or an
  auction on a permissionless crank: a new trusted surface bought against a bounded,
  execution-only edge. Not taken.
- **Weight is final at the report deadline**, and `rewardBaseWad` is a cumulative STANDING
  base: it is re-reported at every interval and decays only with capital, never with time or
  market loss. With C-1 closed, reaching a claim is not cheap — it needs real capital, real
  exposure and real profit across a real interval.
  The ORDER DEPENDENCE is closed (AUDIT-2026-07-25 "half B"), and closed on
  the POOL side: an exit scales the standing base on the vault side
  (`nextRewardBase = (R + C·x)·(1−x)`, so `x = 1 ⇒ 0`) **and** scales the weight already
  reported for the open interval by the same `keep` via `B4Pool.scaleWeight`, lowering both
  `weightOf` and `totalWeight` by the identical amount. Settle-then-exit and exit-then-settle
  therefore agree: a vault holds a claim proportional to the capital still standing behind it,
  on a basket funded by leavers for the benefit of stayers.
  (The earlier "add the realised share instead of scaling it away" fix converged the two orders
  on KEEPING the weight; it was reverted because that inverts the redistribution model and
  re-opens the clone-recycling shape of C-1.)
  The pool side scales on EVERY exit. **The trigger MUST NOT be an equality on `keep == 0`:** `x`
  is owner-chosen, so that test is defeated by `x = WAD − 1` — essentially the whole position paid
  out, the whole reported claim retained (AUDIT-2026-07-29 F1). Proportional
  scaling removes the boundary rather than relocating it — no threshold survives a caller who
  can sit one wei above it, and no measure derived from the post-exit base survives the `C·x`
  re-inflation the owner controls the timing of. `scaleWeight` is confined to
  `block.timestamp <= reportDeadline(id)` — strictly disjoint from the claim window, which opens
  only after it — so `totalWeight` can never move while claims are open (invariants 10/11), and
  every non-applicable case is a silent no-op rather than a revert on the permissionless crank
  path (`HAZARDS.md` H3).
  What remains, and is accepted, is a dust residual in the exit-then-settle order: such a vault
  settles with `entryLedgerWad == 0`, so the flooring dust the exit waterfall left behind reads
  as profit and reports a dust weight. It is asserted rather than hidden, and pinned below one
  part per million of a real participant's share (`AuditHalfB_ExitWeightOrder.t.sol`).
  Redesigning weight accrual (report-and-consume instead of cumulative) is a separate product
  question, not a safety one.
- **Penalty-receipt measurement window.** `capturePenalty` bounds a sleeve's escrow by the
  balance increase measured since `beginPenalty`, but three token transfers run inside that
  window, and `claimDeferred` is permissionless with no idle gate. A basket token that runs
  a callback on transfer could therefore have unrelated value counted as this exit's receipt.
  Out of the honest-ERC20 model this protocol assumes (§4 excludes rebasing and
  fee-on-transfer directional assets), and the direction is bounded — it can only move value
  between a sleeve and claim inventory, never out of the pool. The hardening, if a
  callback-bearing basket asset is ever admitted, is to also bound the escrow by the exit's
  own declared pool share, making the measured receipt a cross-check rather than the sole cap.
- **Contract size** — *resolved, but structural.* `B4Vault` and `B4VaultOps` both inherit
  `B4VaultEngine`, so engine bytes are paid twice; and `B4Pool`'s creation code used to be
  embedded in both factory paths, making the pool's headroom unusable. Both are now split
  (`B4PoolDeployer`, `B4VaultRecovery`) and every deployed contract is guarded by
  `Eip170Sizes.t.sol`. `B4Vault` is now the tightest at ~310 spare bytes and is the one to
  watch; the doubling rule still applies to anything added to the engine.

## 4. Deliberate exclusions

Carry mode; arbitrary router callbacks; protocol bridge custody; rebasing/fee-on-transfer/
blacklistable directional assets (settlement USDC excepted); governance/upgrade/admin
withdrawal; automatic liquidation/insurance; tax classification; any Pool-quality guarantee.
These are security boundaries, not dormant extension points.

## 5. Release gates (funded, mandatory — none provable off-chain)

Every source release: format, size (EIP-170), full test suite, static analysis (reject
high-severity). Every production deployment additionally proves with funded transactions on
the target network:

1. canonical USDC identity, decimals, and both class-transfer directions — including that the
   quote token `usdClassTransfer` moves **is spot token index 0**, which binding now asserts
   (`DescriptorLib.verifySettlement`) and therefore cannot be configured around;
2. each directional token's signed decimal conversion + round trip;
3. **fresh-account activation** and one-time-fee behavior (`HAZARDS.md` A9);
4. spot asset id / lot rounding / IOC encoding / price bounds;
5. perp price/size/entry-notional/position scaling;
6. margin in/out, positive harvest, realized loss, principal reconciliation;
7. partial exits: full flatten to raw zero, complete margin return, proportional payment,
   remaining-vault resync;
8. partial / no / delayed fill and retry behavior;
9. Core debit + EVM receipt on every return path;
10. **CoreWriter action atomicity** and no delayed-double-execution across a resend
    (`HAZARDS.md` A7/A11);
11. **reduce-only can close to raw `szi == 0`** (`HAZARDS.md` A10);
12. light-client publication + LayerZero delivery with production libraries/DVNs;
13. permanent delegate removal after LayerZero config;
14. deployed-runtime-bytecode equality via a reproducible-build manifest for every contract
    (including those carrying constructor immutables) + published constructor args and Pool
    descriptors;
15. precompile gas-cost calibration (any per-call gas caps confirmed against live costs);
16. **Cancun EVM opcodes live on the target chain** — EIP-1153 `TSTORE`/`TLOAD` and
    EIP-5656 `MCOPY`. The whole tree is compiled at `evm_version = "cancun"`
    (`foundry.toml`) and both opcodes reach the deployed runtime, but they fail in
    opposite ways. `MCOPY` is emitted for every dynamic memory copy and appears in nearly
    every deployed contract — in `B4Pool` it is the `abi.decode` of precompile returndata inside
    `CoreReader`, on the path `advance()` uses to lock checkpoint prices — so a chain
    without EIP-5656 breaks LOUDLY and everywhere: no interval locks and nothing is ever
    distributed. `TSTORE`/`TLOAD` occupy exactly three sites, all in
    `B4Pool.beginPenalty`/`capturePenalty` (the H-1 measured-receipt window), and
    `B4VaultOps._finalizeExit` calls both inside `try/catch`; so on a chain that has
    `MCOPY` but not EIP-1153 they revert, **no revert surfaces anywhere**, and penalty
    escrow SILENTLY never accrues — sleeves are never funded, `foldPenalty` has nothing to
    fold, and invariant 19's strict-Product-Pool routing degrades into the legacy shared
    basket with no on-chain signal. That silent half is the reason this is a gate. Unlike
    the rest of this list it is provable with a single `eth_call`; prove it **before** any
    pool is created and record the result. The exact probe (bytecode, expected return,
    both the code-override and deployed forms) is `docs/06-deployment.md` §6, gate 16.

Mainnet MUST NOT proceed until these are recorded and independently reviewed. Given the
earlier engagement (a permanent-freeze High survived three audit rounds), the async
completion/retry, harvest-quota, and recovery paths in the new implementation SHOULD receive a
dedicated independent audit round of their own.
