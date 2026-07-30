# Clean-room handoff prompt (historical record)

> **This is provenance, not instructions.** It is the prompt that started this repository: the
> implementation was built clean-room from a specification package, deliberately without sight of
> any earlier contract source, so that no latent bug could ride along. The build it asks for is
> the one in this repository, and the specification it names now lives in [`../../spec/`](../../spec/)
> — the package folder it refers to no longer exists as a separate copy, because keeping a second
> byte-identical set of the same documents only creates two things to forget to update.
>
> Kept because the *reason* the code looks the way it does is recorded here — chiefly the rule
> that `HAZARDS.md` is binding design input rather than background reading. Read it as history;
> read [`../../spec/`](../../spec/) for anything normative.

---

You are a senior smart-contract engineer implementing a DeFi protocol **from scratch** from a
specification package. This is a clean-room build: a prior implementation existed and was
audited across multiple rounds, but you must NOT see or reuse its code — that is deliberate,
so no latent bug rides along. You inherit only the specification and the distilled design
lessons in this folder.

## Read first, in this order
*(Paths as they are today — the package's six documents live in [`spec/`](../../spec/), and the
seventh, its own README, was folded into the repository root README.)*
1. [`README.md`](../../README.md) — how the pieces fit together and what to carry vs. not carry.
2. [`spec/WHITEPAPER.md`](../../spec/WHITEPAPER.md) — what the protocol is and why (economics,
   thesis, product ladder).
3. [`spec/REQUIREMENTS.md`](../../spec/REQUIREMENTS.md) — actors, products, lifecycle, commercial
   model.
4. [`spec/SPECIFICATION.md`](../../spec/SPECIFICATION.md) — the normative target behavior
   (`MUST`/`MUST NOT`). This is what you implement.
5. [`spec/HAZARDS.md`](../../spec/HAZARDS.md) — **read this before writing any asynchronous or
   accounting code.** It is a map of real failure classes (including permanent-freeze bugs that
   survived three audit rounds in the prior build), each stated as a design requirement with
   rationale. Treat it as binding.
6. [`spec/SECURITY_MODEL.md`](../../spec/SECURITY_MODEL.md) — trust boundaries, the safety
   invariants to preserve, and the funded-network release gates.
7. [`spec/TEST_PLAN.md`](../../spec/TEST_PLAN.md) — the verification bar you must meet.

## What to build
Implement the protocol in `SPECIFICATION.md` on the target environment named there (HyperEVM +
HyperCore; a Citrea-proven Bitcoin-halving fact transported by LayerZero; canonical USDC
settlement). Use Foundry. Structure the contracts however is cleanest — the spec defines
behavior, not layout — subject to the constraints in `HAZARDS.md`.

## Hard rules (non-negotiable)
- **Design to `HAZARDS.md`.** In particular: async completion/retry MUST key only on a balance
  your own action reliably moves (never a PnL-driven or externally-toppable one); every resend
  condition is the exact complement of its completion condition; no recorded claim may exceed
  what a single later call can settle, and no pending claim may gate the operation that
  resolves it; custody flatness is strict (raw position == 0); the worst case of any async or
  gated path is delayed liveness that self-heals by cranking — never fund loss or a permanent
  freeze.
- **No authority.** No admin, upgrade, pause, or privileged fund mover.
- **Measure actual received deltas**, floor all division toward the protocol, and reconcile
  realized loss before every NAV valuation.
- **"Looks clean" is not "is clean" on the async surface.** For every async/accounting fix or
  mechanism, write a fail-before/pass-after test AND make an independent adversarial attempt to
  break it before considering it done.
- **Documentation is normative** — if you change behavior, update the spec/docs in the same
  step. Never let a doc describe superseded behavior.
- **Do not use a timer to replace a state/receipt proof**, and do not "solve" async with a
  rate limit — the state machine already serializes to one in-flight operation.

## Verification bar (must pass before you call it done)
- `forge build` clean, `forge fmt --check` clean, full `forge test` green.
- Every mandatory regression in `TEST_PLAN.md §2–4` implemented (these encode the exact traps
  that were missed before — especially: reliable-balance completion under adverse perp PnL /
  external top-up; exact-complement resend; the harvest-quota deadlock; strict flatness;
  checkpoint-price poisoning; fast-cycle halving acceptance with no wall-clock window).
- Stateful invariant campaigns asserting every invariant in `SECURITY_MODEL.md §2`.
- A traceability map from each invariant to the tests that assert it, with honest GAP markers.
- Mark every item in `SECURITY_MODEL.md §5` / `TEST_PLAN.md §5` as a funded-network gate — do
  NOT claim venue atomicity, account activation, or reduce-to-raw-zero as locally proven; local
  mocks cannot faithfully reproduce venue timing.

## How to work
- Plan before coding: propose the contract decomposition and the async state machine, checked
  against `HAZARDS.md`, before implementing.
- Build incrementally and keep the suite green at each step.
- Economic/policy forks: the four in `HAZARDS.md §C` (funding-income fee, exit-weight
  valuation, USDC depeg, oracle band) are already decided — follow the
  **Decided (2026-07-18)** notes there. If you hit a NEW economic/policy fork not covered
  by a decided-note, do NOT decide unilaterally: surface it, state the trade-off, and ask.
- Deliverable: the Foundry project (contracts + tests), a `SPECIFICATION`-conformant build, the
  invariant traceability map, and a short report of what is proven locally vs. what remains a
  funded gate. Status is pre-mainnet until an independent audit and the funded gates are done.

Ask clarifying questions before starting if anything in the package is ambiguous.
