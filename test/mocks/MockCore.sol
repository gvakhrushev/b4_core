// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreTypes} from "src/venue/CoreTypes.sol";

// Fixed address the precompile shims forward to; tests etch MockCoreHub's runtime here.
address constant HUB = 0x00000000000000000000000000000000c0dEcAFe;

/// @notice Etched at every read-precompile address; forwards (self, calldata) to the hub.
contract PrecompileShim {
    fallback(bytes calldata data) external returns (bytes memory) {
        return MockCoreHub(HUB).read(address(this), data);
    }
}

/// @notice Etched at the CoreWriter address; queues raw actions with their sender.
contract CoreWriterShim {
    function sendRawAction(bytes calldata data) external {
        MockCoreHub(HUB).enqueueAction(msg.sender, data);
    }
}

/// @notice Plain ERC20 that mirrors the linked-token bridge: a transfer to a registered
///         system address queues an EVM→Core credit on the hub (async, like the venue).
contract MockERC20 {
    string public name;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory name_, uint8 decimals_) {
        name = name_;
        decimals = decimals_;
    }

    bool public blocked; // test knob: transfers return false (D5 retryable-claim cases)
    mapping(address => bool) public blockedTo; // test knob: per-recipient blacklist

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    /// Test knob: models an external deficit (e.g. issuer action) for D3 socialization.
    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function setBlocked(bool v) external {
        blocked = v;
    }

    /// Test knob: models an issuer blacklist of a single recipient.
    function setBlockedTo(address to, bool v) external {
        blockedTo[to] = v;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        if (blocked || blockedTo[to]) return false;
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (MockCoreHub(HUB).systemAddressToken(to) != 0 || MockCoreHub(HUB).isSystemAddress(to)) {
            MockCoreHub(HUB).notifyEvmToCore(from, to, amount);
        }
        return true;
    }
}

