// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Phi} from "../libraries/Phi.sol";
import {Calendar} from "../libraries/Calendar.sol";
import {SafeTransfer} from "../libraries/SafeTransfer.sol";
import {CoreTypes} from "../venue/CoreTypes.sol";
import {CoreReader} from "../venue/CoreReader.sol";
import {IHalvingOracle} from "../interfaces/IHalvingOracle.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IB4PoolPolicy} from "../interfaces/IB4PoolPolicy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

interface IB4VaultOwner {
    function owner() external view returns (address);
}

interface IB4PoolSleeve {
    function deposit(uint256 dirAmount, uint256 usdcAmount) external;
    function crank() external returns (bool progressed);
    function initiateExit(uint256 shareWad) external;
    function exitShareWad() external view returns (uint256);
    // Owner-only escapes of a pool-OWNED sleeve. A sleeve is initialized with
    // `owner == pool`, so this contract is the only address that can ever satisfy their
    // `onlyOwner` modifier; without these entries in the interface the escapes that
    // INVARIANTS row 20 and HAZARDS B6 promise simply do not exist for a sleeve (audit
    // L-1). Each is relayed with fixed arguments and a recipient this contract cannot
    // choose — see the sleeve-escape section below.
    function cancelExit() external;
    function recoverEvm(address token) external;
    function recoverCoreSpot(bool dirToken) external;
    function recoverPerpSurplus() external;
    function emergencyClearRecovery() external;
    // Read-side of the exit-deferral predicate mirrored by `cancelSleeveExit`.
    function dirEvm() external view returns (uint256);
    function coreDirWei() external view returns (uint64);
}

