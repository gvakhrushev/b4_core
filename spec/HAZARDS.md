# B4 — hazard map (design requirements from hard-won experience)

Every item below is a failure class discovered while implementing and auditing an earlier
version of B4 (one Medium, several Highs including permanent-freeze bugs, plus economic and
documentation defects — some missed by multiple independent audit rounds). Each is stated as
a **design requirement with rationale**, so a fresh implementation avoids the trap by
construction. Read this before writing any asynchronous or accounting code.

The single most important lesson: **on the asynchronous surface, "looks clean" is not "is
clean."** Treat every completion/retry rule and every state-gate interaction as guilty until
adversarially proven innocent.

---

## A. Asynchronous execution (the highest-risk surface)

Execution against the trading venue is asynchronous: emitting an action is not proof it ran;
its effect must be proven by a later on-chain state read.

- **A1 · Prove-then-credit.** A CoreWriter/venue action's success MUST NOT finalize a trade,
  transfer, or accounting update. A later block MUST prove the effect via a state read. Never
  credit from an emitted intent alone.

- **A2 · Key completion on the RELIABLE balance only.** Inferring "the transfer completed"
  from a balance delta is safe *only* for a balance our own action alone can move.
  - The Core **spot** balance is decreased only by our action (external transfers can only
    ADD). A spot NET-DECREASE reliably proves our transfer executed.
  - The perp **withdrawable** balance drifts with unrealized PnL (an open residual position)
    AND is externally toppable via a standard transfer. It MUST NEVER be used as a completion
    or retry counter.
  - Therefore: `spot→perp` completes on spot net-decrease; `perp→spot` completes on spot
    net-increase; `spot→EVM` completes on spot net-decrease + destination received the full
    amount. *(This exact bug — keying on the perp balance — survived three audit rounds.)*

- **A3 · Resend must be the EXACT complement of completion.** Not stricter, not looser. A
  stricter resend gate (e.g. "source unchanged" instead of "source did not net-decrease")
  freezes forever when a 1-unit external top-up perturbs the source; a looser gate
  double-applies a merely delayed action. There must be no post-timeout dead zone.

- **A4 · No recorded claim may exceed what a single later call can settle.** If you record a
  claim (e.g. a harvest quota of realized PnL) and later try to settle the *full* claim, an
  intervening adverse move can drop the settleable amount below the claim. If every other
  entrypoint is then gated on "claim == 0", the vault is **permanently frozen**. Requirement:
  settle `min(claim, currently-available)`, and always be able to **clear** the residual claim
  (the unsettled part stays as recoverable surplus, not a blocking phantom). *(This was a
  total-fund-freeze High missed by every prior review.)*

- **A5 · No gate may block its own escape.** If a pending claim/intent gates the very
  operations that would resolve it (e.g. a harvest quota blocks the position-reduce that
  would free the margin needed to harvest), you have a deadlock. Order the state machine so
  the resolving action is always reachable; drain/clear blocking claims before the steps they
  would block.

- **A6 · Emergency recovery for every stuck class — but never discard funds.** Provide a
  timed owner escape for every intent that could hang. Distinguish two cases:
  - Abandoning a **surplus-recovery** intent is safe: the funds stay on Core and are
    re-recoverable, so it may be emergency-cleared.
  - Discarding an **asset-transfer** intent is forbidden: funds could still land afterward and
    be lost from accounting. With A2/A3 in place, transfer intents always progress after the
    timeout and never need discarding.

- **A7 · Atomicity differs by action type — handle them differently.** Intra-Core transfers
  (spot↔perp) are assumed atomic (source-decrease ⇔ destination-increase, all-or-nothing);
  Core→EVM has a debit-then-deliver window (source may decrease before the destination
  receives). Never resend a Core→EVM leg once the source has decreased (it executed; wait).
  These atomicity properties are **funded-network assumptions** — see `SECURITY_MODEL.md`.

- **A8 · Native deposits are not re-emittable.** An EVM→Core transfer to a system address is
  not a re-sendable action; re-poll the balance until it credits. A *permanent* drop is an
  ecosystem-wide venue failure, not a B4-specific bug — document the assumption; do not build
  a local "abandon" that could discard funds that later arrive.

