// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreTypes} from "../venue/CoreTypes.sol";

/// @title B4VaultStorage — state layout, types, events and errors of a vault.
/// @notice A vault is an isolated clone: one owner, one directional descriptor + the
///         settlement descriptor, one immutable fee route, and its own address as the
///         isolated Core execution identity. Steady-state custody is on the EVM side;
///         Core holds only perp margin and in-flight amounts.
abstract contract B4VaultStorage {
    // ------------------------------------------------------------------ constants
    /// Resend gate for resendable legs — schedules a resend decision, never finalizes
    /// accounting (HAZARDS A12).
    uint256 internal constant RESEND_TIMEOUT = 1 hours;
    /// Owner escape for stuck surplus-recovery intents (HAZARDS A6).
    uint256 internal constant EMERGENCY_TIMEOUT = 3 days;
    /// Owner escape for a Core→EVM return whose credit never arrived (A7 residual). Far longer
    /// than `EMERGENCY_TIMEOUT` because this one REALIZES A LOSS rather than releasing a claim on
    /// funds that still exist: a legitimate return completes within `RESEND_TIMEOUT`, so 30 days
    /// is ~720x any honest delay, while still fitting inside the ~0.94–1.5 year checkpoint
    /// cadence — it can free a vault long before its next settlement.
    uint256 internal constant RETURN_ABANDON_TIMEOUT = 30 days;
    /// Rebalance dead-band: skip trades below 1% of strategy value…
    uint256 internal constant TOLERANCE_BPS = 100;
    /// …or below the venue's $10 minimum order notional.
    uint256 internal constant MIN_ORDER_USD_WAD = 10e18;
    /// Perp IOC price envelope, bps of mark (SPECIFICATION §7).
    uint256 internal constant PERP_ENVELOPE_BPS = 50;
    /// Floor for the per-vault spot envelope. An immutable 0 would emit every IOC at the
    /// mid, which never crosses — a permanently unfillable vault with no setter to fix it.
    uint16 internal constant MIN_SLIPPAGE_BPS = 10;
    /// Allowance for the fresh-account activation fee deducted from the first Core
    /// credit (HAZARDS A9); exact live fee is a funded gate.
    uint256 internal constant ACTIVATION_FEE_USD_WAD = 5e18;

    // ------------------------------------------------------------------ config
    struct FeeRoute {
        address operator;
        uint16 operatorBps; // of the virtual performance fee, ≤ 3819
        address referrer;
        uint16 referrerBps; // of the operator payment, ∈ [3819, 10000] when referrer set
    }

    bool internal _initialized;
    address public owner;
    address public pool;
    address public factory;
    address public oracle;
    uint16 public slippageBps; // spot envelope, ≤ 500
    FeeRoute public route;
    CoreTypes.AssetDescriptor internal _dir;
    CoreTypes.AssetDescriptor internal _usdc;
    uint256 internal _dirAssetIndex; // index of the directional asset in the pool

    /// Stored policy: resolved signed WAD targets (strategy read once at selection).
    int256 public growthTarget;
    int256 public fallTarget;

    // ------------------------------------------------------------------ accounting
    /// Directional capital on EVM (token units).
    uint256 public dirEvm;
    /// Rotated/realized strategy settlement on EVM (USDC units).
    uint256 public usdcRotatedEvm;
    /// Owner margin reserve on EVM (USDC units) — never increases strategy notional (B3).
    uint256 public usdcMarginEvm;
    /// Verified principal on Core spot (wei units).
    uint64 public coreDirWei;
    uint64 public coreUsdcRotatedWei;
    uint64 public coreUsdcMarginWei;
    /// Verified margin principal in the perp account (1e6 USD).
    uint64 public perpMargin6;
    /// Interval entry ledger E (WAD USD).
    uint256 public entryLedgerWad;
    /// Reward base R (WAD USD) — retained client shares.
    uint256 public rewardBaseWad;
    /// Last pool interval this vault settled (id + 1; 0 = never).
    uint256 public lastSettledPlusOne;

    /// Settlement NAV captured for the interval in `settleNavIdPlusOne` (WAD USD; id + 1, so
    /// 0 = nothing captured). AUDIT-2026-07-29 F4: `settle` used to value the vault at the price
    /// of the instant IT ran, anywhere in the 3-day report window, so a third party chose the
    /// valuation instant for a vault it did not own and the owner could not pre-empt it — the
    /// interval is one-shot, so the victim had no second attempt. The valuation instant is now
    /// a separate, one-shot, permissionless act confined to `Calendar.SNAPSHOT_WINDOW`: the
    /// owner removes all discretion by taking it at `pointTime`, which is exactly the mitigation
    /// the `Calendar` docstring records for `lockPrices` and which C-1 had moved out of reach.
    /// Reporting liveness is unchanged — the weight report still has until `reportDeadline`.
    uint256 public settleNavWad;
    uint256 public settleNavIdPlusOne;
    /// Price the snapshot above was taken at, so the in-kind operator payment values the basket
    /// on the SAME basis the NAV was measured on even when settle runs a day later.
    uint256 internal _settleNavPxWad;

    /// Frozen structural liquidation target (WAD) of a held leveraged long (§7b margin control).
    /// Captured once at open and NOT re-derived while held — so a live price move or a
    /// permissionless anchor sample (which flips the regime / jumps at the halving) can never
    /// re-lever the position (audit C1/C4). Zero while flat and for every non-structural leg;
    /// cleared at flip / exit / liquidation so the next open re-derives from the live price.
    uint256 public perpStopWad;
    /// Side of the frozen `perpStopWad` (true = long, false = short) — a long's stop sits below
    /// entry, a short's above, so the sizing denominator and the flip-clear are side-aware.
    bool public perpStopLong;

    // ------------------------------------------------------------------ async intent
    enum IntentKind {
        None,
        FundDir, // EVM→Core spot credit poll (A8: not re-emittable, poll only)
        FundUsdc,
        SpotOrder, // one IOC on the spot pair; measured, capped, accounted once
        ReturnDir, // Core spot→EVM (A2: net-decrease + EVM receipt; A7: never resend after debit)
        ReturnUsdc,
        ToPerp, // spot→perp (A2: completes on spot net-decrease)
        FromPerp, // perp→spot (A2: completes on spot net-increase reaching full amount)
        PerpOrder, // one IOC on the perp
        RecoverSpotDir, // surplus recovery legs — abandonable after timeout (A6)
        RecoverSpotUsdc,
        RecoverPerpPhase1, // perp→spot surplus
        RecoverPerpPhase2 // spot→EVM→owner surplus
    }

    /// Purpose of a FromPerp/ToPerp/Return leg (controls which bucket is credited).
    enum Purpose {
        Generic,
        Margin, // margin allocation / return
        Harvest // settles a harvest claim: min(claim, available), then cleared (A4)
    }

    struct Intent {
        IntentKind kind;
        Purpose purpose;
        uint64 amount; // source units: wei for spot legs, 1e6 for perp legs
        uint64 snapSrcWei; // Core-spot snapshot of the tracked token
        uint64 snapAux; // SpotOrder: other-leg spot snapshot; PerpOrder: |szi| before
        uint256 snapEvm; // EVM balance snapshot for receipt proofs
        uint256 pxWad; // price snapshot for envelope caps
        uint64 orderSz; // submitted order size (lots)
        bool isBuy;
        bool firstCredit; // FundX: fresh-account activation tolerance (A9)
        uint64 claim6; // PerpOrder verify → harvest quota; FromPerp(Harvest) settles it
        uint40 createdAt;
    }

    Intent public intent;

    /// Exit machine: share being exited (WAD; 0 = no exit in progress). Driven by the
    /// LIVE position each crank, not a one-shot flag (SPECIFICATION §9).
    uint256 public exitShareWad;

    bool internal _entered;

    /// Payouts whose token transfer failed (e.g. a USDC-blacklisted recipient) are
    /// deferred instead of reverting the settle/exit — a recipient's transfer failure
    /// must never freeze the vault (H3). recipient → token → amount; retryable via
    /// claimDeferred. Deferred amounts stay accounted (excluded from EVM recovery).
    mapping(address => mapping(address => uint256)) public deferredPayout;
    mapping(address => uint256) public deferredPayoutTotal; // token → total deferred

    // ------------------------------------------------------------------ events (G1)
    event Initialized(address owner, address pool, bytes32 dirDescriptorHash);
    event PolicySelected(address strategy, int256 growth, int256 fall, uint256 scaleWad);
    event Deposited(uint256 dirAmount, uint256 usdcAmount, uint256 valueWad, uint256 entryWad);
    event IntentCreated(IntentKind kind, Purpose purpose, uint64 amount);
    event IntentCompleted(IntentKind kind, Purpose purpose, uint64 amount);
    event IntentResent(IntentKind kind, uint64 newAmount);
    event IntentCleared(IntentKind kind); // no-fill order or zero-settle claim
    event SpotTraded(bool isBuy, uint64 inWei, uint64 outWei, uint64 creditedOutWei);
    event HarvestRecorded(uint64 claim6);
    event HarvestSettled(uint64 settled6, uint64 residualAbandoned6);
    event LossReconciled(uint64 writtenDown6); // silent value movement made visible (G1)
    event MarginReturned(uint64 amount6);
    event Settled(
        uint256 indexed intervalId, uint256 navWad, uint256 profitWad, uint256 feePaidWad
    );
    event FeePaid(address operator, uint256 operatorValueWad, address referrer);
    event SettleNavSnapshotted(uint256 indexed intervalId, uint256 navWad, uint256 pxWad);
    /// The exit paid its penalty to the pool, but the pool-side attribution call reverted and was
    /// swallowed so the exit could not be frozen by it (H3/V3-POOL-1). `onCapture` distinguishes
    /// which half failed: `beginPenalty` (false) or `capturePenalty` (true).
    ///
    /// Custody is unaffected — the tokens are in the pool and a later permissionless `capture()`
    /// accounts them. What IS affected is ROUTING: in a strict Product Pool the penalty was owed
    /// to its matching sleeve (D6/D7) and instead falls through to generic claim inventory, where
    /// it is distributed by weight to whoever is claiming. That is a value movement with no other
    /// on-chain trace, which HAZARDS G1 requires be observable rather than inferred by diffing
    /// storage — and it is the ONLY signal that a pool-side guard silently downgraded the routing.
    event PenaltyRoutingDegraded(bool onCapture);
    event ExitInitiated(uint256 shareWad);
    event ExitCancelled(uint256 shareWad);
    event ExitFinalized(
        uint256 shareWad, uint256 grossWad, uint256 ownerWad, uint256 penaltyWad, bool free
    );
    event SurplusRecovered(IntentKind kind, uint64 amount, address to);
    event EmergencyCleared(IntentKind kind);
    event UnaccountedEvmRecovered(address token, uint256 amount);
    event PayoutDeferred(address indexed to, address token, uint256 amount);
    event DeferredPayoutClaimed(address indexed to, address token, uint256 amount);

    // ------------------------------------------------------------------ errors
    error AlreadyInitialized();
    error OnlyOwner();
    error OnlyFactory();
    error ZeroDeposit();
    error BadPolicy();
    error BadRoute();
    error BadSlippage();
    error IntentPending();
    error ExitPending();
    error NoExitPending();
    error NotFlat(); // strict custody flatness: raw szi == 0 required (A10)
    error WrongSignPerp();
    error FeeNotRepatriated(); // settle requires the EVM basket to cover the operator cut
    error AlreadySettled();
    error NotSettleable();
    error NavNotSnapshotted(); // settle ran past the snapshot window with no captured NAV
    error ReturnNotStuck(); // the source still holds it: the leg is slow, not wedged
    error OutsideSnapshotWindow(); // the valuation instant is confined to the settlement day
    error BadShare();
    error NotRecoveryIntent();
    error TooEarly();
    error NothingToRecover();
    error Reentrancy();
    /// A directional price of 0 is never a valid valuation or cost basis: it would book
    /// principal at zero, or value a whole NAV at zero (audit C-1/H-3).
    error ZeroPrice();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    function dirDescriptor() external view returns (CoreTypes.AssetDescriptor memory) {
        return _dir;
    }

    function usdcDescriptor() external view returns (CoreTypes.AssetDescriptor memory) {
        return _usdc;
    }
}
