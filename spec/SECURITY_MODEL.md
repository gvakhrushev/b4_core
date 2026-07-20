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
12. Product/scale change never invokes exit or penalty logic.
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
  supplies it; the user MUST verify.
- **Standard account mode.** Prove on funded fresh accounts.
- **Fixed USDC = 1 USD.** A depeg is undetected (economic decision C3).
- **Liquidity / liquidation.** IOC may fill partially or not at all; the `1/φ` reserve is a
  margin, not liquidation protection.
- **Funding-income fee policy** (economic decision C1) and **exit-weight valuation** (C2) are
  documented asymmetries, not safety bugs.

## 4. Deliberate exclusions

Carry mode; arbitrary router callbacks; protocol bridge custody; rebasing/fee-on-transfer/
blacklistable directional assets (settlement USDC excepted); governance/upgrade/admin
withdrawal; automatic liquidation/insurance; tax classification; any Pool-quality guarantee.
These are security boundaries, not dormant extension points.

## 5. Release gates (funded, mandatory — none provable off-chain)

Every source release: format, size (EIP-170), full test suite, static analysis (reject
high-severity). Every production deployment additionally proves with funded transactions on
the target network:

1. canonical USDC identity, decimals, and both class-transfer directions;
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
15. precompile gas-cost calibration (any per-call gas caps confirmed against live costs).

Mainnet MUST NOT proceed until these are recorded and independently reviewed. Given the
earlier engagement (a permanent-freeze High survived three audit rounds), the async
completion/retry, harvest-quota, and recovery paths in the new implementation SHOULD receive a
dedicated independent audit round of their own.