/// @title B4Pool — shared reward basket: intervals, checkpoint prices, weights, claims.
/// @notice Permissionless creation is not endorsement (REQUIREMENTS §1). One pool admits
///         1–N directional descriptors keyed by full descriptor hash plus the settlement
///         descriptor; separate pools share nothing. Liability discipline per HAZARDS D:
///         liability grows only by measured receipt (D2), the checkpoint-price lock is
///         all-or-nothing (D1), loss socialization is order-independent (D3), expired
///         inventory sweeps once with liability unchanged (D4), and a failed token
///         transfer leaves only that token's claim retryable (D5).
contract B4Pool is IB4PoolPolicy {
    using SafeTransfer for address;

    // ------------------------------------------------------------------ immutable config
    address public immutable factory;
    IHalvingOracle public immutable oracle;
    uint256 public immutable assetCount; // settlement at index 0 + directional 1..N

    /// Bounded whitelist (F2: loops are bounded by it).
    uint256 public constant MAX_DIRECTIONAL = 8;

    CoreTypes.AssetDescriptor[] internal _assets;
    mapping(bytes32 => uint256) public descriptorIndexPlusOne; // directional hash → index+1
    mapping(address => bool) public isVault;

    // ------------------------------------------------------------------ immutable policy domain
    /// @notice Bit mask of the enabled reference products. Zero preserves the original
    ///         legacy shared-basket mode; a non-zero mask is a strict configured pool.
    ///         1=Mini, 2=B4, 4=Pro, 8=Pro Max. The four single bits are isolated
    ///         pools and 15 is the explicit aggregate-pool choice.
    uint8 public policyMask;
    bool private _policiesConfigured;
    mapping(address => uint8) public policyIdForStrategy;
    mapping(uint8 => address) public strategyOf;
    mapping(address => uint8) public policyOfVault;
    mapping(address => uint256) public dirIndexOfVault;
    mapping(address => bool) public isSleeve;
    mapping(uint8 => mapping(uint256 => address)) public sleeveOf;

    /// @notice Per-product, per-direction inventory captured from non-free exits.
    ///         It is deliberately NOT distributable inventory: it is committed to its
    ///         matching sleeve until that sleeve exits in a free distribution window.
    mapping(uint8 => mapping(uint256 => mapping(uint256 => uint256))) public penaltyEscrow;
    /// @notice Physical token amounts committed to `penaltyEscrow`. Kept separate from
    ///         `liability`, so unclaimed checkpoint rewards never see a false shortfall
    ///         merely because another product's capital is currently being traded.
    mapping(address => uint256) public escrowHeld;

    // ------------------------------------------------------------------ intervals
    struct Interval {
        uint64 pointTime;
        uint64 lockedAt; // 0 until checkpoint prices are locked
        bool swept;
        uint256 totalWeight;
        mapping(uint256 => uint256) lockedPxWad; // asset index → WAD price
        mapping(uint256 => uint256) bucket; // asset index → claim base B (fixed)
        mapping(uint256 => uint256) remaining; // asset index → not-yet-claimed inventory
        mapping(address => uint256) weightOf; // vault → reported weight
        mapping(address => mapping(uint256 => bool)) claimed; // vault → asset → done
    }

    uint256 public intervalCount;
    mapping(uint256 => Interval) internal _intervals;
    uint256 public lastPointTime;

    /// Structural-leverage anchors per directional asset (SPECIFICATION §7b). `floor` is the
    /// previous confirmed structural low (the delta anchor); `cap` is the current window's
    /// running low (the stop ceiling); `windowTag = epoch·2 + kind + 1` identifies the window
    /// being sampled (kind 0 = post-halving window, 1 = 62-window), 0 = never sampled.
    struct Anchor {
        uint256 floor;
        uint256 cap;
        uint256 windowTag;
        // Mirror of (floor, cap) for the SHORT side (SPECIFICATION §7b): confirmed HIGHS.
        // `prevPeak` = previous cycle's confirmed peak (delta anchor); `peakC` = this cycle's
        // peak = running MAX over the peak-window `[P−W, P]`; `peakTag = epoch + 1` (0 = never).
        uint256 prevPeak;
        uint256 peakC;
        uint256 peakTag;
        // Dispersion remedy (AUDIT-2026-07-25 M-3's second half, prescribed twice and never
        // built — see REVIEW-2026-07-25 item 11). `peakTop` is the highest CLOSE seen so far
        // and `peakTopDay` the close-day that set it; `peakC` above is the highest level
        // reached at TWO DISTINCT close-days, and only `peakC` is ever served or promoted. A
        // lone print — a wick, or one manipulated close — raises `peakTop` and stops there.
        uint256 peakTop;
        uint256 peakTopDay;
        // Sampling density of the window currently feeding each side (V8-M-1/V8-M-2): the
        // anchor is CONFIRMED only at ≥ MIN_ANCHOR_SAMPLES daily observations spanning
        // ≥ W/2 of its window. Reset on every window reseed; each packs into a single slot.
        Density lowDensity;
        Density peakDensity;
    }

    /// Sampling density of one anchor side's current window. `first`/`last` are the
    /// timestamps of the first/most recent sample of the window.
    struct Density {
        uint32 count;
        uint112 first;
        uint112 last;
    }

    mapping(uint256 => Anchor) internal _anchor; // directional asset index → anchors

    /// Density gate (V8-M-1/V8-M-2): a window confirms its anchor only at ≥ 10 samples
    /// separated by at least one day and spanning ≥ W/2 (10 days). An unconfirmed
    /// anchor is never promoted and never fed to the engine.
    uint256 internal constant MIN_ANCHOR_SAMPLES = 10;
    uint256 internal constant MIN_ANCHOR_SAMPLE_GAP = 1 days;

    /// Daily-CLOSE acceptance window, measured from the sampling window's own opening: an
    /// observation may set the peak VALUE only when `(t − (P − W)) % 1 days` is inside it.
    /// Anchoring the day grid to the window rather than to the halving puts the first close at
    /// the window's opening instant and yields exactly `W` closes in a `W`-wide window.
    ///
    /// SPECIFICATION §152 defines the peak anchor as the window's **max close**, and a close is
    /// a fixed instant of the day. The implementation had no such instant: it took the max over
    /// all *calls*, so the anchor was whatever price a caller chose to sample at (M-3), and
    /// after M-3's first remedy tied the value to the density slot it became whatever the
    /// caller who WON that slot chose — letting a squatter take every daily slot at a low and
    /// suppress the true high while the density gate still confirmed (AUDIT-2026-07-29 F2).
    ///
    /// Pinning the instant is what separates the two failures, which no rule based on the
    /// caller's identity or the gap since the last sample can do — those are the only two
    /// dimensions a squat and an honest late observation differ in, and addresses are free.
    /// A fixed, public instant is a third dimension:
    ///   * suppression fails — the value is not owned by whoever calls first; every
    ///     observation inside the window competes, so an honest caller always lands the
    ///     genuine close;
    ///   * a wick fails — an injected print must coincide with the close window to bind at
    ///     all, instead of being harvestable at any instant of the day.
    ///
    /// One hour rather than one block, for the same reason `Calendar.SNAPSHOT_WINDOW` is 24h:
    /// over a window recurring once a day for 20 days, a failed cron or an RPC outage is the
    /// dominant real risk, and a one-block target would be missed routinely. The honest cost of
    /// a fixed instant is that it is PREDICTABLE and therefore easier to target than a random
    /// one; what it buys is that the attacker must now hold a price at a published time rather
    /// than pick their moment, and the density gate still requires ≥10 such days spanning ≥W/2.
    uint256 internal constant ANCHOR_CLOSE_WINDOW = 1 hours;

    /// Inventory collecting for the next interval to be materialized (asset index →
    /// amount, EVM units).
    mapping(uint256 => uint256) public accruing;
    /// Total owed per EVM token across all interval buckets + accruing (EVM units).
    mapping(address => uint256) public liability;

    bool private _entered;

    // ------------------------------------------------------------------ events (G1)
    event IntervalMaterialized(uint256 indexed id, uint256 pointTime);
    event PricesLocked(uint256 indexed id, uint256 lockedAt);
    event WeightReported(uint256 indexed id, address indexed vault, uint256 weight);
    event WeightForfeited(uint256 indexed id, address indexed vault, uint256 weight);
    event Claimed(
        uint256 indexed id, address indexed vault, uint256 assetIndex, uint256 nominal, uint256 paid
    );
    event ClaimDeferred(uint256 indexed id, address indexed vault, uint256 assetIndex);
    event Swept(uint256 indexed id);
    event Captured(uint256 assetIndex, uint256 amount);
    event PenaltyCaptured(
        uint8 indexed policy, uint256 indexed dirAssetIndex, uint256 assetIndex, uint256 amount
    );
    event VaultRegistered(address vault);
    event SleeveRegistered(uint8 indexed policy, uint256 indexed dirAssetIndex, address sleeve);
    event PolicyConfigured(uint8 policyMask);
    event VaultPolicyChanged(address indexed vault, uint8 indexed policy);
    event EscrowFolded(
        uint8 indexed policy,
        uint256 indexed dirAssetIndex,
        address sleeve,
        uint256 dirAmount,
        uint256 usdcAmount
    );
    event SleeveExitInitiated(uint8 indexed policy, uint256 indexed dirAssetIndex, address sleeve);
    event SleeveExitCancelled(uint8 indexed policy, uint256 indexed dirAssetIndex, address sleeve);
    event AnchorSampled(uint256 indexed assetIndex, uint256 floor, uint256 cap, uint256 tag);
    event PeakSampled(uint256 indexed assetIndex, uint256 prevPeak, uint256 peakC, uint256 tag);

    error OnlyFactory();
    error TooManyAssets();
    error DuplicateAsset();
    error NotMaterialized();
    error OutsideSnapshotWindow();
    error AlreadyLocked();
    error ZeroPrice();
    error NotLocked();
    error ReportWindowClosed();
    error ReportWindowOpen();
    error AlreadyReported();
    error ZeroWeight();
    error NotAVault();
    error NothingToClaim();
    error NotExpired();
    error AlreadySwept();
    error BadAsset();
    error NotInWindow();
    error Reentrancy();
    error PolicyAlreadyConfigured();
    error BadPolicyConfig();
    error PolicyNotAllowed();
    error BadPolicyTransition();
    error NotASleeve();
    error NotFreeExit();
    /// `cancelSleeveExit` is an ESCAPE, not a control: it is refused unless the sleeve's
    /// exit is provably unable to finalize (see that function).
    error NotStuck();

    modifier nonReentrant() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    /// @param descriptors settlement descriptor at [0], then 1..N directional. The factory
    ///        validates each against the venue before deployment (F3: binding cannot
    ///        precede validation).
    /// @param factory_ the address that holds the pool's registration authority. Supplied
    ///        explicitly because creation now happens inside `B4PoolDeployer`, which exists
    ///        so this contract's creation code is not embedded in both factory paths (see
    ///        that file). The deployer passes its own caller, so the value is exactly what
    ///        `msg.sender` was under the previous inline `new B4Pool(...)`, and the trust
    ///        model is unchanged: a self-declared factory grants nothing, because authority
    ///        flows from a factory's own `isPool` registry, never from this field.
    constructor(
        address oracle_,
        CoreTypes.AssetDescriptor[] memory descriptors,
        address factory_
    ) {
        factory = factory_;
        oracle = IHalvingOracle(oracle_);
        uint256 n = descriptors.length;
        if (n < 2 || n - 1 > MAX_DIRECTIONAL) revert TooManyAssets();
        for (uint256 i = 0; i < n; i++) {
            _assets.push(descriptors[i]);
            if (i == 0) continue;
            bytes32 h = CoreTypes.descriptorHash(descriptors[i]);
            if (descriptorIndexPlusOne[h] != 0) revert DuplicateAsset();
            // One token never has two descriptors in a pool (SPEC §2).
            for (uint256 j = 0; j < i; j++) {
                if (
                    _assets[j].evmToken == descriptors[i].evmToken
                        || _assets[j].coreToken == descriptors[i].coreToken
                ) revert DuplicateAsset();
            }
            descriptorIndexPlusOne[h] = i + 1;
        }
        assetCount = n;
        // Points that predate the pool are never materialized.
        lastPointTime = block.timestamp;
    }

    function registerVault(address vault) external {
        if (msg.sender != factory) revert OnlyFactory();
        _registerVault(vault, 0, 0);
    }

    /// @notice Factory-only binding of a user vault to its initial immutable product
    ///         and directional asset. The legacy overload above remains for pre-domain
    ///         pools and adversarial test harnesses.
    function registerVault(address vault, uint8 policy, uint256 dirAssetIndex) external {
        if (msg.sender != factory) revert OnlyFactory();
        _registerVault(vault, policy, dirAssetIndex);
    }

    function _registerVault(address vault, uint8 policy, uint256 dirAssetIndex) internal {
        if (policyMask != 0) {
            if (
                policy == 0 || (policyMask & (uint8(1) << (policy - 1))) == 0 || dirAssetIndex == 0
                    || dirAssetIndex >= assetCount
            ) revert BadPolicyConfig();
        }
        isVault[vault] = true;
        policyOfVault[vault] = policy;
        dirIndexOfVault[vault] = dirAssetIndex;
        emit VaultRegistered(vault);
    }

    /// @notice One-time configuration, callable only by the immutable factory during
    ///         `createConfiguredPool`. The factory has no later arbitrary-call surface,
    ///         so this is immutable in practice and by construction.
    function configurePolicies(address[4] calldata strategies, uint8 mask) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (_policiesConfigured || mask == 0 || (mask & 0x0f) != mask) {
            revert PolicyAlreadyConfigured();
        }
        _policiesConfigured = true;
        policyMask = mask;
        for (uint8 policy = 1; policy <= 4; policy++) {
            if ((mask & (uint8(1) << (policy - 1))) == 0) continue;
            address strategy = strategies[policy - 1];
            if (strategy == address(0) || policyIdForStrategy[strategy] != 0) {
                revert BadPolicyConfig();
            }
            (int256 growth, int256 fall) = IStrategy(strategy).targets();
            if (!_isReferencePair(policy, growth, fall)) revert BadPolicyConfig();
            policyIdForStrategy[strategy] = policy;
            strategyOf[policy] = strategy;
        }
        emit PolicyConfigured(mask);
    }

    /// @notice Whether a vault may bind `strategy` at this moment. In a configured
    ///         aggregate pool policy ids are monotonically non-decreasing, so upgrading
    ///         1→4 is an in-place, penalty-free change while a downgrade must exit and
    ///         re-enter. A one-product pool naturally admits only that product.
    function policyAllowedForVault(
        address vault,
        address strategy,
        int256 growth,
        int256 fall,
        uint256 scaleWad
    ) external view returns (bool) {
        if (policyMask == 0) return true;
        uint8 policy = policyIdForStrategy[strategy];
        if (policy == 0 || (policyMask & (uint8(1) << (policy - 1))) == 0) return false;
        if (scaleWad != Phi.WAD || !_isReferencePair(policy, growth, fall)) return false;
        uint8 current = policyOfVault[vault];
        return current == 0 || policy >= current;
    }

    /// @notice Commit a successful in-vault product selection. This function can only
    ///         be called by the registered vault itself, through its fixed ops module.
    function setVaultPolicy(uint8 policy) external {
        if (!isVault[msg.sender]) revert NotAVault();
        if (policyMask == 0) return;
        if (policy == 0 || (policyMask & (uint8(1) << (policy - 1))) == 0) {
            revert PolicyNotAllowed();
        }
        if (policy < policyOfVault[msg.sender]) revert BadPolicyTransition();
        policyOfVault[msg.sender] = policy;
        emit VaultPolicyChanged(msg.sender, policy);
    }

    /// @notice Bind a factory-created pool-owned sleeve. Sleeves are deliberately not
    ///         reward-reporting vaults: their realised value returns to the basket before
    ///         participants' weights are used.
    function registerSleeve(address sleeve, uint8 policy, uint256 dirAssetIndex) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (
            policyMask == 0 || policy == 0 || (policyMask & (uint8(1) << (policy - 1))) == 0
                || dirAssetIndex == 0 || dirAssetIndex >= assetCount
                || sleeveOf[policy][dirAssetIndex] != address(0)
        ) revert BadPolicyConfig();
        isSleeve[sleeve] = true;
        sleeveOf[policy][dirAssetIndex] = sleeve;
        emit SleeveRegistered(policy, dirAssetIndex, sleeve);
    }

    function asset(uint256 i) external view returns (CoreTypes.AssetDescriptor memory) {
        return _assets[i];
    }

    // ------------------------------------------------------------------ calendar cranks

    /// @notice Materialize the next passed settlement point (one per call; permissionless).
    ///         A point of a superseded epoch that was never reached is skipped by
    ///         construction (zones follow the latest fact; `lastPointTime` is monotonic).
    ///         Worst case of a late crank is an unreportable interval — delayed liveness,
    ///         self-healing via sweep (H3).
    function advance() external nonReentrant returns (bool materialized) {
        uint256 next = Calendar.nextSettlementPoint(oracle.halvingTs(), lastPointTime);
        if (next == 0 || block.timestamp < next) return false;
        uint256 id = intervalCount++;
        Interval storage it = _intervals[id];
        it.pointTime = uint64(next);
        // The inventory accrued since the previous point becomes this interval's basket.
        for (uint256 i = 0; i < assetCount; i++) {
            uint256 amt = accruing[i];
            if (amt != 0) {
                it.bucket[i] = amt;
                it.remaining[i] = amt;
                accruing[i] = 0;
            }
        }
        lastPointTime = next;
        emit IntervalMaterialized(id, next);
        return true;
    }

    /// @notice Lock checkpoint prices — permissionless, all-or-nothing (D1): commits only
    ///         after EVERY directional asset prices non-zero; otherwise reverts so a later
    ///         call within the snapshot window retries. Missing the window makes the
    ///         interval unreportable (liveness, not custody).
    function lockPrices(uint256 id) external {
        Interval storage it = _interval(id);
        if (it.lockedAt != 0) revert AlreadyLocked();
        if (
            block.timestamp < it.pointTime
                || block.timestamp > it.pointTime + Calendar.SNAPSHOT_WINDOW
        ) revert OutsideSnapshotWindow();
        // Since AUDIT-2026-07-25 C-1 the recorded price feeds NO valuation — settlement
        // values the vault at the instant it runs, so the entry ledger and NAV share one
        // basis. What survives here is the marker that opens the interval for reporting
        // (`lockedAt`), plus the prices as an informational record. Refusing a zero read
        // therefore no longer protects anything: it would only let a dead feed on ONE
        // co-listed asset block reporting and claiming for the WHOLE pool, which is pure
        // liveness cost for no safety gain. Record what resolves, skip what does not.
        it.lockedPxWad[0] = Phi.WAD; // fixed USDC = 1 USD (decision C3)
        for (uint256 i = 1; i < assetCount; i++) {
            it.lockedPxWad[i] = CoreReader.spotPxWad(_assets[i]);
        }
        it.lockedAt = uint64(block.timestamp);
        emit PricesLocked(id, block.timestamp);
    }

    // ------------------------------------------------------------- structural anchors

    /// @notice Permissionless: record the directional spot price into the structural-leverage
    ///         ratchet for asset `i`, if we are inside one of the two sampling windows —
    ///         the post-halving window `[0, W)` or the 62-window `[T, T+W)`. Moves funds for
    ///         no one; reads only the venue precompile (`spotPxWad`), so a caller cannot forge
    ///         the price, only choose when to sample. Sampling MORE lowers the recorded low
    ///         and therefore lowers leverage (SPECIFICATION §7b) — a keeper samples each
    ///         window; the pool benefits from an accurate low.
    ///
    ///         Ratchet: within a window the `cap` tracks the running minimum DOWN. When a new
    ///         62-window opens the `cap` is reseeded to this cycle's bottom (the `floor` is
    ///         unchanged); when a new post-halving window opens the halving **flip** fires —
    ///         the previous `cap` becomes the new `floor`, and `cap` is reseeded to the
    ///         post-halving low. So the pair advances up only at the halving flip.
    ///
    ///         Density gate (V8-M-1/V8-M-2): a window CONFIRMS its anchor only at ≥
    ///         MIN_ANCHOR_SAMPLES daily observations spanning ≥ W/2 (see `_confirmed`).
    ///         An unconfirmed anchor is never promoted into `floor`/`prevPeak` and is
    ///         withheld by the `anchors()`/`peaks()` getters (read as 0 = "absent"), so a
    ///         sparsely-sampled window can never size a leveraged position — the engine
    ///         degrades fail-safe instead.
    ///
    ///         PEAK value rule (SPEC §152, `ANCHOR_CLOSE_WINDOW`): the density gate above
    ///         governs CONFIRMATION only. The peak VALUE is the max over daily CLOSES,
    ///         corroborated by two distinct close-days — a separate mechanism, deliberately not
    ///         sharing the counter's gate. Conflating them is what let a caller who won the
    ///         daily counting slot own the day's value and suppress the true high (F2); gating
    ///         the value on nothing at all is what let any wick set it (M-3). A single print,
    ///         wherever it lands, is at most a candidate.
    function sampleAnchor(uint256 i) external {
        if (i == 0 || i >= assetCount) revert BadAsset();
        uint256 t = oracle.timeSinceHalving();
        Anchor storage a = _anchor[i];
        uint112 now112 = uint112(block.timestamp);

        // Peak window [P−W, P): the confirmed-HIGH ratchet — the mirror of the low ratchet
        // below. `peakC` tracks the running MAX up; a new epoch's first peak sample flips the
        // prior `peakC` into `prevPeak` (the short's delta anchor). One peak window per epoch.
        if (t >= Calendar.P - Calendar.W && t < Calendar.P) {
            uint256 pxp = CoreReader.spotPxWad(_assets[i]);
            if (pxp == 0) revert ZeroPrice();
            uint256 ptag = oracle.epoch() + 1; // 0 = never sampled
            uint256 sinceOpen = t - (Calendar.P - Calendar.W);
            bool atClose = sinceOpen % MIN_ANCHOR_SAMPLE_GAP < ANCHOR_CLOSE_WINDOW;
            uint256 closeDay = sinceOpen / MIN_ANCHOR_SAMPLE_GAP;
            if (ptag != a.peakTag) {
                // A new peak window opens. Lazy promotion of the outgoing window — the
                // fallback for the eager halving-flip path below. ONE coherent rule on
                // both paths: only a density-confirmed peak is ever promoted, and since
                // `peakC` cannot change between the flip and this opening, the two paths
                // are idempotent (they can never contradict or double-promote).
                if (a.peakTag != 0 && _confirmed(a.peakDensity)) a.prevPeak = a.peakC;
                // Reseed carries NO served value. Seeding `peakC` from whatever the first
                // caller into the window happened to read gave that caller the anchor for the
                // whole 20 days with no cadence condition at all — and since the value only
                // ratchets up, a wick at that instant survived the entire window. A served
                // value now requires two distinct closes, so the opening observation can only
                // ever be a candidate.
                a.peakC = 0;
                a.peakTop = atClose ? pxp : 0;
                a.peakTopDay = closeDay;
                a.peakTag = ptag;
                a.peakDensity = Density(1, now112, now112);
            } else {
                // Density counting stays daily and stays SEPARATE from the value: it gates
                // confirmation (was this window actually observed?), never what the anchor is.
                // Conflating the two is what produced F2 — the caller who won the day's
                // counting slot also owned the day's value, so taking every slot at a low
                // suppressed the true high while the gate still confirmed.
                _recordDistinctSample(a.peakDensity, now112);
            }
            // The value: the MAX over daily CLOSES, per SPECIFICATION §152, corroborated by two
            // distinct closes. Three properties, each closing a different failure:
            //
            //   * independent of who won the density slot ⇒ suppression is impossible. A
            //     squatter taking every slot cannot stop an honest observation from raising the
            //     level, which is what F2 exploited.
            //   * confined to the close window ⇒ an off-close print, the ordinary exchange wick,
            //     cannot bind at all.
            //   * corroborated across two distinct close-days ⇒ a print that DOES land at a
            //     close still cannot bind alone. This is M-3's dispersion remedy; the close
            //     window narrows when a wick must occur, but only corroboration makes a single
            //     one worthless.
            //
            // The cost, stated rather than hidden: the served level is the second-highest close,
            // so a top that prints on exactly one close is understated until a second close
            // reaches it. Understating `peakC` pushes the short's stop further out and LOWERS
            // leverage — the conservative direction — and the error is bounded by the gap
            // between the two highest closes, where an admitted wick would be unbounded.
            if (atClose) {
                if (pxp > a.peakTop) {
                    // A new candidate. The level it displaces is now attested by its own day, so
                    // if that day differs it becomes the corroborated value.
                    if (closeDay != a.peakTopDay && a.peakTop > a.peakC) a.peakC = a.peakTop;
                    a.peakTop = pxp;
                    a.peakTopDay = closeDay;
                } else if (closeDay != a.peakTopDay && pxp > a.peakC) {
                    // A different close-day reaches this level: corroborated.
                    a.peakC = pxp;
                }
            }
            emit PeakSampled(i, a.prevPeak, a.peakC, ptag);
            return;
        }

        uint256 kind;
        if (t < Calendar.W) {
            kind = 0; // post-halving window
        } else if (t >= Calendar.T && t < Calendar.T + Calendar.W) {
            kind = 1; // 62-window (cycle bottom)
        } else {
            revert NotInWindow();
        }
        uint256 px = CoreReader.spotPxWad(_assets[i]);
        if (px == 0) revert ZeroPrice();

        // Tag parity encodes the window kind: kind 0 (post-halving) ⇒ odd, kind 1
        // (62-window bottom) ⇒ even. The halving flip may ONLY promote a cap that a
        // 62-window confirmed — an even outgoing tag (F1) AND a density-confirmed window
        // (V8-M-1): if the previous cycle's 62-window went unsampled the cap still holds a
        // post-halving low (odd tag), and if it was sampled too sparsely its low is an
        // upper bound, not the cycle bottom. Neither may become the floor. Skipping the
        // promotion leaves floor at the prior confirmed low — the conservative direction
        // (a lower floor ⇒ lower leverage), matching the documented flip-skip behaviour
        // rather than poisoning the floor high.
        uint256 tag = oracle.epoch() * 2 + kind + 1; // +1 so 0 means "never sampled"
        if (tag != a.windowTag) {
            // A new window opens.
            if (kind == 0) {
                if (a.windowTag != 0 && a.windowTag % 2 == 0 && _confirmed(a.lowDensity)) {
                    a.floor = a.cap; // halving flip: a confirmed 62-low becomes the floor
                }
                // V8-L-2: promote the peak EAGERLY at the halving flip, mirroring the low
                // side — the peak window of the cycle that just ended was sampled this
                // epoch (`peakTag == epoch`) and density-confirmed. Pre-fix `prevPeak`
                // promoted only inside a peak-window SAMPLE, so one skipped window
                // stranded it at 0 for a whole cycle. The lazy path above stays as the
                // fallback; both are confirmation-gated and idempotent.
                if (a.peakTag != 0 && a.peakTag == oracle.epoch() && _confirmed(a.peakDensity)) {
                    a.prevPeak = a.peakC;
                }
            }
            a.cap = px; // reseed the ceiling to the first observation of this window
            a.windowTag = tag;
            a.lowDensity = Density(1, now112, now112);
        } else {
            // NOT mirrored from the peak side: the two anchors fail in OPPOSITE directions.
            // A too-high `peakC` shrinks the short's `(C − Pp)` and RAISES leverage, so the
            // peak value is tied to the daily cadence (M-3). A too-low `cap` moves the long's
            // stop FURTHER from price and LOWERS leverage — the conservative direction — so
            // the low ratchets on EVERY observation, as the sampling doc requires ("sampling
            // MORE lowers the recorded low and therefore lowers leverage; the pool benefits
            // from an accurate low"). Gating it daily would let a real intra-day crash go
            // unrecorded and keep structural longs levered against a low the market already
            // broke. Only the DENSITY count stays daily — that gates confirmation, not value.
            if (px < a.cap) a.cap = px; // ratchet the ceiling down within the window
            _recordDistinctSample(a.lowDensity, now112);
        }
        emit AnchorSampled(i, a.floor, a.cap, tag);
    }

    /// @notice The `(floor, cap)` anchors for directional asset `i`, WAD. `(0, 0)` before any
    ///         window is sampled — a leveraged product then uses its flat base leverage.
    ///         Density gate: an under-sampled `cap` is WITHHELD (read as 0 = "no anchor") so
    ///         the engine degrades fail-safe (flat-φ) instead of sizing a leveraged long
    ///         against a sparse low (V8-M-1). `floor` is returned raw: it is only ever
    ///         promoted from a density-confirmed window, so a non-zero floor is confirmed
    ///         by construction.
    function anchors(uint256 i) external view returns (uint256 floor, uint256 cap) {
        Anchor storage a = _anchor[i];
        return (a.floor, _confirmed(a.lowDensity) ? a.cap : 0);
    }

    /// @notice The confirmed-HIGH anchors `(prevPeak, peakC, peakTag)` for directional asset `i`,
    ///         WAD — the SHORT-side mirror of `anchors`. `(0, 0, 0)` before any peak window is
    ///         sampled. `peakTag = epoch + 1` identifies the epoch whose window set `peakC`; a
    ///         consumer compares it to `oracle.epoch() + 1` to reject a stale prior-cycle peak (a
    ///         short must never anchor to an unconfirmed/stale high — see B4VaultEngine).
    ///         Density gate: an under-sampled `peakC` is WITHHELD (read as 0 = "this cycle's
    ///         peak unknown") so a short never anchors to a sparse window (V8-M-1); the
    ///         freshness tag is returned raw so the consumer can still distinguish "withheld"
    ///         from "stale". `prevPeak` is returned raw: it is only ever promoted from a
    ///         density-confirmed peak.
    ///         `peakC` itself is the CORROBORATED level — the highest reached at two distinct
    ///         daily closes — so a single wick is never served here even in a dense window
    ///         (M-3's dispersion remedy); the uncorroborated candidate `peakTop` is internal
    ///         and deliberately not exposed.
    function peaks(uint256 i)
        external
        view
        returns (uint256 prevPeak, uint256 peakC, uint256 peakTag)
    {
        Anchor storage a = _anchor[i];
        return (a.prevPeak, _confirmed(a.peakDensity) ? a.peakC : 0, a.peakTag);
    }

    /// @notice Whether each side's current-window anchor is density-confirmed
    ///         (≥ MIN_ANCHOR_SAMPLES daily observations spanning ≥ W/2). The getters withhold an
    ///         unconfirmed cap/peakC; `floor`/`prevPeak` are only ever promoted from
    ///         confirmed windows.
    function anchorConfirmed(uint256 i)
        external
        view
        returns (bool lowConfirmed, bool peakConfirmed)
    {
        Anchor storage a = _anchor[i];
        return (_confirmed(a.lowDensity), _confirmed(a.peakDensity));
    }

    /// @dev The density gate (V8-M-1/V8-M-2): a window's anchor confirms only at ≥
    ///      MIN_ANCHOR_SAMPLES daily observations spanning ≥ W/2. Monotonic
    ///      within a window (the count and span only grow), so once confirmed a window
    ///      stays confirmed until the next reseed.
    function _confirmed(Density storage d) internal view returns (bool) {
        return d.count >= MIN_ANCHOR_SAMPLES && d.last - d.first >= Calendar.W / 2;
    }

    /// @dev Count daily observations, not calls. Same-block or tightly-compressed samples
    ///      carry no meaningful window coverage and must not inflate the density gate.
    /// @return counted true when this observation opened a NEW day for the window.
    function _recordDistinctSample(Density storage d, uint112 now112)
        internal
        returns (bool counted)
    {
        if (uint256(now112) < uint256(d.last) + MIN_ANCHOR_SAMPLE_GAP) return false;
        d.count += 1;
        d.last = now112;
        return true;
    }

    function _isReferencePair(uint8 policy, int256 growth, int256 fall)
        internal
        pure
        returns (bool)
    {
        if (policy == 1) return growth == int256(Phi.WAD) && fall == int256(Phi.WAD);
        if (policy == 2) return growth == int256(Phi.WAD) && fall == 0;
        if (policy == 3) return growth == int256(Phi.WAD) && fall == -int256(Phi.WAD);
        if (policy == 4) return growth == int256(Phi.PHI) && fall == -int256(Phi.PHI);
        return false;
    }

    // ------------------------------------------------------------------ weights

    function reportDeadline(uint256 id) public view returns (uint256) {
        return _intervals[id].pointTime + Calendar.SNAPSHOT_WINDOW + Calendar.REPORT_WINDOW;
    }

    /// @notice One weight report per vault per interval; caller is the vault itself.
    function reportWeight(uint256 id, uint256 weight) external {
        if (!isVault[msg.sender]) revert NotAVault();
        if (weight == 0) revert ZeroWeight();
        Interval storage it = _interval(id);
        if (it.lockedAt == 0) revert NotLocked();
        if (block.timestamp > reportDeadline(id)) revert ReportWindowClosed();
        if (it.weightOf[msg.sender] != 0) revert AlreadyReported();
        it.weightOf[msg.sender] = weight;
        it.totalWeight += weight;
        emit WeightReported(id, msg.sender, weight);
    }

    /// @notice A vault that exits scales the weight it reported for `id` by the share it
    ///         KEPT, so a reported claim always tracks the capital still standing behind it.
    /// @dev AUDIT-2026-07-25 C-1 half B, generalised by AUDIT-2026-07-29 F1. The basket is
    ///      funded by leavers for the benefit of stayers, so a claim must never outlive the
    ///      capital that earned it. The vault side already scales its standing base by `keep`
    ///      on EVERY exit (`rewardBaseWad = (R + C·x)·keep`, SPEC §9); this is the pool side of
    ///      the same event, and the two are now the same rule rather than two different ones.
    ///
    ///      Previously the pool side fired only at the exact boundary `keep == 0`, which left
    ///      two defects. The outcome depended on whether the owner called `settle` before or
    ///      after exiting (C-1 half B, the original motivation). And because the test was an
    ///      exact equality on a caller-chosen number, `initiateExit(WAD − 1)` paid out every
    ///      unit of the position but flooring dust while keeping 100% of the reported weight
    ///      (F1) — one wei of retained share bought the whole claim.
    ///
    ///      Scaling proportionally removes the boundary rather than moving it: there is no
    ///      threshold to sit just above, one wei of retained share retains one wei of weight,
    ///      and the outcome is continuous in the exit share. Repeated exits compound
    ///      multiplicatively because each call re-reads the live weight, so splitting an exit
    ///      into steps cannot dodge it either. A dust threshold would only relocate the same
    ///      defect; a measure taken from the post-exit BASE would be worse still, because
    ///      `(R + C·x)·keep` is re-inflated by the exiting share's own unsettled profit, which
    ///      the owner controls the timing of.
    ///
    ///      Three properties this MUST preserve, all load-bearing:
    ///      1. `claimFor` computes `nominal = bucket · w / totalWeight` AT CLAIM TIME, so
    ///         shrinking `totalWeight` once claims are open would raise every later claimant's
    ///         share and could pay out more than the bucket (D2/D3). Claims are gated until
    ///         AFTER `reportDeadline`, so scaling is confined to the same window in which
    ///         `reportWeight` itself is allowed — while claims are still closed, weights are
    ///         not yet final and order-independence is untouched.
    ///      2. It is reached from `_finalizeExit`, which sits on the permissionless crank path.
    ///         A revert there would freeze the exit, and there is no admin to unstick it — so
    ///         every non-applicable case is a silent no-op, never a revert (H3). The added
    ///         arithmetic cannot revert: `keepWad` is clamped at `WAD`, so `kept ≤ w` always
    ///         and the subtraction can never underflow.
    ///      3. `keep == 0` still zeroes the reported weight exactly, so the full-exit rule the
    ///         original half-B fix established is unchanged — it is now the endpoint of a ramp
    ///         instead of a special case.
    function scaleWeight(uint256 id, uint256 keepWad) external {
        if (!isVault[msg.sender]) return;
        if (id >= intervalCount) return;
        if (block.timestamp > reportDeadline(id)) return; // weights final, claims open
        Interval storage it = _intervals[id];
        uint256 w = it.weightOf[msg.sender];
        if (w == 0) return;
        uint256 kept = keepWad >= Phi.WAD ? w : Phi.wmul(w, keepWad);
        uint256 dropped = w - kept;
        if (dropped == 0) return; // nothing left, or flooring dust — silent no-op
        it.weightOf[msg.sender] = kept;
        it.totalWeight -= dropped;
        emit WeightForfeited(id, msg.sender, dropped);
    }

    // ------------------------------------------------------------------ distribution

    /// @notice Permissionless claim for a vault; pays the vault's fixed owner (F2). Claims
    ///         open after the report window closes (weights final) and end at expiry.
    ///         nominal = B·w/W; on shortfall actual = nominal·balance/liability, both
    ///         reduced per claim — order-independent (D3). A failed token transfer leaves
    ///         that token retryable without reverting the others (D5).
    function claimFor(uint256 id, address vault) external nonReentrant {
        Interval storage it = _interval(id);
        if (it.lockedAt == 0) revert NotLocked();
        if (block.timestamp <= reportDeadline(id)) revert ReportWindowOpen();
        if (id + 1 < intervalCount) revert NothingToClaim();
        if (it.swept) revert NothingToClaim();
        uint256 w = it.weightOf[vault];
        if (w == 0) revert NothingToClaim();
        address recipient = IB4VaultOwner(vault).owner();
        uint256 wTotal = it.totalWeight;
        for (uint256 i = 0; i < assetCount; i++) {
            if (it.claimed[vault][i]) continue;
            uint256 nominal = Phi.mulDiv(it.bucket[i], w, wTotal);
            if (nominal > it.remaining[i]) nominal = it.remaining[i]; // flooring safety
            if (nominal == 0) {
                it.claimed[vault][i] = true;
                continue;
            }
            address token = _assets[i].evmToken;
            // Read the balance through a revert-free, return-bomb-capped helper: a
            // malicious basket token whose balanceOf reverts must NOT brick the claim of
            // the settlement token and the healthy tokens for this or any co-resident
            // vault — defer only its own claim (D5 / invariant 18). It stays fully
            // retryable: claimed/remaining/liability are untouched on the failing token.
            (bool ok, uint256 bal) = _safeBalanceOf(token);
            if (!ok) {
                emit ClaimDeferred(id, vault, i);
                continue;
            }
            uint256 liab = liability[token];
            // Escrow belongs to a live product sleeve, not to this checkpoint. Exclude
            // it from the shortfall calculation or an otherwise solvent interval would
            // pay only `poolBalance / (claims + sleeveEscrow)` of every claim.
            uint256 available = bal > escrowHeld[token] ? bal - escrowHeld[token] : 0;
            uint256 pay = available >= liab ? nominal : Phi.mulDiv(nominal, available, liab);
            if (token.tryTransfer(recipient, pay)) {
                it.claimed[vault][i] = true;
                it.remaining[i] -= nominal;
                liability[token] -= nominal;
                emit Claimed(id, vault, i, nominal, pay);
            } else {
                emit ClaimDeferred(id, vault, i);
            }
        }
    }

    /// @notice An interval expires when the next one is materialized; its unclaimed
    ///         inventory sweeps once into the accruing basket, liability unchanged (D4).
    /// @dev nonReentrant: shares claimFor's guard so a malicious pool token cannot reenter
    ///      from claimFor's payout to mutate remaining/accruing mid-distribution (F4).
    function sweep(uint256 id) external nonReentrant {
        Interval storage it = _interval(id);
        if (id + 1 >= intervalCount) revert NotExpired();
        if (it.swept) revert AlreadySwept();
        it.swept = true;
        for (uint256 i = 0; i < assetCount; i++) {
            uint256 rem = it.remaining[i];
            if (rem != 0) {
                it.remaining[i] = 0;
                accruing[i] += rem;
            }
        }
        emit Swept(id);
    }

    /// @notice Capture any uncommitted balance into the accruing interval — measured
    ///         receipt only (D2); a donation becomes inventory, never vault profit. Strict
    ///         configured pools reserve this generic path for donations and sleeve returns;
    ///         ordinary exit penalties use `capturePenalty` below.
    /// @dev nonReentrant: prevents a malicious pool token from reentering (from claimFor's
    ///      payout) to bump liability/accruing against a stale mid-claim balance (F4).
    function capture() external nonReentrant {
        _captureToAccruing();
    }

    /// @dev Namespaced base for the `beginPenalty`/`capturePenalty` transient snapshot.
    ///      Raw slots `1..assetCount` were reachable by any other transient user of THIS
    ///      address — a future transient reentrancy guard replacing `_entered`, or an inlined
    ///      library that starts using `tstore` — and a silent collision would corrupt the H-1
    ///      measured receipt in the direction that mints sleeve escrow. Deriving the base from
    ///      a keccak namespace and clearing the low byte (ERC-7201 convention) reserves the
    ///      whole region `[BASE, BASE + 255]`, which covers `1 + MAX_DIRECTIONAL = 9` assets
    ///      with no risk of `BASE + i` wandering into a neighbouring namespace.
    ///      Verified at this revision: `B4Pool` contains no `delegatecall`, and no library on
    ///      its call path (`Phi`, `Calendar`, `SafeTransfer`, `CoreReader`, `CoreTypes` — all
    ///      internal, hence inlined rather than delegatecalled) uses `tstore`/`tload`. These
    ///      three sites are the only transient users of the pool's address space. External
    ///      calls (sleeve `deposit`/`crank`, token transfers) get their own transient space
    ///      and cannot reach this one.
    uint256 internal constant PENALTY_SNAPSHOT_TSLOT =
        uint256(keccak256("b4.pool.penaltySnapshot.v1")) & ~uint256(0xff);

    /// @notice Route the measured balance delta from a user-vault non-free exit. In a
    ///         configured pool only settlement + that vault's directional token are penalty
    ///         escrow; another whitelisted token is an ordinary donation. Legacy pools retain
    ///         the historical generic penalty basket.
    /// @notice Snapshot balances immediately BEFORE an exit pushes its penalty in, so the
    ///         paired `capturePenalty()` escrows the MEASURED receipt of that exit.
    /// @dev Audit H-1. `capturePenalty` used to escrow `_unaccounted(token, bal)` — the
    ///      pool's ENTIRE uncommitted balance of the settlement token and of the caller's
    ///      directional token — into the CALLER's sleeve. Any dust vault finalizing an exit
    ///      therefore swept whatever else happened to be unattributed (donations, returned
    ///      sleeve capital, another vault's uncaptured penalty) into a sleeve of its own
    ///      choosing. Value never left the pool, but it left ordinary claim inventory.
    ///      Transient storage: the snapshot is only meaningful inside the single transaction
    ///      that performs the exit and clears itself afterwards, so this buys a measured
    ///      before/after with no persistent state. Slot `PENALTY_SNAPSHOT_TSLOT + i` holds
    ///      `balance + 1`, leaving 0 to mean "no snapshot taken".
    /// @dev EIP-1153 is a mandatory deployment precondition (`SECURITY_MODEL.md` §5.16): on a
    ///      chain without `TSTORE`/`TLOAD` both halves revert into `_finalizeExit`'s try/catch,
    ///      no revert surfaces, and penalty escrow silently never accrues (the penalty itself
    ///      is still recoverable to claim inventory through the transient-free `capture()`).
    function beginPenalty() external {
        if (!isVault[msg.sender]) revert NotAVault();
        if (policyMask == 0) return; // legacy pools route to accruing regardless
        for (uint256 i = 0; i < assetCount; i++) {
            (bool ok, uint256 bal) = _safeBalanceOf(_assets[i].evmToken);
            uint256 slot = PENALTY_SNAPSHOT_TSLOT + i;
            uint256 v = ok ? bal + 1 : 0;
            assembly ("memory-safe") {
                tstore(slot, v)
            }
        }
    }

    function capturePenalty() external nonReentrant {
        if (!isVault[msg.sender]) revert NotAVault();
        if (policyMask == 0) {
            _captureToAccruing();
            return;
        }
        uint8 policy = policyOfVault[msg.sender];
        uint256 dirAssetIndex = dirIndexOfVault[msg.sender];
        if (policy == 0 || dirAssetIndex == 0 || dirAssetIndex >= assetCount) {
            revert BadPolicyConfig();
        }
        for (uint256 i = 0; i < assetCount; i++) {
            address token = _assets[i].evmToken;
            // Consume the snapshot FIRST and UNCONDITIONALLY — before the `balanceOf` below,
            // which may fail and `continue`. Clearing it makes a missing or already-used
            // snapshot read as 0, so `received` is 0 and the value falls through to claim
            // inventory — the documented safe direction — by CONSTRUCTION rather than by
            // discipline at the single paired call site. Clearing it only on the success path
            // left that claim false: a stale pre-transfer snapshot survived an asset whose
            // `balanceOf` failed, and any later capture in the SAME transaction that did not
            // re-snapshot (e.g. a second exit whose `beginPenalty` was swallowed by
            // `_finalizeExit`'s try/catch) would read `received` against a pre-transfer
            // balance and escrow the pool's whole unattributed balance — H-1 itself.
            uint256 slot = PENALTY_SNAPSHOT_TSLOT + i;
            uint256 prev;
            assembly ("memory-safe") {
                prev := tload(slot)
                tstore(slot, 0)
            }
            // Skip (never revert on) an asset whose balanceOf fails: capture is on the
            // exit-penalty path (_finalizeExit calls it un-guarded), so a malicious
            // co-asset must not freeze co-resident vaults' exits — its donation simply
            // isn't captured until it behaves again.
            (bool ok, uint256 bal) = _safeBalanceOf(token);
            if (!ok) continue;
            uint256 delta = _unaccounted(token, bal);
            // Escrow only what THIS exit actually delivered (H-1): the measured increase
            // since `beginPenalty`, still capped by what is genuinely unattributed.
            uint256 received = (prev != 0 && bal + 1 > prev) ? bal + 1 - prev : 0;
            uint256 escrowable = delta < received ? delta : received;
            if (escrowable != 0 && (i == 0 || i == dirAssetIndex)) {
                penaltyEscrow[policy][dirAssetIndex][i] += escrowable;
                escrowHeld[token] += escrowable;
                emit PenaltyCaptured(policy, dirAssetIndex, i, escrowable);
                delta -= escrowable;
            }
            // Whatever remains is not this exit's receipt: a co-listed donation, another
            // vault's uncaptured penalty, or returned sleeve capital. The descriptor array
            // is the immutable whitelist, so keep it ordinary claim inventory — every
            // recorded balance must have a reachable drain path. With no snapshot the
            // receipt is 0 and everything lands here, the safe direction: value stays
            // claimable rather than locked into an arbitrary sleeve.
            if (delta != 0) {
                accruing[i] += delta;
                liability[token] += delta;
                emit Captured(i, delta);
            }
        }
    }

    function _captureToAccruing() internal {
        for (uint256 i = 0; i < assetCount; i++) {
            address token = _assets[i].evmToken;
            // Skip (never revert on) an asset whose balanceOf fails: capture is on the
            // exit-penalty path (_finalizeExit calls it un-guarded), so a malicious
            // co-asset must not freeze co-resident vaults' exits — its donation simply
            // isn't captured until it behaves again.
            (bool ok, uint256 bal) = _safeBalanceOf(token);
            if (!ok) continue;
            uint256 delta = _unaccounted(token, bal);
            if (delta != 0) {
                accruing[i] += delta;
                liability[token] += delta;
                emit Captured(i, delta);
            }
        }
    }

    /// @dev `liability` covers claimable inventory only. `escrowHeld` covers tokens
    ///      currently committed to sleeves. The difference is the only safe measured
    ///      receipt available for either capture route.
    function _unaccounted(address token, uint256 bal) internal view returns (uint256) {
        uint256 claimable = liability[token];
        if (bal <= claimable) return 0;
        uint256 aboveClaimable = bal - claimable;
        uint256 held = escrowHeld[token];
        return aboveClaimable > held ? aboveClaimable - held : 0;
    }

    // ------------------------------------------------------------- pool strategy sleeves

    /// @notice Transfer one policy's measured penalties into its exact pool-owned vault
    ///         and begin the ordinary B4 state machine. No caller can select a different
    ///         target, route or recipient. A Pro/Pro Max sleeve therefore uses the same
    ///         live anchors, price and `StructuralLeverage` stop derivation as a client
    ///         vault opened at that moment.
    function foldPenalty(uint8 policy, uint256 dirAssetIndex)
        external
        nonReentrant
        returns (bool folded)
    {
        address sleeve = _sleeve(policy, dirAssetIndex);
        uint256 dirAmount = penaltyEscrow[policy][dirAssetIndex][dirAssetIndex];
        uint256 usdcAmount = penaltyEscrow[policy][dirAssetIndex][0];
        if (dirAmount == 0 && usdcAmount == 0) return false;

        // Effects first. Any failed approval or deposit reverts atomically, restoring
        // the escrow. `escrowHeld` falls with the physical transfer, leaving claimable
        // inventory and its shortfall ratio unchanged.
        penaltyEscrow[policy][dirAssetIndex][dirAssetIndex] = 0;
        penaltyEscrow[policy][dirAssetIndex][0] = 0;
        if (dirAmount != 0) escrowHeld[_assets[dirAssetIndex].evmToken] -= dirAmount;
        if (usdcAmount != 0) escrowHeld[_assets[0].evmToken] -= usdcAmount;

        if (dirAmount != 0) _approveForSleeve(_assets[dirAssetIndex].evmToken, sleeve, dirAmount);
        if (usdcAmount != 0) _approveForSleeve(_assets[0].evmToken, sleeve, usdcAmount);
        IB4PoolSleeve(sleeve).deposit(dirAmount, usdcAmount);
        // Leave no standing approval even if the sleeve is a known immutable clone.
        if (dirAmount != 0) _assets[dirAssetIndex].evmToken.safeApprove(sleeve, 0);
        if (usdcAmount != 0) _assets[0].evmToken.safeApprove(sleeve, 0);

        // Start the exact normal engine immediately. Further async legs are always
        // permissionless through `crankSleeve`.
        IB4PoolSleeve(sleeve).crank();
        emit EscrowFolded(policy, dirAssetIndex, sleeve, dirAmount, usdcAmount);
        return true;
    }

    function _approveForSleeve(address token, address sleeve, uint256 amount) internal {
        token.safeApprove(sleeve, 0);
        token.safeApprove(sleeve, amount);
    }

    /// @notice Begin a full sleeve exit only in a protocol free-exit window. Its owner is
    ///         this pool, so returned capital lands here and the next `crankSleeve` captures
    ///         it into the ordinary claim basket without a recursive penalty.
    function initiateSleeveExit(uint8 policy, uint256 dirAssetIndex)
        external
        nonReentrant
        returns (bool initiated)
    {
        if (!Calendar.freeExit(oracle.timeSinceHalving())) revert NotFreeExit();
        address sleeve = _sleeve(policy, dirAssetIndex);
        if (IB4PoolSleeve(sleeve).exitShareWad() != 0) return false;
        IB4PoolSleeve(sleeve).initiateExit(Phi.WAD);
        emit SleeveExitInitiated(policy, dirAssetIndex, sleeve);
        return true;
    }

    /// @notice Permissionless liveness for a sleeve. Returned sleeve capital is captured
    ///         only after it has physically reached this pool; it is then claimable at the
    ///         next checkpoint just like any other basket inventory.
    function crankSleeve(uint8 policy, uint256 dirAssetIndex)
        external
        nonReentrant
        returns (bool progressed)
    {
        progressed = IB4PoolSleeve(_sleeve(policy, dirAssetIndex)).crank();
        _captureToAccruing();
    }

    /// @dev The ONLY way any of the sleeve entrypoints below name a callee: a
    ///      factory-registered address read out of the immutable `sleeveOf` table. A caller
    ///      supplies `(policy, dirAssetIndex)` exactly as it already does for `foldPenalty`
    ///      / `initiateSleeveExit` / `crankSleeve` — it selects WHICH known sleeve is
    ///      serviced, never an address, never a recipient, never an amount (F2).
    function _sleeve(uint8 policy, uint256 dirAssetIndex) internal view returns (address sleeve) {
        sleeve = sleeveOf[policy][dirAssetIndex];
        if (sleeve == address(0) || !isSleeve[sleeve]) revert NotASleeve();
    }

    // ------------------------------------------------- sleeve owner-escapes (audit L-1)
    //
    // A sleeve is initialized with `owner == pool` (`B4ProductPoolCreator._createSleeve`),
    // so B4Pool is the unique address that can satisfy the vault's `onlyOwner`. Before
    // this section it exposed no forwarder, which made two documented guarantees FALSE
    // for pool-owned vaults:
    //   * INVARIANTS row 20 / `B4VaultOps._finalizeExit` — "`cancelExit` is the escape
    //     from a permanently dead price feed". A sleeve could enter ExitPending and never
    //     leave it: `exitShareWad != 0` pins `opsPlanStep` on the exit machine, so the
    //     sleeve stops following its calendar target for the whole outage, and it blocks
    //     `deposit`, so `foldPenalty` reverts and that product's `penaltyEscrow` stays
    //     outside claim inventory. HONEST BOUND on what the escape buys: while the feed is
    //     still dead, cancelling does NOT by itself restore a DIRECTIONAL fold —
    //     `B4Vault.deposit` reverts `ZeroPrice` inside its own directional branch (H-3).
    //     It restores the settlement-only fold, returns the sleeve to the sync planner,
    //     and makes it immediately usable the instant the feed returns.
    //   * HAZARDS B6 / decision C1 — "surplus above recorded principal is recoverable to
    //     the owner". Every surplus class a sleeve accrues (funding above the harvest
    //     bound, A11 favourable overfill, Core spot above principal, over-delivery on a
    //     Core→EVM return, plain donations) was permanently unreachable.
    //
    // None of these creates a privileged fund mover. The mover is still the sleeve, under
    // its own bounded B6 rules; the pool only relays a call whose recipient it cannot
    // choose — the vault pays `owner`, and `owner` IS this pool. `_captureToAccruing`
    // then admits the arrival by MEASURED delta (D2), so recovered surplus becomes
    // ordinary claim inventory distributed by reported weight. That is the only
    // disposition available: the pool has no treasury, no admin and no authority to make
    // a distribution decision, and the same sink already receives every other unit of
    // sleeve value through the free-window exit (`crankSleeve`).

    /// @notice Escape a sleeve exit that a dead directional price feed has permanently
    ///         deferred — the pool-side half of INVARIANTS row 20.
    /// @dev Deliberately gated, not a free control. `_finalizeExit` defers exactly when
    ///      `pxWad == 0 && dirEvm + coreDirWei != 0` (audit H-3), so that same predicate is
    ///      required here: it is the EXACT complement of "this exit can still finalize".
    ///      With a live feed the call cannot be made at all, which is what keeps an
    ///      otherwise permissionless cancel from becoming an indefinite grief on sleeve
    ///      repatriation — there is no admin to unstick that.
    ///
    ///      Evaluating the predicate mid-exit is sound: the exit steps that still run
    ///      (perp flatten, harvest, Core principal return) only move directional value
    ///      from `coreDirWei` into `dirEvm`, so the sum stays non-zero and the deferral at
    ///      `_finalizeExit` is already determined. Cancelling moves no funds and consumes
    ///      no exit share, so nothing can be stranded (see `B4Vault.cancelExit`); the
    ///      sleeve returns to the ordinary planner and is re-exitable in a free window.
    ///      Not wired into `Keeper` on purpose: this must never fire on the routine path.
    function cancelSleeveExit(uint8 policy, uint256 dirAssetIndex)
        external
        nonReentrant
        returns (bool cancelled)
    {
        address sleeve = _sleeve(policy, dirAssetIndex);
        if (IB4PoolSleeve(sleeve).exitShareWad() == 0) return false;
        // Same descriptor the sleeve values itself with: `_assets[dirAssetIndex]` is the
        // exact struct passed to that sleeve's `initialize` as `_dir`.
        if (CoreReader.spotPxWad(_assets[dirAssetIndex]) != 0) revert NotStuck();
        if (IB4PoolSleeve(sleeve).dirEvm() + IB4PoolSleeve(sleeve).coreDirWei() == 0) {
            revert NotStuck();
        }
        IB4PoolSleeve(sleeve).cancelExit();
        emit SleeveExitCancelled(policy, dirAssetIndex, sleeve);
        return true;
    }

    /// @notice Recover a sleeve's unaccounted EVM surplus into ordinary claim inventory.
    /// @dev `assetIndex` is an index into the immutable descriptor whitelist, not a token
    ///      address: the caller cannot name an arbitrary token, and every wei that lands
    ///      here therefore has a drain path (`_captureToAccruing` only knows `_assets`).
    ///      A non-whitelisted airdrop into a sleeve stays where it is — moving it would
    ///      only relocate an undrainable balance into the pool. The amount is the vault's
    ///      own `balance − recorded` bound under `_requireIdle` for its two accounted
    ///      tokens (B6); this contract supplies no amount and no recipient.
    function recoverSleeveEvm(uint8 policy, uint256 dirAssetIndex, uint256 assetIndex)
        external
        nonReentrant
    {
        address sleeve = _sleeve(policy, dirAssetIndex);
        if (assetIndex >= assetCount) revert BadAsset();
        IB4PoolSleeve(sleeve).recoverEvm(_assets[assetIndex].evmToken);
        // Measured receipt (D2): the transfer already landed, so capture books exactly
        // the delta above `liability + escrowHeld` and the pool invariant is preserved.
        _captureToAccruing();
    }

    /// @notice Recover a sleeve's Core spot balance above recorded principal (B6).
    /// @dev Two-leg async: the payout reaches this pool later, inside the sleeve's own
    ///      `_verifyRecovery`, and the `crankSleeve` that drives it captures on the same
    ///      call — so no capture is needed (or possible) here. `_requireIdleFlat` on the
    ///      vault side means this can never interrupt a live position or a pending exit.
    function recoverSleeveCoreSpot(uint8 policy, uint256 dirAssetIndex, bool dirToken)
        external
        nonReentrant
    {
        IB4PoolSleeve(_sleeve(policy, dirAssetIndex)).recoverCoreSpot(dirToken);
    }

    /// @notice Recover a sleeve's perp withdrawable above margin principal + the pending
    ///         harvest claim — the untaxed funding surplus of decision C1, which for a
    ///         pool-owned sleeve belongs to pool claimants. Async, as above.
    function recoverSleevePerpSurplus(uint8 policy, uint256 dirAssetIndex)
        external
        nonReentrant
    {
        IB4PoolSleeve(_sleeve(policy, dirAssetIndex)).recoverPerpSurplus();
    }

    /// @notice Abandon a sleeve's stuck SURPLUS-RECOVERY intent after `EMERGENCY_TIMEOUT`.
    /// @dev MANDATORY companion of the three recovery forwarders, not an extra: a pending
    ///      intent blocks the whole crank (`crank` verifies before it plans), so a
    ///      recovery leg the venue never completes would freeze the sleeve's exit machine
    ///      and permanently strand its principal — turning an accounting leak into the
    ///      permanent freeze that the worst-case rule forbids. The vault side already
    ///      refuses every non-`Recover*` kind and enforces the timeout (A6), and the funds
    ///      stay on Core and re-recoverable, so relaying it grants nothing.
    function clearSleeveRecovery(uint8 policy, uint256 dirAssetIndex) external nonReentrant {
        IB4PoolSleeve(_sleeve(policy, dirAssetIndex)).emergencyClearRecovery();
    }

    /// Gas cap on untrusted token reads: a hostile token that burns the forwarded gas
    /// would otherwise (via EIP-150's 63/64 rule) let a few basket entries exhaust the
    /// whole claim/capture transaction and defeat the per-token isolation (V3-POOL-1).
    uint256 internal constant TOKEN_READ_GAS = 100_000;

    /// @dev Revert-free, return-bomb-capped, gas-capped `balanceOf` read: staticcall with
    ///      bounded gas and the return copy bounded to 32 bytes, so a hostile basket token
    ///      can neither revert, OOG, nor return-bomb the caller. (false, 0) on any failure.
    function _safeBalanceOf(address token) internal view returns (bool ok, uint256 bal) {
        bytes memory data = abi.encodeWithSelector(IERC20.balanceOf.selector, address(this));
        uint256 word;
        assembly {
            let g := gas()
            if gt(g, TOKEN_READ_GAS) { g := TOKEN_READ_GAS }
            let s := staticcall(g, token, add(data, 0x20), mload(data), 0x00, 0x20)
            ok := and(s, iszero(lt(returndatasize(), 0x20)))
            word := mload(0x00)
        }
        if (ok) bal = word;
    }

    // ------------------------------------------------------------------ views

    function intervalInfo(uint256 id)
        external
        view
        returns (uint64 pointTime, uint64 lockedAt, bool swept, uint256 totalWeight)
    {
        Interval storage it = _intervals[id];
        return (it.pointTime, it.lockedAt, it.swept, it.totalWeight);
    }

    function lockedPxWad(uint256 id, uint256 assetIndex) external view returns (uint256) {
        return _intervals[id].lockedPxWad[assetIndex];
    }

    function bucketOf(uint256 id, uint256 assetIndex) external view returns (uint256) {
        return _intervals[id].bucket[assetIndex];
    }

    function remainingOf(uint256 id, uint256 assetIndex) external view returns (uint256) {
        return _intervals[id].remaining[assetIndex];
    }

    function weightOf(uint256 id, address vault) external view returns (uint256) {
        return _intervals[id].weightOf[vault];
    }

    function claimedOf(uint256 id, address vault, uint256 assetIndex) external view returns (bool) {
        return _intervals[id].claimed[vault][assetIndex];
    }

    /// @notice Latest interval whose report window is currently open, if any.
    function currentReportable() external view returns (bool exists, uint256 id) {
        if (intervalCount == 0) return (false, 0);
        id = intervalCount - 1;
        Interval storage it = _intervals[id];
        exists = it.lockedAt != 0 && block.timestamp <= reportDeadline(id);
    }

    function _interval(uint256 id) internal view returns (Interval storage it) {
        if (id >= intervalCount) revert NotMaterialized();
        it = _intervals[id];
    }
}