/// @title MockCoreHub — simulated HyperCore state with adversarial controls.
/// @notice NOT a venue emulator: it implements the same read/write ABI as the live venue
///         so the async engine can be driven happy-path and adversarially (delayed, dropped
///         and partially filled actions; external Core top-ups; withdrawable drift;
///         debit-then-deliver Core→EVM; activation fees). Live venue timing/atomicity
///         remains a funded gate (TEST_PLAN §5).
contract MockCoreHub {
    struct Pos {
        int64 szi;
        uint64 entryNtl;
        uint32 leverage;
    }

    struct TokenCfg {
        address evmToken;
        uint8 weiDecimals;
        uint8 szDecimals;
        uint8 evmDecimals;
        bool exists;
        string name;
    }

    struct SpotCfg {
        uint64 base;
        uint64 quote;
        bool exists;
    }

    struct PerpCfg {
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
        bool exists;
        string coin;
    }

    struct Action {
        address sender;
        bytes data;
        bool dropped;
    }

    struct EvmCredit {
        address user;
        uint64 token;
        uint64 weiAmount;
    }

    struct EvmDelivery {
        address user;
        uint64 token;
        uint64 weiAmount;
    }

    // core state
    mapping(address => mapping(uint64 => uint64)) public spotBal;
    mapping(address => uint64) public wd; // perp withdrawable
    mapping(address => mapping(uint32 => Pos)) public positions;
    mapping(address => bool) public userExists;
    /// Ghost for invariant campaigns: cumulative realized perp losses per user (1e6).
    mapping(address => uint256) public realizedLoss6;

    // config
    mapping(uint64 => TokenCfg) public tokens;
    mapping(uint32 => SpotCfg) public spotMarkets;
    mapping(uint32 => PerpCfg) public perpMarkets;
    mapping(uint32 => uint64) public spotPxOf; // (8 − szDec) decimals
    mapping(uint32 => uint64) public markPxOf; // (6 − szDec) decimals
    mapping(uint32 => uint64) public oraclePxOf;
    mapping(address => uint64) public systemAddressToken;
    mapping(address => bool) public isSystemAddress;
    mapping(uint64 => uint64) public activationFee; // wei of the credited token
    uint64 public usdcToken;

    // behavior knobs
    bool public autoExecute; // apply actions immediately on enqueue
    bool public autoCredit; // apply EVM→Core credits immediately
    bool public autoDeliver; // deliver Core→EVM immediately after debit
    uint256 public dropNext; // silently discard the next N queued actions
    mapping(uint32 => uint16) public fillRatioBps; // default 10000
    mapping(uint32 => uint64) public execPxOverride; // 0 ⇒ use spot/mark px

    Action[] public queue;
    uint256 public queueHead;
    EvmCredit[] public creditQueue;
    uint256 public creditHead;
    EvmDelivery[] public deliveryQueue;
    uint256 public deliveryHead;

    // ------------------------------------------------------------------ configuration

    function registerToken(
        uint64 id,
        address evmToken,
        uint8 weiDec,
        uint8 szDec,
        uint8 evmDec,
        string calldata name_
    ) external {
        tokens[id] = TokenCfg(evmToken, weiDec, szDec, evmDec, true, name_);
        address sys = CoreTypes.systemAddress(id);
        systemAddressToken[sys] = id;
        isSystemAddress[sys] = true;
    }

    function setUsdcToken(uint64 id) external {
        usdcToken = id;
    }

    function registerSpotMarket(uint32 id, uint64 base, uint64 quote) external {
        spotMarkets[id] = SpotCfg(base, quote, true);
        fillRatioBps[CoreTypes.SPOT_ASSET_OFFSET + id] = 10_000;
    }

    function registerPerpMarket(uint32 id, uint8 szDec, uint8 maxLev, bool onlyIso) external {
        perpMarkets[id] = PerpCfg(szDec, maxLev, onlyIso, true, "PERP");
        fillRatioBps[id] = 10_000;
    }

    function setSpotPx(uint32 m, uint64 px) external {
        spotPxOf[m] = px;
    }

    function setMarkPx(uint32 m, uint64 px) external {
        markPxOf[m] = px;
    }

    function setOraclePx(uint32 m, uint64 px) external {
        oraclePxOf[m] = px;
    }

    function setActivationFee(uint64 token, uint64 fee) external {
        activationFee[token] = fee;
    }

    function setAuto(bool exec, bool credit, bool deliver) external {
        autoExecute = exec;
        autoCredit = credit;
        autoDeliver = deliver;
    }

    function setFillRatio(uint32 asset, uint16 ratioBps) external {
        fillRatioBps[asset] = ratioBps;
    }

    function setExecPx(uint32 asset, uint64 px) external {
        execPxOverride[asset] = px;
    }

    function setDropNext(uint256 n) external {
        dropNext = n;
    }

    // ------------------------------------------------------------------ adversarial knobs

    /// External Core spot credit — a standard venue operation, adversarial for us.
    function coreTopUp(address user, uint64 token, uint64 amount) external {
        spotBal[user][token] += amount;
    }

    function setWithdrawable(address user, uint64 x) external {
        wd[user] = x;
    }

    function addWithdrawable(address user, uint64 x) external {
        wd[user] += x;
    }

    function subWithdrawable(address user, uint64 x) external {
        wd[user] = wd[user] > x ? wd[user] - x : 0;
    }

    function setPosition(address user, uint32 perp, int64 szi, uint64 entryNtl) external {
        positions[user][perp] = Pos(szi, entryNtl, 1);
    }

    function setUserExists(address user, bool v) external {
        userExists[user] = v;
    }

    // ------------------------------------------------------------------ EVM→Core bridge

    function notifyEvmToCore(address from, address sysAddr, uint256 evmAmount) external {
        uint64 token = systemAddressToken[sysAddr];
        TokenCfg memory cfg = tokens[token];
        uint64 weiAmount;
        if (cfg.evmDecimals >= cfg.weiDecimals) {
            weiAmount = uint64(evmAmount / 10 ** (cfg.evmDecimals - cfg.weiDecimals));
        } else {
            weiAmount = uint64(evmAmount * 10 ** (cfg.weiDecimals - cfg.evmDecimals));
        }
        creditQueue.push(EvmCredit(from, token, weiAmount));
        if (autoCredit) applyCredits();
    }

    function applyCredits() public {
        while (creditHead < creditQueue.length) {
            EvmCredit memory c = creditQueue[creditHead++];
            uint64 amount = c.weiAmount;
            if (!userExists[c.user]) {
                uint64 fee = activationFee[c.token];
                amount = amount > fee ? amount - fee : 0;
                userExists[c.user] = true;
            }
            spotBal[c.user][c.token] += amount;
        }
    }

    /// Pending (queued, unapplied) credits — lets tests simulate the in-flight window.
    function pendingCredits() external view returns (uint256) {
        return creditQueue.length - creditHead;
    }

    // ------------------------------------------------------------------ action queue

    function enqueueAction(address sender, bytes calldata data) external {
        if (dropNext > 0) {
            dropNext--;
            queue.push(Action(sender, data, true));
            return;
        }
        queue.push(Action(sender, data, false));
        if (autoExecute) executeActions();
    }

    function pendingActions() external view returns (uint256) {
        return queue.length - queueHead;
    }

    function executeActions() public {
        while (queueHead < queue.length) {
            Action memory a = queue[queueHead++];
            if (!a.dropped) _apply(a.sender, a.data);
        }
        if (autoDeliver) deliverEvm();
    }

    function deliverEvm() public {
        while (deliveryHead < deliveryQueue.length) {
            EvmDelivery memory d = deliveryQueue[deliveryHead++];
            TokenCfg memory cfg = tokens[d.token];
            uint256 evmAmount;
            if (cfg.evmDecimals >= cfg.weiDecimals) {
                evmAmount = uint256(d.weiAmount) * 10 ** (cfg.evmDecimals - cfg.weiDecimals);
            } else {
                evmAmount = uint256(d.weiAmount) / 10 ** (cfg.weiDecimals - cfg.evmDecimals);
            }
            MockERC20(cfg.evmToken).mint(d.user, evmAmount);
        }
    }

    function pendingDeliveries() external view returns (uint256) {
        return deliveryQueue.length - deliveryHead;
    }

    function _apply(address sender, bytes memory raw) internal {
        // [version:1][actionId:3][abi args]
        uint8 version = uint8(raw[0]);
        require(version == CoreTypes.ACTION_VERSION, "version");
        uint24 actionId =
            (uint24(uint8(raw[1])) << 16) | (uint24(uint8(raw[2])) << 8) | uint24(uint8(raw[3]));
        bytes memory args = new bytes(raw.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = raw[i + 4];
        }

        if (actionId == CoreTypes.ACTION_USD_CLASS_TRANSFER) {
            (uint64 ntl, bool toPerp) = abi.decode(args, (uint64, bool));
            _usdClassTransfer(sender, ntl, toPerp);
        } else if (actionId == CoreTypes.ACTION_SPOT_SEND) {
            (address dest, uint64 token, uint64 weiAmount) =
                abi.decode(args, (address, uint64, uint64));
            _spotSend(sender, dest, token, weiAmount);
        } else if (actionId == CoreTypes.ACTION_LIMIT_ORDER) {
            (uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly,,) =
                abi.decode(args, (uint32, bool, uint64, uint64, bool, uint8, uint128));
            _order(sender, asset, isBuy, limitPx, sz, reduceOnly);
        }
        // unknown actions: ignored (venue would reject; either way no local effect)
    }

    function _spotOrder(address user, uint32 asset, bool isBuy, uint64 limitPx, uint64 fillSz)
        internal
    {
        uint32 m = asset - CoreTypes.SPOT_ASSET_OFFSET;
        SpotCfg memory cfg = spotMarkets[m];
        uint64 px = execPxOverride[asset] != 0 ? execPxOverride[asset] : spotPxOf[m];
        if (isBuy ? limitPx < px : limitPx > px) return; // book beyond limit: no fill
        // base wei per sz lot; px carries (8 − szDec) decimals ⇒ sz·px has 8 decimals.
        uint64 baseWei =
            fillSz * uint64(10 ** (tokens[cfg.base].weiDecimals - tokens[cfg.base].szDecimals));
        uint64 quoteWei = _toWei(cfg.quote, uint256(fillSz) * px);
        if (isBuy) {
            if (spotBal[user][cfg.quote] < quoteWei) return;
            spotBal[user][cfg.quote] -= quoteWei;
            spotBal[user][cfg.base] += baseWei;
        } else {
            if (spotBal[user][cfg.base] < baseWei) return;
            spotBal[user][cfg.base] -= baseWei;
            spotBal[user][cfg.quote] += quoteWei;
        }
    }

    /// notional8 is a 1e8-USD amount; convert to the token's wei decimals.
    function _toWei(uint64 token, uint256 notional8) internal view returns (uint64) {
        uint8 w = tokens[token].weiDecimals;
        return w >= 8 ? uint64(notional8 * 10 ** (w - 8)) : uint64(notional8 / 10 ** (8 - w));
    }

    function _usdClassTransfer(address user, uint64 ntl, bool toPerp) internal {
        uint8 w = tokens[usdcToken].weiDecimals;
        uint64 weiAmt = ntl * uint64(10 ** (w - CoreTypes.PERP_USD_DECIMALS));
        if (toPerp) {
            if (spotBal[user][usdcToken] < weiAmt) return; // venue rejects silently for us
            spotBal[user][usdcToken] -= weiAmt;
            wd[user] += ntl;
        } else {
            if (wd[user] < ntl) return;
            wd[user] -= ntl;
            spotBal[user][usdcToken] += weiAmt;
        }
    }

    function _spotSend(address user, address dest, uint64 token, uint64 weiAmount) internal {
        if (spotBal[user][token] < weiAmount) return;
        spotBal[user][token] -= weiAmount;
        if (isSystemAddress[dest] && systemAddressToken[dest] == token) {
            // Core → EVM: debit now, deliver later (A7 debit-then-deliver window).
            deliveryQueue.push(EvmDelivery(user, token, weiAmount));
            if (autoDeliver) deliverEvm();
        } else {
            spotBal[dest][token] += weiAmount;
        }
    }

    /// CoreWriter order fields arrive in FIXED-1e8 units (human value × 10⁸) — convert
    /// to the internal read/lot conventions before applying, mirroring the live venue's
    /// writer↔reader asymmetry.
    function _order(
        address user,
        uint32 asset,
        bool isBuy,
        uint64 limitPx8,
        uint64 sz8,
        bool reduceOnly
    ) internal {
        uint8 szDec;
        uint64 limitPx;
        if (asset >= CoreTypes.SPOT_ASSET_OFFSET) {
            SpotCfg memory scfg = spotMarkets[asset - CoreTypes.SPOT_ASSET_OFFSET];
            szDec = tokens[scfg.base].szDecimals;
            // spot read px carries (8 − szDec) decimals: px8 = px_read · 10^szDec.
            limitPx = limitPx8 / uint64(10 ** szDec);
        } else {
            szDec = perpMarkets[asset].szDecimals;
            // perp read px carries (6 − szDec) decimals: px8 = px_read · 10^(szDec + 2).
            limitPx = limitPx8 / uint64(10 ** (szDec + 2));
        }
        uint64 sz = sz8 / uint64(10 ** (8 - szDec)); // lots (floor to venue granularity)

        uint16 ratio = fillRatioBps[asset];
        uint64 fillSz = uint64((uint256(sz) * ratio) / 10_000);
        if (fillSz == 0) return;

        if (asset >= CoreTypes.SPOT_ASSET_OFFSET) {
            _spotOrder(user, asset, isBuy, limitPx, fillSz);
        } else {
            _perpOrder(user, asset, isBuy, limitPx, fillSz, reduceOnly);
        }
    }

    function _perpOrder(
        address user,
        uint32 asset,
        bool isBuy,
        uint64 limitPx,
        uint64 fillSz,
        bool reduceOnly
    ) internal {
        uint64 px = execPxOverride[asset] != 0 ? execPxOverride[asset] : markPxOf[asset];
        if (isBuy ? limitPx < px : limitPx > px) return;
        Pos storage p = positions[user][asset];
        if (reduceOnly) {
            // Only toward zero, never across.
            if (p.szi == 0 || (p.szi > 0) == isBuy) return;
            uint64 absSzi = uint64(p.szi > 0 ? p.szi : -p.szi);
            if (fillSz > absSzi) fillSz = absSzi;
        }
        bool increasing = p.szi == 0 || ((p.szi > 0) == isBuy);
        if (increasing) {
            p.szi += isBuy ? int64(fillSz) : -int64(fillSz);
            // ntl of the fill at exec price: sz·px has 6 decimals (perp convention).
            p.entryNtl += uint64(uint256(fillSz) * px);
        } else {
            uint64 closeSz = _perpClose(p, user, fillSz, px);
            uint64 rem = fillSz - closeSz;
            if (rem > 0) {
                // remainder opens the other side (vault never does this; keep simple)
                p.szi += isBuy ? int64(rem) : -int64(rem);
                p.entryNtl += uint64(uint256(rem) * px);
            }
        }
    }

    function _perpClose(Pos storage p, address user, uint64 fillSz, uint64 px)
        internal
        returns (uint64 closeSz)
    {
        uint64 absSzi = uint64(p.szi > 0 ? p.szi : -p.szi);
        closeSz = fillSz > absSzi ? absSzi : fillSz;
        uint64 closedNtl = uint64(uint256(p.entryNtl) * closeSz / absSzi);
        uint64 closeNtlAtPx = uint64(uint256(closeSz) * px);
        // realized pnl: long profits when px above entry; short the reverse.
        int256 pnl = p.szi > 0
            ? int256(uint256(closeNtlAtPx)) - int256(uint256(closedNtl))
            : int256(uint256(closedNtl)) - int256(uint256(closeNtlAtPx));
        if (pnl >= 0) {
            wd[user] += uint64(uint256(pnl));
        } else {
            uint256 loss = uint256(-pnl);
            realizedLoss6[user] += loss;
            wd[user] = wd[user] > loss ? wd[user] - uint64(loss) : 0;
        }
        p.entryNtl -= closedNtl;
        p.szi += p.szi > 0 ? -int64(closeSz) : int64(closeSz);
    }

    // ------------------------------------------------------------------ precompile reads

    function read(address precompile, bytes calldata data) external view returns (bytes memory) {
        if (precompile == CoreTypes.PRECOMPILE_POSITION) {
            (address user, uint16 perp) = abi.decode(data, (address, uint16));
            // Live-venue fidelity: querying a nonexistent/invalid perp asset fails the
            // precompile call instead of returning an empty position. This is what turns
            // an unguarded NO_MARKET (truncated to 65535) read into a bricked vault.
            require(perpMarkets[perp].exists, "invalid perp asset");
            Pos memory p = positions[user][perp];
            return abi.encode(CoreTypes.Position(p.szi, p.entryNtl, int64(0), p.leverage, false));
        }
        if (precompile == CoreTypes.PRECOMPILE_SPOT_BALANCE) {
            (address user, uint64 token) = abi.decode(data, (address, uint64));
            return abi.encode(CoreTypes.SpotBalance(spotBal[user][token], 0, 0));
        }
        if (precompile == CoreTypes.PRECOMPILE_WITHDRAWABLE) {
            address user = abi.decode(data, (address));
            return abi.encode(wd[user]);
        }
        if (precompile == CoreTypes.PRECOMPILE_MARK_PX) {
            return abi.encode(markPxOf[abi.decode(data, (uint32))]);
        }
        if (precompile == CoreTypes.PRECOMPILE_ORACLE_PX) {
            return abi.encode(oraclePxOf[abi.decode(data, (uint32))]);
        }
        if (precompile == CoreTypes.PRECOMPILE_SPOT_PX) {
            return abi.encode(spotPxOf[abi.decode(data, (uint32))]);
        }
        if (precompile == CoreTypes.PRECOMPILE_PERP_ASSET_INFO) {
            uint32 m = abi.decode(data, (uint32));
            PerpCfg memory c = perpMarkets[m];
            require(c.exists, "no perp");
            return abi.encode(
                CoreTypes.PerpAssetInfo(c.coin, 0, c.szDecimals, c.maxLeverage, c.onlyIsolated)
            );
        }
        if (precompile == CoreTypes.PRECOMPILE_SPOT_INFO) {
            uint32 m = abi.decode(data, (uint32));
            SpotCfg memory c = spotMarkets[m];
            require(c.exists, "no spot");
            uint64[2] memory pair = [c.base, c.quote];
            return abi.encode(CoreTypes.SpotInfo("PAIR", pair));
        }
        if (precompile == CoreTypes.PRECOMPILE_TOKEN_INFO) {
            uint32 id = abi.decode(data, (uint32));
            TokenCfg memory c = tokens[uint64(id)];
            require(c.exists, "no token");
            uint64[] memory spots = new uint64[](0);
            int8 extra = int8(int16(uint16(c.evmDecimals)) - int16(uint16(c.weiDecimals)));
            return abi.encode(
                CoreTypes.TokenInfo(
                    c.name, spots, 0, address(0), c.evmToken, c.szDecimals, c.weiDecimals, extra
                )
            );
        }
        if (precompile == CoreTypes.PRECOMPILE_CORE_USER_EXISTS) {
            return abi.encode(userExists[abi.decode(data, (address))]);
        }
        revert("unknown precompile");
    }
}
