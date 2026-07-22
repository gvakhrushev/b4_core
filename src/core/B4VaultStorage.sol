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
    /// Rebalance dead-band: skip trades below 1% of strategy value…
    uint256 internal constant TOLERANCE_BPS = 100;
    /// …or below the venue's $10 minimum order notional.
    uint256 internal constant MIN_ORDER_USD_WAD = 10e18;
    /// Perp IOC price envelope, bps of mark (SPECIFICATION §7).
    uint256 internal constant PERP_ENVELOPE_BPS = 50;
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
    event ExitInitiated(uint256 shareWad);
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
    error DepositWindowClosed();
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
    error BadShare();
    error NotRecoveryIntent();
    error TooEarly();
    error NothingToRecover();
    error Reentrancy();

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