- **A9 · Fresh-account activation.** Each new execution/Core account may require activation
  (e.g. a quote-token fee) before it can send actions, and may not serve precompile reads
  until active; an activation fee may be deducted from the first credit. Gate the first
  margin/spot action on proven activation, and make the first funding tolerant of the fee.
  This is funded-only to prove.

- **A10 · Strict custody flatness.** Custody boundaries — margin return, exit NAV
  realization, loss reconciliation — MUST require the raw position size to be exactly zero,
  not "within an epsilon". A fine-lot market leaves dozens of sub-epsilon lots live, so an
  epsilon "flat" check returns principal over an open position. Keep the epsilon tolerance
  only for non-zero rebalance targets; a full close targets exact zero. (Confirm on funded
  tests that a reduce-only order can always close to raw zero.)

- **A11 · Bound credit in both directions; make the residual benign.** Never credit more than
  the intended amount (cap it), and never let a destination-side top-up fake a completion into
  an over-credit. The irreducible residual under balance-inference — a `≥ amount` external
  top-up faking a signal once — MUST be attacker-funded, never a freeze or theft, and leave
  real assets ≥ books, recoverable via surplus recovery. Full closure of even this residual
  requires a venue action receipt/nonce (funded); design toward it.

- **A12 · A timer never replaces a proof.** Do not "solve" async by rate-limiting operations
  and assuming settlement after a delay. "It's been a day, surely it landed" is strictly worse
  than a state/receipt proof — the venue may still not have processed the action. Cooldowns
  address economic attacks, not async-completion correctness, and the state machine already
  serializes to one in-flight operation.

- **A13 · A planner step reports progress ONLY when it actually acted.** A crank step that
  decides to trade but whose order rounds to a no-op (a spend/size below one whole lot floors
  to zero) MUST NOT return "progressed". Two failures ride on this: (1) if the step
  short-circuits later legs (spot rotation before perp sizing), the un-acted leg — e.g. the
  perp hedge — is **never sized**, so the vault silently holds unmanaged exposure; (2) the
  keeper loop, which stops only on "no progress", spins forever burning gas on the false
  signal. Requirement: the intent-creating helpers return whether an intent was actually
  snapshotted, and the planner returns `true` only on a real state change (a new intent, or a
  claim/quota genuinely cleared) — a want-to-trade-but-sub-lot residual falls through to the
  next leg and, once nothing is left to do, the step returns `false`. Note the trap only
  surfaces when one lot is worth MORE than the rebalance band; a fixture where one lot equals
  the band floor hides it, so test on a **coarse-lot** market. *(This was a Medium liveness
  defect — a `return true` that conflated "no-op" with "progressed", found in a post-build
  adversarial audit.)*

---

## B. Accounting and value integrity

- **B1 · Measure actual received deltas.** Accounting MUST grow only by a measured balance
  increase, never a requested amount or an unmeasured/unsolicited transfer (donation).
- **B2 · Reconcile realized loss before EVERY valuation.** Any path that values NAV — settle,
  exit, sync — MUST first write recorded principal down to the actual withdrawable value when
  flat. Reconciling in *some* paths but not others over-reports profit/weight in the missed
  one. *(This was a real Medium — settle was the missed path.)* The dual trap: a
  self-initiated perp-side transfer in flight (an executed but unverified margin return)
  depresses the withdrawable BY DESIGN — writing that dip down as "loss" reclassifies
  returning principal as later fee-bearing profit. The robust discipline: run EVERY
  valuation (settle, exit, sync) only at an idle engine, so reconcile always sees real PnL
  and never the protocol's own in-flight transfers. Settlement in particular — which pays
  the fee and reports weight irreversibly — must reject an in-flight engine, not attempt a
  mid-transfer valuation (a partial-fix that merely suppressed reconcile during transfers
  still over-reported when a genuine loss coincided with one).
- **B3 · Keep unrealized and unverified value out.** Unrealized PnL and unverified Core
  surplus never enter the realized ledger; owner-deposited margin stays separate from strategy
  capital.
- **B4 · Entry ledger integrity.** A deposit adds its current value to the interval entry
  ledger so new principal cannot read as profit; changing token form (spot↔USDC, margin moves)
  MUST NOT change the entry ledger.
