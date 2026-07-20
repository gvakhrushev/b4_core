# Security policy

## Status

B4 is **pre-mainnet** and has **not** completed an independent external audit. The mandatory
funded network gates in [`spec/SECURITY_MODEL.md`](spec/SECURITY_MODEL.md) §5 are **not** met.
Do not use this code with real funds.

What *has* been done is documented honestly in [`REPORT.md`](REPORT.md): four internal
adversarial audit rounds, each fix carrying a fail-before/pass-after regression, a stateful
invariant campaign, and a static-analysis gate enforced in CI. Internal rounds are not a
substitute for an external audit — notably, each of the first three rounds found the previous
round's fix incomplete.

## Reporting a vulnerability

**Please do not open a public GitHub issue for a suspected vulnerability.**

Report privately through
[GitHub Security Advisories](https://github.com/gvakhrushev/b4_core/security/advisories/new)
for this repository. If that is unavailable to you, open a public issue containing **only**
a request for a private contact channel — no technical detail.

Please include, as far as you can:

- the affected contract and function (file and line),
- which safety invariant or hazard class you believe is broken
  (see [`spec/SECURITY_MODEL.md`](spec/SECURITY_MODEL.md) §2 and [`spec/HAZARDS.md`](spec/HAZARDS.md)),
- a concrete failure scenario: inputs and state → wrong accounting, frozen funds, or loss,
- ideally a failing Foundry test against this repository.

We aim to acknowledge a report within a few business days. There is currently **no bug
bounty program**; this is a pre-mainnet codebase with no deployed value at risk.

## Scope

**In scope** — anything in `src/` that breaks custody or accounting:

- theft or unauthorized movement of vault funds, or any cross-vault authority,
- a permanent freeze of funds that cranking cannot heal (the worst case of any async or
  gated path must be delayed liveness, never loss),
- phantom accounting: value credited from an unmeasured transfer, a donation, or a claimed
  amount rather than an actual received delta,
- pool liability or distribution errors (`balance ≥ liability`, distribution ≤ nominal),
- a break of any invariant listed in [`spec/SECURITY_MODEL.md`](spec/SECURITY_MODEL.md) §2.

**Out of scope** — documented boundaries, not defects:

- market loss, liquidation, drawdown, or the timing accuracy of the calendar pivots,
- the accepted residuals and deliberate exclusions in `spec/SECURITY_MODEL.md` §3–4
  (for example: funding/basis-carry strategies are out of scope by design; `USDC = 1 USD` is
  fixed by decision),
- venue behavior that the funded release gates exist to verify (CoreWriter atomicity,
  fresh-account activation, precompile semantics) — these are known-unverified, not findings,
- issues in `test/`, `script/`, or documentation wording with no runtime custody impact,
- gas optimization and style.

## Trust boundaries

The **vault, pool and factory** contracts deliberately have **no admin, no upgrade proxy, no
pause, and no privileged fund mover**. There is therefore **no emergency stop**: a report
cannot be mitigated by pausing the system, which is precisely why pre-deployment reports
matter.

Two authority boundaries exist by design and are in scope for reports only if they exceed
what is documented here:

- **Vault owner** — each vault's fixed owner may deposit, re-select a policy, initiate an
  exit, and recover unaccounted/surplus assets **from their own vault only**. They cannot
  alter the immutable fee route, reach another vault, or choose the halving fact.
- **LayerZero configurator delegate** — `HalvingOracle` and `HalvingProver` each hold a
  temporary `delegate` that controls the endpoint's messaging configuration until the
  one-shot `renounceDelegate()` is called. Until then it can influence the message
  verification path for the halving fact (it can never touch funds, vaults, pools or
  targets). Permanently renouncing both, and verifying it on-chain, is a mandatory release
  gate — check `delegateRenounced()` before trusting any deployment.
