// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {VenueTestBase} from "../utils/VenueTestBase.sol";
import {MockLzEndpoint} from "../mocks/MockLzEndpoint.sol";
import {HalvingOracle} from "src/core/HalvingOracle.sol";
import {B4Factory} from "src/core/B4Factory.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultOps} from "src/core/B4VaultOps.sol";
import {B4VaultRecovery} from "src/core/B4VaultRecovery.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {Origin} from "src/interfaces/ILayerZero.sol";
import {
    StrategyMini,
    StrategyB4,
    StrategyPro,
    StrategyProMax
} from "src/periphery/ReferenceStrategies.sol";

/// @title Historical benchmark on the REAL contracts. Returns are `B4Vault.navWad()` and drawdowns
///        are mark-to-market equity (NAV + unrealized perp PnL — see `_equityWad`; NAV alone is
///        blind to a pure-perp product's only leg), read
///        off the actual B4Vault/B4VaultOps/B4Pool/HalvingOracle + reference strategies, cranked
///        and settled day-by-day across the real halving epochs exactly as the on-chain keeper
///        would — NOT a hand-rolled parallel equity model. Every vault starts from the same BTC
///        deposit and posts NO separate margin: a short product funds its fall short by selling
///        that BTC into USDC (V6-M-2). Income is realized per cycle — a full exit in the 20-day
///        post-halving free window pays the fee and realizes the perp PnL that navWad excludes
///        (B3), then re-deposits. StructuralLeverage IS wired in the engine, but this run
///        samples the anchor windows daily as the keeper does, so the confirmed-anchor
///        structural path is what these figures measure.
///        Run: `forge test --match-path 'test/backtest/BacktestReal.t.sol' -vv`
contract BacktestRealTest is VenueTestBase {
    uint32 constant SRC_EID = 30_101;
    bytes32 constant SRC_SENDER = bytes32(uint256(1));

    uint256[4] HALVING_HEIGHT = [uint256(210_000), 420_000, 630_000, 840_000];
    uint256[4] HALVING_TS = [uint256(1_354_116_278), 1_468_082_773, 1_589_225_023, 1_713_571_767];

    MockLzEndpoint endpoint;
    HalvingOracle oracle;
    B4Factory factory;
    B4Pool pool;
    StrategyMini mini;
    address user = address(0xA11CE);

    uint256[] ts; // absolute unix seconds
    int256[] px; // WAD dollars

    function setUp() public {
        vm.warp(HALVING_TS[0]);
        setUpVenue();
        mini = new StrategyMini();
        _loadPrices();
    }

    /// Fresh oracle + factory + pool, so each product's run gets an ISOLATED interval
    /// timeline (B4Pool's interval materialization/lock state is global to the pool — reusing
    /// one pool across sequential product runs over the same historical dates collides with
    /// `AlreadyLocked`). The venue (hub/tokens) is fine to share: price-setting is idempotent.
    function _freshProtocol() internal {
        vm.warp(HALVING_TS[0]); // rewind so the fresh pool's lastPointTime starts at halving 0
        endpoint = new MockLzEndpoint();
        oracle = new HalvingOracle(
            address(endpoint), SRC_EID, SRC_SENDER, HALVING_HEIGHT[0], address(this)
        );
        _acceptHalving(HALVING_HEIGHT[0], HALVING_TS[0]);
        address impl =
            address(new B4Vault(address(new B4VaultOps()), address(new B4VaultRecovery())));
        factory = new B4Factory(address(oracle), usdcDescriptor(), impl, address(poolDeployer));
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = ubtcDescriptor();
        pool = B4Pool(factory.createPool(dirs));
    }

    // ------------------------------------------------------------------ data loading

    function _loadPrices() internal {
        string memory path = string.concat(vm.projectRoot(), "/data/btcusd_daily.csv");
        vm.readLine(path); // header
        string memory line;
        while (bytes((line = vm.readLine(path))).length != 0) {
            string[] memory f = vm.split(line, ",");
            ts.push(_dateToTs(f[0]));
            px.push(int256(vm.parseUint(_toWadDecimal(f[4]))));
        }
    }

    function _dateToTs(string memory d) internal pure returns (uint256) {
        bytes memory b = bytes(d);
        uint256 y = _num(b, 0, 4);
        uint256 m = _num(b, 5, 7);
        uint256 day = _num(b, 8, 10);
        uint256 yy = m <= 2 ? y - 1 : y;
        uint256 era = yy / 400;
        uint256 yoe = yy - era * 400;
        uint256 mp = (m + 9) % 12;
        uint256 doy = (153 * mp + 2) / 5 + day - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return (era * 146097 + doe - 719468) * 86400;
    }

    function _num(bytes memory b, uint256 s, uint256 e) internal pure returns (uint256 v) {
        for (uint256 i = s; i < e; i++) {
            v = v * 10 + (uint8(b[i]) - 48);
        }
    }

    function _toWadDecimal(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 dot = b.length;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ".") {
                dot = i;
                break;
            }
        }
        bytes memory out = new bytes(dot + 18);
        for (uint256 i = 0; i < dot; i++) {
            out[i] = b[i];
        }
        for (uint256 i = 0; i < 18; i++) {
            uint256 src = dot + 1 + i;
            out[dot + i] = src < b.length ? b[src] : bytes1("0");
        }
        return string(out);
    }

    /// Price on/after `t` (step function on daily closes).
    function _pxAt(uint256 t) internal view returns (int256) {
        for (uint256 i = 0; i < ts.length; i++) {
            if (ts[i] >= t) return px[i];
        }
        return px[px.length - 1];
    }

    // ------------------------------------------------------------------ venue plumbing

    function _acceptHalving(uint256 height, uint256 tsAt) internal {
        bytes memory h = new bytes(80);
        h[68] = bytes1(uint8(tsAt));
        h[69] = bytes1(uint8(tsAt >> 8));
        h[70] = bytes1(uint8(tsAt >> 16));
        h[71] = bytes1(uint8(tsAt >> 24));
        vm.prank(address(endpoint));
        oracle.lzReceive(
            Origin(SRC_EID, SRC_SENDER, 1), bytes32(0), abi.encode(height, h), address(0), ""
        );
    }

    function _setPx(uint256 t) internal {
        uint256 pxWad = uint256(_pxAt(t));
        hub.setSpotPx(SPOT_MKT, uint64(pxWad / 1e14)); // WAD $ -> $ * 1e4
        hub.setMarkPx(PERP_MKT, uint64(pxWad / 1e16)); // WAD $ -> $ * 1e2
        hub.setOraclePx(PERP_MKT, uint64(pxWad / 1e16));
    }

    function _crankUntilIdle(B4Vault v, uint256 maxSteps) internal returns (uint256 steps) {
        for (steps = 0; steps < maxSteps; steps++) {
            if (!v.crank()) break;
        }
    }

    function _settleAt(B4Vault v, uint256 t) internal {
        vm.warp(t);
        _setPx(t);
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);
        v.settle(id);
    }

    // ================================================================= short-leg diagnostic

    /// Pro funded with BTC ONLY must still open its fall short — the proceeds of selling the
    /// spot BTC fund the margin (V6-M-2 fix). Reads the raw perp position across the cycle-1
    /// fall. Also documents that NAV excludes unrealized PnL (B3), so the short's gain is
    /// invisible while open and only lands when it is closed.
    function test_real_pro_short_opens() public {
        _freshProtocol();
        StrategyPro sp = new StrategyPro();
        // Fund with BTC ONLY — no dedicated margin. The short must be funded by selling spot.
        B4Vault v = _deployAndFund(address(sp), address(0x0FE0), 0);

        uint256 s1 = HALVING_TS[0] + Calendar.P - Calendar.H;
        uint256 pTop = HALVING_TS[0] + Calendar.P;
        uint256 mid = HALVING_TS[0] + (Calendar.P + Calendar.T) / 2;
        uint256 pBot = HALVING_TS[0] + Calendar.T;

        _settleAt(v, s1);

        vm.warp(pTop);
        _setPx(pTop);
        _crankUntilIdle(v, 40);
        CoreTypes.Position memory p1 = _readPos(address(v));
        console.log("at P (fall entry): perp szi (raw int64):");
        console.logInt(int256(p1.szi));
        console.log("  navWad:", v.navWad());
        console.log("  spot BTC px at P (wad):", uint256(_pxAt(pTop)));

        vm.warp(mid);
        _setPx(mid);
        uint256 navBeforeGain = v.navWad();
        _crankUntilIdle(v, 40);
        CoreTypes.Position memory p2 = _readPos(address(v));
        console.log("mid-fall: perp szi:");
        console.logInt(int256(p2.szi));
        console.log("  navWad (B3: unrealized excluded):", v.navWad());
        console.log("  spot BTC px mid (wad):", uint256(_pxAt(mid)));

        // Finding (1) — V6-M-2 fix: with a BTC-ONLY deposit the short still opens (szi < 0),
        // funded by selling the spot BTC into USDC and reclassifying it as perp margin.
        assertLt(p1.szi, int64(0), "short opens from BTC-only funding (V6-M-2)");
        assertLt(p2.szi, int64(0), "short still open mid-fall");
        // Finding (2): B3 — while the short is open, its unrealized gain is NOT in NAV, even as
        // BTC falls ~40% from P to mid-fall. NAV moves by less than 0.1% (fees/dust only).
        uint256 navMid = v.navWad();
        uint256 drift = navMid > navBeforeGain ? navMid - navBeforeGain : navBeforeGain - navMid;
        assertLt(drift, navBeforeGain / 1000, "open short's gain is excluded from NAV (B3)");
    }

    function _readPos(address vault) internal view returns (CoreTypes.Position memory pos) {
        (bool ok, bytes memory ret) =
            CoreTypes.PRECOMPILE_POSITION.staticcall(abi.encode(vault, uint16(PERP_MKT)));
        if (ok && ret.length >= 32) pos = abi.decode(ret, (CoreTypes.Position));
    }

    /// Diagnostic: where does Pro Max's perp actually engage across cycle 1, BTC-only? Logs the
    /// raw perp szi (>0 long, <0 short, 0 none) at growth-mid, fall entry/mid, recovery-mid.
    function test_real_promax_leverage_by_zone() public {
        _freshProtocol();
        B4Vault v = _deployAndFund(address(new StrategyProMax()), address(0x0FE0), 0);
        uint256 h = HALVING_TS[0];
        uint256[4] memory pts = [
            h + Calendar.P / 2, // growth-mid
            h + Calendar.P + 5 days, // just into the fall
            h + (Calendar.P + Calendar.T) / 2, // fall-mid
            h + Calendar.T + (HALVING_TS[1] - h - Calendar.T) / 2 // recovery-mid
        ];
        string[4] memory names = ["growth-mid ", "fall-entry ", "fall-mid   ", "recovery   "];
        console.log(
            "Pro Max (phi long / phi short) cycle 1, BTC-only. perp szi: >0 long, <0 short:"
        );
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(pts[i]);
            _setPx(pts[i]);
            _crankUntilIdle(v, 40);
            console.log(
                string.concat("  ", names[i], " px=$", vm.toString(uint256(_pxAt(pts[i])) / 1e18))
            );
            console.log("    perp szi:");
            int64 szi = _readPos(address(v)).szi;
            console.logInt(int256(szi));
            // Not just a printf. `names` is [growth-mid, fall-entry, fall-mid, recovery-mid],
            // and the sign of the perp at each is the whole claim the product makes: Pro Max is
            // long through growth and short through the fall. A diagnostic nobody asserts is a
            // diagnostic that silently stops reporting what it was written to show — this file
            // already carried one for a question that had been answered, and it survived because
            // it always passed.
            if (i == 0) assertGt(szi, 0, "growth-mid: Pro Max must be LONG");
            if (i == 1 || i == 2) assertLt(szi, 0, "fall: Pro Max must be SHORT");
        }
    }

    // ================================================================= full multi-cycle run

    struct CycleRow {
        int256 startNav;
        int256 endNav;
        int256 low; // worst nav seen this cycle
        int256 peak; // running peak this cycle (for maxDD)
        int256 maxDDWad; // worst peak-to-trough this cycle, WAD fraction
        uint256 ddDay; // day-of-cycle on which that worst drawdown was set
    }

    function _deployAndFund(address strategy, address operator, uint256 usdcMargin6)
        internal
        returns (B4Vault v)
    {
        vm.prank(user);
        v = B4Vault(
            factory.createVault(
                address(pool),
                CoreTypes.descriptorHash(ubtcDescriptor()),
                strategy,
                1e18,
                100,
                B4VaultStorage.FeeRoute({
                    operator: operator, operatorBps: 3819, referrer: address(0), referrerBps: 0
                })
            )
        );
        // Fund with BTC. Since V6-M-2 is fixed, a short product funds its perp margin by selling
        // that BTC (the sold USDC reclassifies from the rotation bucket to margin), so no
        // separate USDC deposit is required — `usdcMargin6` is 0 for every product now, retained
        // only so the short-open diagnostic can still exercise the pre-funded path. $1,000 base
        // (small enough that even the most-leveraged product's ~10^6x compounded NAV stays
        // inside the MockCore uint64 perp accounting; multiples are scale-invariant).
        _setPx(HALVING_TS[0]);
        uint256 entryPx = uint256(_pxAt(HALVING_TS[0]));
        uint256 dirAmount = (1_000e18 * 1e18 / entryPx) / 1e10;
        ubtc.mint(user, dirAmount);
        vm.startPrank(user);
        ubtc.approve(address(v), dirAmount);
        if (usdcMargin6 > 0) {
            usdc.mint(user, usdcMargin6);
            usdc.approve(address(v), usdcMargin6);
        }
        v.deposit(dirAmount, usdcMargin6);
        vm.stopPrank();
    }

    /// One cycle: daily NAV marks for drawdown, plus cranks at each calendar transition and
    /// the two real settlements. The short/leveraged-perp leg is opened at the P crank and
    /// CLOSED at the recovery crank (a few days past T) so its realized PnL enters NAV before
    /// the cycle-end read — NAV excludes unrealized PnL by design (engine B3), so a still-open
    /// short would be invisible. Split out from `_runProduct` to keep the stack shallow.
    function _runCycleDaily(B4Vault v, uint256 cycleStart, uint256 readPoint)
        internal
        returns (CycleRow memory r)
    {
        // The opposite-sign targets ramp THROUGH ZERO exactly at the settlement points P-H
        // and T+H (Calendar.targetAt): the perp is flat there. So at each settlement we crank
        // to reach that flat target FIRST, then settle (settle reverts WrongSignPerp on an
        // open wrong-sign perp). The full short opens at P (Fall) and the recovery long/short
        // reopens after T+W (OpeningGrowth complete).
        uint256 s1 = cycleStart + Calendar.P - Calendar.H;
        uint256 pTop = cycleStart + Calendar.P;
        uint256 s2 = cycleStart + Calendar.T + Calendar.H;
        uint256 recovOpen = cycleStart + Calendar.T + Calendar.W;

        r.startNav = int256(v.navWad());
        r.peak = r.startNav;
        r.low = r.startNav;

        bool[5] memory done; // [start, s1, pTop(open short), s2, recovOpen]
        for (uint256 i = 0; i < ts.length; i++) {
            if (ts[i] < cycleStart || ts[i] > readPoint) continue;
            vm.warp(ts[i]);
            _setPx(ts[i]);
            // Sample the anchor windows exactly as the permissionless keeper does. Without this
            // the pool's getters withhold every anchor and the engine correctly degrades to the
            // flat-phi genesis fallback — which is what this benchmark used to measure. Sampling
            // makes it measure the SHIPPED structural product instead.
            try pool.sampleAnchor(1) {} catch {} // index 0 is settlement; reverts outside a window
            if (!done[0]) {
                _crankUntilIdle(v, 40); // open the growth position for this epoch
                done[0] = true;
            }
            if (!done[1] && ts[i] >= s1) {
                _crankUntilIdle(v, 40); // flatten to the zero-crossing target, then settle
                _settleAt(v, ts[i]);
                done[1] = true;
            }
            if (!done[2] && ts[i] >= pTop) {
                _crankUntilIdle(v, 40); // open the full fall position (short / USDC)
                done[2] = true;
            }
            if (!done[3] && ts[i] >= s2) {
                _crankUntilIdle(v, 40); // close the short to the zero-crossing, then settle
                _settleAt(v, ts[i]);
                done[3] = true;
            }
            if (!done[4] && ts[i] >= recovOpen) {
                _crankUntilIdle(v, 40); // reopen the recovery long for the bull run to next halving
                done[4] = true;
            }
            _trackDD(r, _equityWad(v), (ts[i] - cycleStart) / 86400);
        }
    }

    /// Mark-to-market equity = `navWad()` + unrealized perp PnL.
    ///
    /// Drawdown MUST NOT be measured on `navWad` alone. NAV is recorded value only — it books the
    /// perp at `perpMargin6`, its margin principal, and excludes unrealized PnL by invariant B3.
    /// That is correct for settlement (it is what stops unearned value entering the ledger), and
    /// it makes NAV useless as a risk gauge for a LEVERAGED product: since the pure-perp change,
    /// Pro Max holds `spot = 0`, so its entire position is the one leg NAV cannot see. Measured on
    /// NAV its drawdown is ~0 no matter what the position does — the published table read
    /// "0.00 %", which is the blindness of the instrument, not the safety of the product.
    ///
    /// The mock maintains `entryNtl` as `Σ fillSz·px`, so the position's current notional at the
    /// mark is `|szi|·markPx` in those same 1e6 units and the difference is the unrealized PnL.
    function _equityWad(B4Vault v) internal view returns (int256) {
        CoreTypes.Position memory p = _readPos(address(v));
        int256 nav = int256(v.navWad());
        if (p.szi == 0) return nav;
        uint64 absSz = uint64(p.szi > 0 ? p.szi : -p.szi);
        int256 markNtl = int256(uint256(absSz) * uint256(hub.markPxOf(PERP_MKT)));
        int256 uPnL6 = p.szi > 0
            ? markNtl - int256(uint256(p.entryNtl))
            : int256(uint256(p.entryNtl)) - markNtl;
        return nav + uPnL6 * int256(10 ** (18 - uint256(CoreTypes.PERP_USD_DECIMALS)));
    }

    /// The 3rd zone: in the post-halving free-exit window, fully exit (realizing the perp PnL
    /// that navWad excludes by B3, paying the perf fee, no penalty), measure the realized value
    /// as the OWNER's balance delta (the `user` address is shared across product runs, so an
    /// absolute read would double-count), then re-deposit it for the next cycle. Returns the
    /// realized value in WAD dollars — the true per-cycle income.
    function _exitRealizeRedeposit(B4Vault v) internal returns (int256 realizedWad) {
        uint256 px = uint256(_pxAt(block.timestamp));
        uint256 btcBefore = ubtc.balanceOf(user);
        uint256 usdcBefore = usdc.balanceOf(user);

        vm.prank(user);
        v.initiateExit(1e18);
        _crankUntilIdle(v, 80);
        require(v.exitShareWad() == 0, "exit did not finalize");

        uint256 btcGained = ubtc.balanceOf(user) - btcBefore; // 8-dec
        uint256 usdcGained = usdc.balanceOf(user) - usdcBefore; // 6-dec
        realizedWad = int256(btcGained * 1e10 * px / 1e18 + usdcGained * 1e12); // WAD BTC*px + WAD USDC

        // Re-deposit the realized funds for the next cycle (post-halving window is deposit-open).
        vm.startPrank(user);
        if (btcGained > 0) ubtc.approve(address(v), btcGained);
        if (usdcGained > 0) usdc.approve(address(v), usdcGained);
        v.deposit(btcGained, usdcGained);
        vm.stopPrank();
    }

    function _trackDD(CycleRow memory r, int256 nav, uint256 dayOfCycle) internal pure {
        if (nav > r.peak) r.peak = nav;
        if (nav < r.low) r.low = nav;
        int256 dd = r.peak <= 0 ? int256(1e18) : (r.peak - nav) * 1e18 / r.peak;
        if (dd > r.maxDDWad) {
            r.maxDDWad = dd;
            r.ddDay = dayOfCycle;
        }
    }

    /// `retBase` = the denominator for the return multiple. For cycle 1 it is the $100k BTC
    /// base (so Pro/Pro Max's posted margin is NOT credited into the multiple — reported
    /// separately); for later cycles it is the prior cycle's end NAV (a clean chained ratio;
    /// the one-time margin is negligible against a multi-million NAV by then).
    function _logCycle(uint256 c, CycleRow memory r, int256 retBase) internal pure {
        console.log(string.concat("  cycle ", vm.toString(c + 1), ":"));
        console.log("    return x1000 (BTC base):", uint256(r.endNav * 1000 / retBase));
        console.log("    maxDD x10000 (bps):", uint256(r.maxDDWad * 10000 / 1e18));
        int256 vsDep = (r.low - r.startNav) * 10000 / r.startNav;
        console.log("    worst vs cycle-start x10000 (bps, signed):", vsDep);
    }

    /// Run one product across all 4 real halving epochs (3 complete + cycle 4 in progress,
    /// bounded by the last available price date). Logs per-cycle return/maxDD/vs-dep and the
    /// compounded final multiple, sourced entirely from `v.navWad()` — no parallel model.
    struct ProductResult {
        uint256 compoundedX1000; // final NAV / $100k BTC base, x1000
        uint256 c1MaxDDbps; // cycle-1 worst drawdown, bps
        bool anyDDInFall; // did ANY cycle set its worst drawdown inside the fall zone?
    }

    function _runProduct(
        string memory label,
        address strategy,
        address operator,
        uint256 usdcMargin6
    ) internal returns (ProductResult memory res) {
        _freshProtocol();
        B4Vault v = _deployAndFund(strategy, operator, usdcMargin6);
        console.log("");
        console.log(label);
        int256 btcBase = int256(1_000e18); // the BTC deposit; the return multiple is on this
        if (usdcMargin6 > 0) {
            console.log("  (also posts USDC margin, $k):", usdcMargin6 / 1e6);
        }

        uint256 lastAvail = ts[ts.length - 1];
        int256 prevEnd = btcBase;

        for (uint256 c = 0; c < 4; c++) {
            uint256 cycleStart = HALVING_TS[c];
            uint256 cycleEndFull = c + 1 < 4 ? HALVING_TS[c + 1] : lastAvail;
            uint256 readPoint = cycleEndFull < lastAvail ? cycleEndFull : lastAvail;

            CycleRow memory r = _runCycleDaily(v, cycleStart, readPoint);

            if (readPoint == cycleEndFull && c + 1 < 4) {
                vm.warp(HALVING_TS[c + 1]);
                _acceptHalving(HALVING_HEIGHT[c + 1], HALVING_TS[c + 1]);
                _setPx(HALVING_TS[c + 1]);
                // 3rd zone: the post-halving 20-day window is a FREE exit. Realize per-cycle
                // income there — a full exit pays the performance fee (no penalty) and, crucially
                // for Pro/Pro Max, REALIZES the recovery perp-leg PnL that navWad excludes by
                // design (B3) — then re-deposit for the next cycle. This is "exit and pay per
                // cycle": the return is the realized, compounded, post-fee value.
                r.endNav = _exitRealizeRedeposit(v);
            } else {
                r.endNav = int256(v.navWad()); // cycle in progress: unrealized mark-to-market
            }
            _logCycle(c, r, c == 0 ? btcBase : prevEnd);
            prevEnd = r.endNav;
            if (c == 0) res.c1MaxDDbps = uint256(r.maxDDWad * 10000 / 1e18);
            // Which ZONE set the worst drawdown is the product claim itself — see the assertions.
            uint256 fallOpen = (Calendar.P - Calendar.H) / 1 days;
            uint256 fallClose = (Calendar.T + Calendar.H) / 1 days;
            if (r.ddDay >= fallOpen && r.ddDay <= fallClose) res.anyDDInFall = true;

            if (readPoint != cycleEndFull) {
                console.log("    (cycle in progress, stopped at last available price date)");
                break;
            }
        }

        int256 finalNav = int256(v.navWad());
        res.compoundedX1000 = uint256(finalNav * 1000 / btcBase);
        console.log("  COMPOUNDED return x1000 (BTC base):", res.compoundedX1000);
    }

    /// HODL baseline: raw BTC hold, no vault, no fee — the BTC price ratio at the exact halving
    /// timestamps the benchmark reads, per cycle and compounded over the three complete cycles.
    function _logHodl() internal view {
        console.log("=== HODL (raw BTC hold, no vault) ===");
        int256 comp = 1000;
        for (uint256 c = 0; c < 4; c++) {
            uint256 endTs = c + 1 < 4 ? HALVING_TS[c + 1] : ts[ts.length - 1];
            int256 x1000 = _pxAt(endTs) * 1000 / _pxAt(HALVING_TS[c]);
            comp = comp * x1000 / 1000;
            console.log(string.concat("  cycle ", vm.toString(c + 1), " return x1000:"));
            console.logInt(x1000);
        }
        console.log("  COMPOUNDED HODL x1000:");
        console.logInt(comp);
    }

    function test_real_all_products() public {
        _logHodl();
        address op = address(0x0FE0);
        // All products funded with BTC ONLY (V6-M-2 fixed): Pro/Pro Max fund their fall
        // short by selling the spot BTC into USDC — no separate margin deposit needed.
        ProductResult memory mn = _runProduct("=== Mini ===", address(new StrategyMini()), op, 0);
        ProductResult memory b = _runProduct("=== B4 ===", address(new StrategyB4()), op, 0);
        ProductResult memory pr = _runProduct("=== Pro ===", address(new StrategyPro()), op, 0);
        ProductResult memory pm =
            _runProduct("=== Pro Max ===", address(new StrategyProMax()), op, 0);

        // The benchmark is a pinned claim, sourced entirely from navWad() on the real engine.
        // Ordering by compounded BTC-base multiple: Pro Max > Pro > B4 > Mini.
        assertGt(b.compoundedX1000, mn.compoundedX1000, "B4 > Mini (steps aside in the fall)");
        assertGt(pr.compoundedX1000, b.compoundedX1000, "Pro > B4 (short adds fall alpha)");
        assertGt(pm.compoundedX1000, pr.compoundedX1000, "Pro Max > Pro (leverage)");
        // Mini tracks HODL-like spot exposure, so it keeps HODL-like drawdown; B4/Pro/Pro Max
        // step out of the market during the bear and draw down materially less.
        assertGt(mn.c1MaxDDbps, b.c1MaxDDbps + 500, "Mini draws down >5pp more than B4 in cycle 1");
        assertGt(mn.c1MaxDDbps, pm.c1MaxDDbps + 500, "Mini draws down >5pp more than Pro Max");
        // A leveraged product CANNOT have a near-zero drawdown, and for a long time this table
        // published one: measured on `navWad` alone, Pro Max read 0.00 %, because NAV excludes
        // unrealized perp PnL (B3) and pure-perp Pro Max holds nothing else. This floor is what
        // makes that unmeasurable-again: revert `_equityWad` to plain NAV and it fails at ~0.
        assertGt(
            pm.c1MaxDDbps, 5000, "Pro Max must show a real drawdown (>50pp); NAV alone reads ~0"
        );
        // THE product claim, and the only drawdown statement worth pinning: a rotating product
        // never takes its worst drawdown in the fall. Mini holds spot through the bear and sets
        // its worst drawdown INSIDE the fall zone in every cycle; B4/Pro/Pro Max are in USDC or
        // short there, so their worst drawdown always lands in growth or recovery — ordinary
        // intra-bull volatility that gives back accumulated profit, not the bear that takes
        // principal. Asserting the ZONE, not a basis-point ordering: the products are all ~1x
        // long in growth, so which of them is a point or two deeper on a given crash is
        // composition noise and pinning it would only encode that noise as a claim.
        assertTrue(mn.anyDDInFall, "Mini must take its worst drawdown IN the fall (it holds)");
        assertFalse(b.anyDDInFall, "B4 must never take its worst drawdown in the fall");
        assertFalse(pr.anyDDInFall, "Pro must never take its worst drawdown in the fall");
        assertFalse(pm.anyDDInFall, "Pro Max must never take its worst drawdown in the fall");
        // Sanity: Mini is a small haircut under raw HODL (operator fee only), not a multiple.
        assertGt(mn.compoundedX1000, 4_000_000, "Mini compounds ~HODL (>4000x over 3 cycles)");
        assertLt(mn.compoundedX1000, 5_500_000, "Mini below raw HODL (fee drag), not above");
    }
}
