# Fees, penalty and the pool

This page documents exactly how B4 charges a performance fee, how that fee is split between operator, referrer and client, how the early-exit penalty is taken, and how the shared `B4Pool` distributes what it holds — all as implemented in the shipped source, not as intended.

> Status: the protocol is **pre-mainnet and not externally audited**. Venue semantics (CoreWriter atomicity, account activation, precompile behaviour) are not locally provable and remain funded release gates — see [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §5.

Source of truth for this page: [`src/libraries/Phi.sol`](../src/libraries/Phi.sol), [`src/core/B4VaultOps.sol`](../src/core/B4VaultOps.sol), [`src/core/B4Vault.sol`](../src/core/B4Vault.sol), [`src/core/B4VaultStorage.sol`](../src/core/B4VaultStorage.sol), [`src/core/B4Pool.sol`](../src/core/B4Pool.sol), [`src/libraries/Calendar.sol`](../src/libraries/Calendar.sol).

---

## 1. The constants

All economic rates are compile-time constants in `Phi`. There is no setter, no admin, no governance path that can change them.

```solidity
/// Virtual performance-fee rate f = φ⁻⁵/2 (SPECIFICATION §8), WAD.
uint256 internal constant FEE_F = 45084971874737120;
/// Exit penalty rate q = φ⁻³/2 (SPECIFICATION §9), WAD.
uint256 internal constant EXIT_Q = 118033988749894848;

uint256 internal constant BPS = 10_000;
/// operatorBps ≤ 38.19% of the virtual fee (SPECIFICATION §2).
uint256 internal constant MAX_OPERATOR_BPS = 3819;
/// referrerBps ∈ [38.19%, 100%] of the operator payment (SPECIFICATION §2).
uint256 internal constant MIN_REFERRER_BPS = 3819;
```

| Symbol | Value (WAD) | Decimal | Meaning |
| --- | --- | --- | --- |
| `FEE_F` (f = φ⁻⁵/2) | `45084971874737120` | ≈ 4.508497 % | virtual performance fee on interval profit |
| `EXIT_Q` (q = φ⁻³/2) | `118033988749894848` | ≈ 11.803399 % | early-exit penalty on the exiting gross |
| `MAX_OPERATOR_BPS` | `3819` bps | 38.19 % | ceiling on the operator's share **of the virtual fee** |
| `MIN_REFERRER_BPS` | `3819` bps | 38.19 % | floor on the referrer's share **of the operator payment** |

Consequence of the ceiling: the maximum an operator can ever take is `f × 38.19% ≈ 1.7218 %` of interval profit. The remainder of the virtual fee (`≥ 61.81 %` of `f`, i.e. `≥ 2.7867 %` of profit) is the **client share** and never leaves the client's economic side — it becomes pool reward weight.

All fixed-point division in `Phi` floors (`mulDiv`, `wmul`, `bps`), documented as HAZARDS B5: fees, penalties, cuts and pool claims never round up, and dust stays with the protocol / the remaining vault.

---

## 2. The fee route: validated once, immutable forever

The route is a plain struct in `B4VaultStorage`:

```solidity
struct FeeRoute {
    address operator;
    uint16 operatorBps; // of the virtual performance fee, ≤ 3819
    address referrer;
    uint16 referrerBps; // of the operator payment, ∈ [3819, 10000] when referrer set
}

FeeRoute public route;
```

It is written exactly once, in `B4Vault.initialize`, after validation:

```solidity
function _validateRoute(FeeRoute calldata r) internal pure {
    if (r.operatorBps > Phi.MAX_OPERATOR_BPS) revert BadRoute();
    if (r.operatorBps > 0 && r.operator == address(0)) revert BadRoute();
    if (r.referrer != address(0)) {
        // A referrer requires a non-zero operator rate and a protected share (SPEC §2).
        if (r.operatorBps == 0) revert BadRoute();
        if (r.referrerBps < Phi.MIN_REFERRER_BPS || r.referrerBps > Phi.BPS) {
            revert BadRoute();
        }
    } else if (r.referrerBps != 0) {
        revert BadRoute();
    }
}
```

`route = route_;` in `initialize` is the **only** assignment to `route` anywhere in `src/`. There is no `setRoute`, no admin, and no upgrade proxy — `B4VaultOps` is reached by delegatecall from an address fixed as an immutable of the vault implementation at deployment, which is EIP-170 code splitting, not an upgrade path.

The route is chosen by the caller of `B4Factory.createVault`, who also becomes the vault's fixed owner:

```solidity
function createVault(
    address pool,
    bytes32 dirDescriptorHash,
    address strategy,
    uint256 scaleWad,
    uint16 slippageBps,
    B4VaultStorage.FeeRoute calldata route
) external returns (address vault);
```

By sending that transaction the owner signs the whole configuration, route included. A `route` with `operator == address(0)` and `operatorBps == 0` is valid: such a vault pays no operator fee at all, and the entire virtual fee is client share.

### Referral is carved OUT OF the operator payment

```solidity
/// @dev The referral is carved only from the operator payment (SPEC §2).
function _routeFee(address token, uint256 amount) internal {
    if (amount == 0) return;
    uint256 refShare = route.referrer == address(0) ? 0 : Phi.bps(amount, route.referrerBps);
    if (refShare > 0) _payOut(token, route.referrer, refShare);
    if (amount - refShare > 0) _payOut(token, route.operator, amount - refShare);
}
```

`referrerBps` is applied to `amount` — the operator payment for that token leg — not to the virtual fee. Adding a referrer therefore **never increases** what the client pays; it only redivides the operator's slice. The `MIN_REFERRER_BPS` floor means a referrer, once set, is guaranteed at least 38.19 % of that slice.

`_payOut` is pay-or-defer: if a recipient's transfer fails (e.g. a blacklisted USDC address), the amount is recorded in `deferredPayout[to][token]` / `deferredPayoutTotal[token]`, a `PayoutDeferred` event is emitted, and settle/exit continue. Deferred amounts are permissionlessly retryable via `claimDeferred` → `opsClaimDeferred`, pay only the recorded recipient, and are excluded from unaccounted-EVM recovery so the owner cannot sweep them.

---

## 3. The virtual fee at settlement

`opsSettle(intervalId)` runs at a pool checkpoint, against the pool's locked checkpoint price, on an **idle** engine with no exit pending (`ExitPending`), only once per interval (`AlreadySettled`), only while the interval is price-locked and still inside its report window (`NotSettleable`), only while any still-open perp already carries the sign of the current target's perp leg — the previous regime's opposite-sign exposure must have unwound through a verified zero first (`WrongSignPerp`) — and after `_reconcile()`:

```solidity
uint256 pxWad = IB4PoolVault(pool).lockedPxWad(intervalId, _dirAssetIndex);
uint256 nav = _navWad(pxWad);
uint256 e = entryLedgerWad;
uint256 profit = nav > e ? nav - e : 0;
uint256 virtualFee = Phi.wmul(profit, Phi.FEE_F);
uint256 operatorCut = Phi.bps(virtualFee, route.operatorBps);
uint256 clientShare = virtualFee - operatorCut;
```

- The measure is **interval profit over the entry ledger** `E` (`entryLedgerWad`), not lifetime profit and not an unrealized high-water mark. `E` is incremented by each `deposit` at the value actually received (`B4Vault.deposit`, accounted from the measured delta), and re-anchored at every settlement.
- If `nav ≤ E`, `profit` is 0 and the whole fee machinery pays nothing. There is no fee on a losing interval and no fee on principal.
- The fee is "virtual" because only the `operatorCut` part is ever transferred out. `clientShare` is not moved; it is added to `rewardBaseWad`.

### The operator cut is paid in kind, and settle demands repatriation

```solidity
if (operatorCut > 0 && _evmBasketWad(pxWad) < operatorCut) revert FeeNotRepatriated();

lastSettledPlusOne = intervalId + 1;
uint256 paidVal = _payOperatorInKind(operatorCut, pxWad);
entryLedgerWad = nav - paidVal;
rewardBaseWad += clientShare;
if (rewardBaseWad > 0) {
    IB4PoolVault(pool).reportWeight(intervalId, rewardBaseWad);
}
```

`_evmBasketWad` is the value of the **accounted EVM basket** only — `dirEvm` priced at the checkpoint price, plus `usdcRotatedEvm` and `usdcMarginEvm` at 1 USD:

```solidity
function _evmBasketWad(uint256 pxWad) internal view returns (uint256) {
    return Phi.wmul(_toWad(dirEvm, _dir.evmDecimals), pxWad)
        + _toWad(usdcRotatedEvm, _usdc.evmDecimals) + _toWad(usdcMarginEvm, _usdc.evmDecimals);
}
```

The `FeeNotRepatriated` check exists because an idle-but-not-repatriated vault (value still sitting on Core) has an empty EVM basket; without the check, settle would waive the cut yet still re-anchor the entry ledger and report the **full** client weight — a fee dodge plus a pool-weight-integrity break (tracked as V3-ACCT-1). Since the cut is at most ~1.72 % of profit, a properly cranked vault always clears it; a stuck vault simply misses its report window, which is a liveness residual (H3), not a custody risk.

`_payOperatorInKind` takes the payment proportionally from each accounted EVM bucket — there is **no swap**:

```solidity
uint256 payWad = Phi.min(valueWad, basketWad);
uint256 dirPay = Phi.mulDiv(dirEvm, payWad, basketWad);
uint256 rotPay = Phi.mulDiv(usdcRotatedEvm, payWad, basketWad);
uint256 marPay = Phi.mulDiv(usdcMarginEvm, payWad, basketWad);
dirEvm -= dirPay; usdcRotatedEvm -= rotPay; usdcMarginEvm -= marPay;
_routeFee(_dir.evmToken, dirPay);
_routeFee(_usdc.evmToken, rotPay + marPay);
emit FeePaid(route.operator, payWad, route.referrer);
```

If `route.operator == address(0)` or the basket is empty, it returns 0 and nothing is paid. The value actually paid (`paidVal`) is what gets subtracted when re-anchoring: `entryLedgerWad = nav - paidVal`.

### Client share → pool reward weight

`rewardBaseWad` (`R`, WAD USD) accumulates retained client shares and is reported once per interval to the pool:

```solidity
function reportWeight(uint256 id, uint256 weight) external {
    if (!isVault[msg.sender]) revert NotAVault();
    if (weight == 0) revert ZeroWeight();
    ...
    if (it.lockedAt == 0) revert NotLocked();
    if (block.timestamp > reportDeadline(id)) revert ReportWindowClosed();
    if (it.weightOf[msg.sender] != 0) revert AlreadyReported();
    it.weightOf[msg.sender] = weight;
    it.totalWeight += weight;
}
```

Only a factory-registered vault can report; one report per vault per interval; the window is `pointTime + SNAPSHOT_WINDOW (1 hour) + REPORT_WINDOW (2 days)`. Weight is a **claim on the pool basket**, not a token and not a transferable share.

---

## 4. Early exit and the penalty

`initiateExit` sets `exitShareWad = x` (WAD fraction). The exit machine (`_planExitStep`) flattens the perp to a strict zero, harvests PnL, reconciles, returns all Core principal, and only then reaches `_finalizeExit`.

```solidity
uint256 pxWad = _livePxWad();            // live oracle valuation (decision C2)
uint256 nav = _navWad(pxWad);
uint256 profit = nav > entryLedgerWad ? nav - entryLedgerWad : 0;
uint256 virtualFee = Phi.wmul(profit, Phi.FEE_F);
uint256 operatorCut = Phi.bps(virtualFee, route.operatorBps);
uint256 clientShare = virtualFee - operatorCut;

s.grossWad = Phi.wmul(nav, x);
uint256 ocx = Phi.wmul(operatorCut, x);
s.free = Calendar.freeExit(IHalvingOracle(oracle).timeSinceHalving());
if (s.free) {
    s.operatorWad = ocx;
    s.ownerWad = s.grossWad - ocx;
} else {
    // One in-kind penalty; the operator payment is carved from it, never added.
    uint256 penalty = Phi.wmul(s.grossWad, Phi.EXIT_Q);
    s.operatorWad = Phi.min(ocx, penalty);
    s.poolWad = penalty - s.operatorWad;
    s.ownerWad = s.grossWad - penalty;
}
```

Note the shape: outside a free window the exiter pays **exactly one** deduction, `q × gross`. The proportional operator cut `ocx` is taken *out of* that penalty (capped by it), and whatever is left of the penalty goes to the pool. The penalty is never stacked on top of the fee.

### When is the exit free?

```solidity
function freeExit(uint256 t) internal pure returns (bool) {
    if (t < POST_FACT_FREE_EXIT) return true;
    Zone z = zoneAt(t);
    return z == Zone.ClosingGrowth || z == Zone.OpeningFall || z == Zone.ClosingFall
        || z == Zone.OpeningGrowth;
}
```

`t` is time since the latest accepted halving fact. A free exit applies in two situations:

| Free window | Definition |
| --- | --- |
| Post-fact window | `t < POST_FACT_FREE_EXIT`, where `POST_FACT_FREE_EXIT = W = 20 days` |
| The four transition zones | `ClosingGrowth [P−W, P−H)`, `OpeningFall [P−H, P)`, `ClosingFall [T, T+H)`, `OpeningGrowth [T+H, T+W)` |

with `CYCLE = 1460 days`, `W = 20 days`, `H = 10 days`, `P = CYCLE/φ²`, `T = CYCLE/φ`. In a free window `poolWad = 0` and the owner still pays the proportional operator cut `ocx` on realized profit.

### Ledger update and in-kind payout

```solidity
uint256 keep = Phi.WAD - x;
entryLedgerWad = Phi.wmul(e, keep);
rewardBaseWad = Phi.wmul(rewardBaseWad + Phi.wmul(clientShare, x), keep);
exitShareWad = 0;
```

`C·x` is the exiting share's client share — symmetric with the proportional operator cut — and the whole reward base is then scaled by `(1−x)`. The remaining share's open profit settles at the next checkpoint (entry is scaled, not re-anchored), so each share's profit earns client share exactly once and repeated partial exits cannot mint or duplicate weight.

Payout is per accounted bucket, in kind, split by value ratio — again **no swap**:

```solidity
function _payBucket(address token, uint256 bucket, uint256 x, ExitSplit memory s)
    internal returns (uint256)
{
    uint256 out = Phi.wmul(bucket, x);
    if (out == 0) return bucket;
    uint256 toOwner    = Phi.mulDiv(out, s.ownerWad,    s.grossWad);
    uint256 toOperator = Phi.mulDiv(out, s.operatorWad, s.grossWad);
    uint256 toPool     = Phi.mulDiv(out, s.poolWad,     s.grossWad);
    _payOut(token, owner, toOwner);
    _routeFee(token, toOperator);
    _payOut(token, pool, toPool);
    return bucket - toOwner - toOperator - toPool;
}
```

The operator leg goes through `_routeFee`, so the referrer carve-out applies identically on the exit path. The pool leg goes through the same pay-or-defer `_payOut`: if the transfer fails, the penalty is recorded as a deferred payout to the pool address and stays permissionlessly retryable via `claimDeferred`, so `capture()` only accounts it once the transfer actually lands. Once the tokens are there, the pool **accounts** them:

```solidity
if (s.poolWad > 0) {
    try IB4PoolVault(pool).capture() {} catch {}
}
```

The `try/catch` is deliberate: a griefing co-asset in the pool must never be able to freeze an exit (V3-POOL-1). The tokens are already at the pool; any later permissionless `capture()` re-accounts them.

---

## 5. How the pool distributes

`B4Pool` holds a **basket** — the settlement descriptor at index 0 plus 1..N directional descriptors (`MAX_DIRECTIONAL = 8`) — and never swaps between them.

| Step | Function | Who | What happens |
| --- | --- | --- | --- |
| Inventory in | `capture()` | anyone | any balance above `liability[token]` becomes `accruing[i]`, and `liability[token] = bal`. Measured receipt only (D2): a donation becomes inventory, never vault profit. |
| New interval | `advance()` | anyone | materializes the next passed settlement point; the whole `accruing` basket becomes that interval's fixed `bucket[i]` / `remaining[i]`. |
| Price lock | `lockPrices(id)` | anyone | within `SNAPSHOT_WINDOW = 1 hour` of `pointTime`; index 0 is fixed at `Phi.WAD` (USDC = 1 USD, decision C3), every directional index must price non-zero or the call reverts — all-or-nothing (D1). |
| Weights | `reportWeight(id, w)` | the vault, from `settle` | one report per vault per interval, until `reportDeadline = pointTime + 1 hour + 2 days`. |
| Claim | `claimFor(id, vault)` | anyone | pays the vault's `owner()` in kind, pro rata over every basket asset. |
| Expiry | `sweep(id)` | anyone | once the next interval exists, unclaimed `remaining` folds back into `accruing`; liability unchanged (D4). |

Distribution itself:

```solidity
uint256 nominal = Phi.mulDiv(it.bucket[i], w, wTotal);
if (nominal > it.remaining[i]) nominal = it.remaining[i]; // flooring safety
...
uint256 liab = liability[token];
uint256 pay = bal >= liab ? nominal : Phi.mulDiv(nominal, bal, liab);
if (token.tryTransfer(recipient, pay)) {
    it.claimed[vault][i] = true;
    it.remaining[i] -= nominal;
    liability[token] -= nominal;
    emit Claimed(id, vault, i, nominal, pay);
} else {
    emit ClaimDeferred(id, vault, i);
}
```

Properties worth stating plainly:

- **Pro rata by weight, per asset.** `nominal = bucket_i × w / W`, floored. A claimant receives a slice of *every* asset the basket holds, in kind — the pool performs no internal swap and holds no price opinion at claim time.
- **Order-independent shortfall socialization (D3).** If the pool's actual balance of a token is below its recorded `liability`, everyone is paid `nominal × bal / liab`, and *both* `remaining[i]` and `liability[token]` are reduced by the full `nominal`. The ratio `bal/liab` is therefore preserved for later claimants: no one is advantaged by claiming first.
- **Per-token isolation (D5).** A hostile basket token that reverts, OOGs or return-bombs on `balanceOf` is read through `_safeBalanceOf` (gas-capped at `TOKEN_READ_GAS = 100_000`, return copy bounded to 32 bytes) and simply skipped; a failing transfer emits `ClaimDeferred` and leaves that token's claim fully retryable. Healthy tokens — and co-resident vaults — are unaffected.
- **Timing.** Claims open strictly *after* `reportDeadline` (weights final) and close when the interval is swept.
- **Recipient.** `claimFor` is permissionless but pays `IB4VaultOwner(vault).owner()` — the vault's fixed owner. A caller cannot redirect anything (F2).
- **Permissionless creation is not endorsement.** Anyone can call `B4Factory.createPool`; sharing a pool with another vault is a choice the vault creator makes at `createVault` time.

---

## 6. Worked numeric example

Assume a vault with `route = { operator: OP, operatorBps: 3819, referrer: REF, referrerBps: 5000 }` — i.e. the maximum operator rate and a 50/50 referral split. Values are USD (WAD internally).

**Display convention.** Every figure below is the exact on-chain WAD value **truncated** to 6 decimals — the same direction the protocol itself floors, never rounded up. Truncated cells therefore do not necessarily add up to the displayed total; the exact 18-decimal values are listed under each table, and those *do* reconcile exactly.

### 6.1 Settlement with profit

Entry ledger `E = 100,000`; checkpoint NAV = `101,000`.

| Quantity | Formula | Value (trunc. 6 dp) |
| --- | --- | --- |
| `profit` | `nav − E` | `1,000.000000` |
| `virtualFee` | `wmul(profit, f)` | `45.084971` |
| `operatorCut` | `bps(virtualFee, 3819)` | `17.217950` |
| `clientShare` | `virtualFee − operatorCut` | `27.867021` |
| paid to `REF` | `bps(operatorCut, 5000)` | `8.608975` |
| paid to `OP` | `operatorCut − refShare` | `8.608975` |
| new `entryLedgerWad` | `nav − paidVal` | `100,982.782049` |
| `rewardBaseWad` | `R += clientShare` | `R + 27.867021` |

Exact WAD values: `virtualFee = 45.084971874737120000`, `operatorCut = 17.217950758962106128`, `clientShare = 27.867021115775013872`, `refShare = opShare = 8.608975379481053064`, `entryLedgerWad = 100,982.782049241037893872`. Here `paidVal = operatorCut`, because the EVM basket covers the cut — otherwise settle would have reverted `FeeNotRepatriated`.

The `27.867021` is not transferred anywhere; it is reported as this interval's weight and becomes a claim on the pool basket. The `17.217950` leaves the vault as tokens, drawn proportionally from `dirEvm`, `usdcRotatedEvm` and `usdcMarginEvm` — so if the basket were 70 % directional / 30 % USDC by value, `OP` and `REF` each receive ~70 % of their payment in the directional token and ~30 % in USDC. Note that `_routeFee` is applied **per token leg**, so with a mixed basket the referrer's aggregate is the sum of two floors and can land a wei or two below the single-leg figure above. All figures are floored, never rounded up.

### 6.2 Full exit outside a free window

Same vault, `x = 1e18` (100 %), `nav = 101,000`, `E = 100,000`, `Calendar.freeExit(t) == false`.

| Quantity | Formula | Value (trunc. 6 dp) |
| --- | --- | --- |
| `grossWad` | `wmul(nav, x)` | `101,000.000000` |
| `operatorCut` (full-position) | as above | `17.217950` |
| `ocx` | `wmul(operatorCut, x)` | `17.217950` |
| `penalty` | `wmul(gross, q)` | `11,921.432863` |
| `operatorWad` | `min(ocx, penalty)` | `17.217950` |
| `poolWad` | `penalty − operatorWad` | `11,904.214912` |
| `ownerWad` | `gross − penalty` | `89,078.567136` |
| new `entryLedgerWad` | `wmul(E, 1 − x)` | `0` |
| new `rewardBaseWad` | `(R + C·x) × (1 − x)` | `0` |

Exact WAD values: `penalty = 11,921.432863739379648000`, `operatorWad = 17.217950758962106128`, `poolWad = 11,904.214912980417541872`, `ownerWad = 89,078.567136260620352000`. At full precision `ownerWad + operatorWad + poolWad = 101,000.000000000000000000 = grossWad` exactly; the truncated column above sums to `100,999.999998`, which is the display convention, not a leak.

Every one of `ownerWad`, `operatorWad`, `poolWad` is paid **in kind**, bucket by bucket, at the same value ratios. `poolWad` lands in the pool as tokens and is picked up by `capture()` into `accruing`, i.e. it becomes inventory for the *next* materialized interval — funding the clients who stayed.

### 6.3 The same exit inside a free window

`Calendar.freeExit(t) == true` (e.g. `t < 20 days` after an accepted halving fact, or inside any transition zone):

| Quantity | Value (trunc. 6 dp) |
| --- | --- |
| `operatorWad` | `17.217950` |
| `poolWad` | `0` |
| `ownerWad` | `100,982.782049` |

Exact WAD values: `operatorWad = ocx = 17.217950758962106128`, `ownerWad = gross − ocx = 100,982.782049241037893872`. The performance fee on realized profit still applies; the penalty does not.

### 6.4 Pool claim

Suppose interval `id` locked with `totalWeight = 100` and a basket of `1,000 USDC` (index 0) and `2 DIR` (index 1), and vault V reported `weight = 30`.

- `nominal(USDC) = 1000 × 30 / 100 = 300`; `nominal(DIR) = 2 × 30 / 100 = 0.6`.
- If the pool's USDC balance equals its USDC liability, V's owner receives exactly `300 USDC` and `0.6 DIR`, and `remaining`/`liability` drop by those amounts.
- If instead the pool holds only 90 % of its recorded USDC liability, V's owner receives `270 USDC`, while `remaining[0]` and `liability[USDC]` are still reduced by the full `300`. The next claimant faces the same 90 % ratio — the shortfall is shared, not raced.

There is no path by which claiming DIR converts into USDC or vice versa: the pool distributes what it holds, in the proportions it holds it.

---

## 7. What has no authority over any of this

- No protocol admin, no owner-of-protocol, no upgrade proxy, no pause. The only privileged role is the vault's own fixed owner, whose `onlyOwner` powers (`deposit`, `selectPolicy`, `initiateExit`, the three recovery entrypoints that return unaccounted or surplus assets to the owner, and `emergencyClearRecovery`) act on that vault's own capital and cannot alter the route, the fee constants, or anything belonging to another vault or to the pool.
- Strategies (`StrategyMini`, `StrategyB4`, `StrategyPro`, `StrategyProMax` in `src/periphery/ReferenceStrategies.sol`) are **view-only**: they return a `(growth, fall)` target pair and hold no authority over funds or fees.
- The keeper (`src/periphery/Keeper.sol`) is permissionless and calls nothing but permissionless entry points — `advance`, `lockPrices`, `sweep`, `capture`, `claimFor` and the `currentReportable` view on the pool, and `crank`, `settle`, `claimDeferred` on each vault. It cannot change a route, choose a target, market or price, or redirect a payout: every recipient is fixed vault state.
- `FEE_F`, `EXIT_Q`, `MAX_OPERATOR_BPS`, `MIN_REFERRER_BPS` are `internal constant` — changing them requires deploying different bytecode, i.e. a different protocol.

Further reading: [`spec/SPECIFICATION.md`](../spec/SPECIFICATION.md) §2 (route), §8 (settlement), §9 (exit); [`spec/HAZARDS.md`](../spec/HAZARDS.md) B5 and D1–D5; [`INVARIANTS.md`](../INVARIANTS.md); [`REPORT.md`](../REPORT.md) for the internal adversarial-review history behind V3-ACCT-1 and V3-POOL-1 (an independent external audit remains an unmet release gate — [`spec/SECURITY_MODEL.md`](../spec/SECURITY_MODEL.md) §5).