- **B5 · Floor toward the protocol.** All fixed-point division floors; fees, penalties, cuts,
  and pool claims never round up; residual dust stays with the protocol/pool.
- **B6 · Bounded, callback-free surplus recovery for spot AND perp.** Surplus above recorded
  principal/liability (from external top-ups, favorable fills, or funding) is recoverable to
  the owner, bounded to `balance − recorded`, flat-and-idle, with no accounting callback (so
  the vault's books stay true).

---

## C. Economic / policy decisions (NOT bugs — decide explicitly, document)

- **C1 · Funding-income fee policy.** Positive perp funding raises withdrawable above
  principal but is on-chain indistinguishable from an external top-up. Decide whether funding
  gains bear the operator fee. (Prior version: not taxed; funding *losses* are still borne — an
  asymmetry, not a safety issue.)
  **Decided (2026-07-18): not taxed.** Harvest credit is bounded by snapshotted mark-PnL, so
  funding surplus never enters the realized ledger; it is owner-recoverable surplus. The
  asymmetry (losses borne) stands, documented.
- **C2 · Exit-time reward-weight valuation.** No mid-interval price snapshot exists, so exit
  profit is valued at the live oracle while settle weight is snapshot-protected. Decide whether
  mid-interval-exit profit earns Pool weight; naively denying it harms legitimate long-term
  holders, and the vector is economically inert under a deep venue.
  **Decided (2026-07-18): earns weight** — one unified fee mechanism (the exiting share's
  client share enters the reward base, `SPECIFICATION.md` §9); the penalty is separate logic
  on top. Live-oracle valuation accepted as economically inert under a deep venue.
- **C3 · `USDC = 1 USD`.** A depeg is undetected and mis-values fees/ledgers/weights. Decide
  whether to add a cross-check.
  **Decided (2026-07-18): fixed 1 USD, no cross-check** — no second trust dependency, no
  halt path (H3); the residual is disclosed (`SECURITY_MODEL.md` §3).
- **C4 · Oracle sanity band.** There is no independent second oracle; a price band is
  defense-in-depth against a manipulated/erroneous read but adds a dependency. Decide.
  **Decided (2026-07-18): no band** — the 500/50 bps execution envelopes are the defense;
  the venue oracle remains a disclosed trusted dependency.
- **C5 · Leverage sizing.** A flat leverage multiple has no relation to where the cycle's
  confirmed support sits, and a running NAV-relative target re-trades the position daily —
  neither is intended. Decide how a leveraged long is sized and how far its risk may reach.
  **Decided (2026-07-21): structural leverage floor, sized once per zone** (`SPECIFICATION.md`
  §7b). The effective leverage is `g·p/(p − floor)` capped by the most recent confirmed
  structural low, where the two anchors ratchet up at the 62-window and the post-halving
  window. Rationale and consequences, all deliberate:
  - **Risk is bounded by structure, not by user optimism.** The stop sits at a golden-ratio
    retrace toward a price the market has already proven and held, so a position cannot be
    sized to liquidate above the last confirmed low. Real-data check: a φ-long opened in
    2019–2020 survives the −53% March-2020 day *only* with the cap; the flat formula
    liquidates.
  - **Leverage self-adjusts to entry.** Entry near the low earns high (structurally justified)
    leverage; a late entry after a long run decays toward `1×`. The operator sets the base `g`
    (the ceiling); the floor mechanism sets where it is applicable — together they bound
    realized risk. Effective leverage MAY exceed `φ` near the low; that replaces the flat
    `|resolved| ≤ φ` cap for leveraged products.
  - **Sized once, held until rotation.** No daily NAV rebalance ⇒ no volatility drag inside a
    zone; the calendar is the rebalance schedule. The trade-off: within a zone the effective
    leverage drifts with price (the position is fixed in *size* — the contract count `szi` —
    so both notional and leverage drift with price, never re-traded to hold a ratio, which is
    exactly the drag being removed) — accepted.
  - **The `min` price ratchet is a new permissionless surface.** It is sampling-only (reads the
    venue spot price, writes a monotone-within-window minimum), moves funds for no one. Its
    safety is directional: **more sampling lowers the recorded low ⇒ lowers leverage**, so the
    honest failure mode is under-sampling (a keeper samples each window; the pool benefits). An
    unsampled window installs no cap, so a leveraged product falls back to the flat base `g`
    (pre-mechanism behaviour), never to a false ceiling. A lower low across cycles does not
    raise leverage (advances only at the halving flip). Long-only; shorts keep
    the flat base.

---

## D. Pool and distribution

- **D1 · Commit the checkpoint-price lock only after ALL assets priced.** If the lock is set
  before pricing and one asset transiently prices to zero/reverts, the zero is committed with
  no retry and settle reverts for every vault sharing that token for the whole window. Leave
  the interval unlocked on any failure so a later call within the snapshot window retries.
  *(Real freeze-an-interval bug.)*
- **D2 · Liability discipline.** Pool liability grows only by real token receipt; distribution
  never exceeds nominal liability; `token balance ≥ total liability` is an invariant.
- **D3 · Order-independent loss socialization.** On a shortfall, recompute each claim's haircut
  against the correspondingly reduced balance and liability, so claim order cannot place the
  whole deficit on the last claimant.
- **D4 · Single sweep, unchanged liability.** Expired inventory sweeps once into the active
  interval and never changes total liability.
- **D5 · Retryable per-token claims.** A failed token transfer leaves that token's claim
  retryable without reverting the already-successful token claims.

---

## E. Calendar and cross-chain

- **E1 · No wall-clock acceptance window for the halving.** Bitcoin fixes the halving
  *height*, not the interval — historically the interval has been well under the nominal cycle
  (~1319 vs 1460 days). Accept the next canonical height on a **monotonic, not-in-future**
  timestamp only. A predicted-time window can permanently halt an un-upgradeable calendar.
  *(Real permanent-halt bug.)*
- **E2 · Tolerate a variable cycle.** The zone calendar rests in the terminal regime after the
  last transition until the next real halving is accepted; it must not depend on the realized
  interval matching the nominal one.
- **E3 · Cryptographically bound facts.** Light-client hash ⇔ header; timestamp derived from
  header bytes; receiver binds source EID + sender; delivery idempotent by height (a
  conflicting fact reverts); the endpoint configurator delegate is removed one-shot before
  production.
- **E4 · Genesis / epoch-boundary edges.** Handle first-epoch `epoch − 1` keys, `t = now −
  halvingTs` subtraction, and the first reportable interval with no underflow and clean
  reverts.

---

## F. Authority, access, griefing

- **F1 · No authority.** No admin, upgrade, pause, or privileged transfer. Every remedy is a
  permissionless crank or an owner-only recovery that cannot create authority.
- **F2 · Safe permissionless entrypoints.** Recipients hardcoded (never attacker-chosen),
  direction not attacker-selectable, loops bounded by the asset whitelist. A permissionless
  crank only advances legitimate state or pays the fixed owner.
- **F3 · Safe initialization.** Atomic factory binding; one-shot re-init guards; no
  half-initialized state; no front-run window; asset-binding cannot precede initialization.
- **F4 · Reentrancy.** Guards on every fund mover; no cross-contract call makes a callback into
  a mid-execution accounting function.

---

## G. Observability and operations

- **G1 · Emit an event on every otherwise-invisible value movement** — especially silent
  write-downs (realized loss) and recoveries — so keepers/users detect them without diffing
  storage.
- **G2 · Ship a keeper that cranks EVERY step.** Verify, finalize, progress-exit, sync,
  lock-prices, distribute, sweep, advance-calendar. A single missing crank (a real one:
  progress-exit) silently strands multi-step operations.
- **G3 · Documentation is normative and must track the code exactly.** A spec/runbook that
  describes superseded behavior is a defect — it misleads auditors and operators. Update them
  in the same change as the code.

---

## H. Process requirements (for the implementer and reviewers)

- **H1 · Adversarial verification per fix.** Each fix ships a fail-before/pass-after regression
  test AND an independent adversarial attempt to break it, before it is called fixed.
- **H2 · Full stateful invariant campaigns** over the documented safety invariants (see
  `SECURITY_MODEL.md` / `TEST_PLAN.md`), not only example tests. Balance-inference and
  state-gate interactions are where the missed bugs lived.
- **H3 · The worst case must be delayed liveness, self-healing by cranking** — never fund loss,
  never a permanent freeze. Design every async/gate path to that standard.
