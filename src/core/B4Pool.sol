// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Phi} from "../libraries/Phi.sol";
import {Calendar} from "../libraries/Calendar.sol";
import {SafeTransfer} from "../libraries/SafeTransfer.sol";
import {CoreTypes} from "../venue/CoreTypes.sol";
import {CoreReader} from "../venue/CoreReader.sol";
import {IHalvingOracle} from "../interfaces/IHalvingOracle.sol";
import {IERC20} from "../interfaces/IERC20.sol";

interface IB4VaultOwner {
    function owner() external view returns (address);
}

/// @title B4Pool — shared reward basket: intervals, checkpoint prices, weights, claims.
/// @notice Permissionless creation is not endorsement (REQUIREMENTS §1). One pool admits
///         1–N directional descriptors keyed by full descriptor hash plus the settlement
///         descriptor; separate pools share nothing. Liability discipline per HAZARDS D:
///         liability grows only by measured receipt (D2), the checkpoint-price lock is
///         all-or-nothing (D1), loss socialization is order-independent (D3), expired
///         inventory sweeps once with liability unchanged (D4), and a failed token
///         transfer leaves only that token's claim retryable (D5).
contract B4Pool {
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
    }

    mapping(uint256 => Anchor) internal _anchor; // directional asset index → anchors

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
    event Claimed(
        uint256 indexed id, address indexed vault, uint256 assetIndex, uint256 nominal, uint256 paid
    );
    event ClaimDeferred(uint256 indexed id, address indexed vault, uint256 assetIndex);
    event Swept(uint256 indexed id);
    event Captured(uint256 assetIndex, uint256 amount);
    event VaultRegistered(address vault);
    event AnchorSampled(uint256 indexed assetIndex, uint256 floor, uint256 cap, uint256 tag);

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

    modifier nonReentrant() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    /// @param descriptors settlement descriptor at [0], then 1..N directional. The factory
    ///        validates each against the venue before deployment (F3: binding cannot
    ///        precede validation).
    constructor(address oracle_, CoreTypes.AssetDescriptor[] memory descriptors) {
        factory = msg.sender;
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
        isVault[vault] = true;
        emit VaultRegistered(vault);
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
        it.lockedPxWad[0] = Phi.WAD; // fixed USDC = 1 USD (decision C3)
        for (uint256 i = 1; i < assetCount; i++) {
            uint256 px = CoreReader.spotPxWad(_assets[i]);
            if (px == 0) revert ZeroPrice();
            it.lockedPxWad[i] = px;
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
    function sampleAnchor(uint256 i) external {
        if (i == 0 || i >= assetCount) revert BadAsset();
        uint256 t = oracle.timeSinceHalving();
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
        // 62-window confirmed (an even outgoing tag); if the previous cycle's 62-window went
        // unsampled the cap still holds a post-halving low (odd tag), which is NOT a cycle
        // bottom and must not become the floor. Skipping the promotion leaves floor at the
        // prior confirmed low — the conservative direction (a lower floor ⇒ lower leverage),
        // matching the documented flip-skip behaviour rather than poisoning the floor high.
        uint256 tag = oracle.epoch() * 2 + kind + 1; // +1 so 0 means "never sampled"
        Anchor storage a = _anchor[i];
        if (tag != a.windowTag) {
            // A new window opens.
            if (kind == 0 && a.windowTag != 0 && a.windowTag % 2 == 0) {
                a.floor = a.cap; // halving flip: a 62-window-confirmed cap becomes the floor
            }
            a.cap = px; // reseed the ceiling to the first observation of this window
            a.windowTag = tag;
        } else if (px < a.cap) {
            a.cap = px; // ratchet the ceiling down within the window
        }
        emit AnchorSampled(i, a.floor, a.cap, tag);
    }

    /// @notice The `(floor, cap)` anchors for directional asset `i`, WAD. `(0, 0)` before any
    ///         window is sampled — a leveraged product then uses its flat base leverage.
    function anchors(uint256 i) external view returns (uint256 floor, uint256 cap) {
        Anchor storage a = _anchor[i];
        return (a.floor, a.cap);
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
            uint256 pay = bal >= liab ? nominal : Phi.mulDiv(nominal, bal, liab);
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

    /// @notice Capture any balance above liability into the accruing interval — measured
    ///         receipt only (D2); a donation becomes inventory, never vault profit. This is
    ///         also how exit penalties enter: the vault transfers, then calls capture().
    /// @dev nonReentrant: prevents a malicious pool token from reentering (from claimFor's
    ///      payout) to bump liability/accruing against a stale mid-claim balance (F4).
    function capture() external nonReentrant {
        for (uint256 i = 0; i < assetCount; i++) {
            address token = _assets[i].evmToken;
            // Skip (never revert on) an asset whose balanceOf fails: capture is on the
            // exit-penalty path (_finalizeExit calls it un-guarded), so a malicious
            // co-asset must not freeze co-resident vaults' exits — its donation simply
            // isn't captured until it behaves again.
            (bool ok, uint256 bal) = _safeBalanceOf(token);
            if (!ok) continue;
            uint256 liab = liability[token];
            if (bal > liab) {
                uint256 delta = bal - liab;
                accruing[i] += delta;
                liability[token] = bal;
                emit Captured(i, delta);
            }
        }
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
