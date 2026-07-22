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

/// @title Historical benchmark on the REAL contracts. Every figure is `B4Vault.navWad()` read
///        off the actual B4Vault/B4VaultOps/B4Pool/HalvingOracle + reference strategies, cranked
///        and settled day-by-day across the real halving epochs exactly as the on-chain keeper
///        would — NOT a hand-rolled parallel equity model. Each vault starts from $100k BTC
///        ("BTC base"); Pro/Pro Max also post USDC margin for the fall short (a short cannot be
///        backed by spot-rotation USDC — it needs its own margin bucket). Returns are on the BTC
///        base so all four products are comparable; margin is reported separately. Sizing is the
///        shipped flat-`φ` (StructuralLeverage is designed but not wired). Run:
///        `forge test --match-path 'test/backtest/BacktestReal.t.sol' -vv`
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
            address(endpoint), SRC_EID, SRC_SENDER, HALVING_HEIGHT[0], HALVING_TS[0], address(this)
        );
        address impl = address(new B4Vault(address(new B4VaultOps())));
        factory = new B4Factory(address(oracle), usdcDescriptor(), impl);
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

    /// Does Pro's fall-regime short actually open, and does its close-PnL reach NAV? Reads the
    /// raw perp position (via the position precompile the vault uses) across the cycle-1 fall.
    /// Documents two engine facts the benchmark depends on: (1) a short needs its OWN USDC
    /// margin — spot-rotation USDC cannot back a perp; (2) NAV excludes unrealized PnL (B3), so
    /// the short's gain is invisible while open and only lands when it is closed.
    function test_real_pro_short_opens() public {
        _freshProtocol();
        StrategyPro sp = new StrategyPro();
        // Fund with BTC AND USDC margin (a short product needs margin capital).
        vm.prank(user);
        B4Vault v = B4Vault(
            factory.createVault(
                address(pool),
                CoreTypes.descriptorHash(ubtcDescriptor()),
                address(sp),
                1e18,
                100,
                B4VaultStorage.FeeRoute({
                    operator: address(0x0FE0),
                    operatorBps: 3819,
                    referrer: address(0),
                    referrerBps: 0
                })
            )
        );
        _setPx(HALVING_TS[0]);
        uint256 entryPx = uint256(_pxAt(HALVING_TS[0]));
        uint256 dirAmount = (100_000e18 * 1e18 / entryPx) / 1e10;
        ubtc.mint(user, dirAmount);
        usdc.mint(user, 50_000e6);
        vm.startPrank(user);
        ubtc.approve(address(v), dirAmount);
        usdc.approve(address(v), 50_000e6);
        v.deposit(dirAmount, 50_000e6);
        vm.stopPrank();

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

        // Finding (1): with USDC margin, the short DID open (szi < 0).
        assertLt(p1.szi, int64(0), "short opens once USDC margin is posted");
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

    // ================================================================= full multi-cycle run

    struct CycleRow {
        int256 startNav;
        int256 endNav;
        int256 low; // worst nav seen this cycle
        int256 peak; // running peak this cycle (for maxDD)
        int256 maxDDWad; // worst peak-to-trough this cycle, WAD fraction
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
        // BTC gives spot exposure (spot buys draw only on the rotation bucket, which the sold
        // BTC also feeds). USDC gives PERP MARGIN (a separate bucket the short/leveraged-long
        // leg draws on — spot-rotation USDC can NOT be used as margin). A short product must
        // therefore deposit its own margin; Mini/B4 pass 0. $100,000 of BTC + `usdcMargin6`.
        _setPx(HALVING_TS[0]);
        uint256 entryPx = uint256(_pxAt(HALVING_TS[0]));
        uint256 dirAmount = (100_000e18 * 1e18 / entryPx) / 1e10;
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
            _trackDD(r, int256(v.navWad()));
        }
    }

    function _trackDD(CycleRow memory r, int256 nav) internal pure {
        if (nav > r.peak) r.peak = nav;
        if (nav < r.low) r.low = nav;
        int256 dd = r.peak <= 0 ? int256(1e18) : (r.peak - nav) * 1e18 / r.peak;
        if (dd > r.maxDDWad) r.maxDDWad = dd;
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
        int256 btcBase = int256(100_000e18); // the $100k BTC sleeve; margin is separate capital
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
            }
            r.endNav = int256(v.navWad());
            _logCycle(c, r, c == 0 ? btcBase : prevEnd);
            prevEnd = r.endNav;
            if (c == 0) res.c1MaxDDbps = uint256(r.maxDDWad * 10000 / 1e18);

            if (readPoint != cycleEndFull) {
                console.log("    (cycle in progress, stopped at last available price date)");
                break;
            }
        }

        int256 finalNav = int256(v.navWad());
        res.compoundedX1000 = uint256(finalNav * 1000 / btcBase);
        console.log("  COMPOUNDED return x1000 (BTC base):", res.compoundedX1000);
    }

    function test_real_all_products() public {
        address op = address(0x0FE0);
        // Mini/B4 never short -> no margin. Pro/Pro Max deposit USDC margin for the fall short
        // (~15% and ~25% of the $100k BTC basis; Pro Max shorts phi x so needs more).
        ProductResult memory mn = _runProduct("=== Mini ===", address(new StrategyMini()), op, 0);
        ProductResult memory b = _runProduct("=== B4 ===", address(new StrategyB4()), op, 0);
        ProductResult memory pr =
            _runProduct("=== Pro ===", address(new StrategyPro()), op, 15_000e6);
        ProductResult memory pm =
            _runProduct("=== Pro Max ===", address(new StrategyProMax()), op, 25_000e6);

        // The benchmark is a pinned claim, sourced entirely from navWad() on the real engine.
        // Ordering by compounded BTC-base multiple: Pro Max > Pro > B4 > Mini.
        assertGt(b.compoundedX1000, mn.compoundedX1000, "B4 > Mini (steps aside in the fall)");
        assertGt(pr.compoundedX1000, b.compoundedX1000, "Pro > B4 (short adds fall alpha)");
        assertGt(pm.compoundedX1000, pr.compoundedX1000, "Pro Max > Pro (leverage)");
        // Mini tracks HODL-like spot exposure, so it keeps HODL-like drawdown; B4/Pro/Pro Max
        // step out of the market during the bear and draw down materially less.
        assertGt(mn.c1MaxDDbps, b.c1MaxDDbps + 500, "Mini draws down >5pp more than B4 in cycle 1");
        assertGt(mn.c1MaxDDbps, pm.c1MaxDDbps + 500, "Mini draws down >5pp more than Pro Max");
        // Sanity: Mini is a small haircut under raw HODL (operator fee only), not a multiple.
        assertGt(mn.compoundedX1000, 4_000_000, "Mini compounds ~HODL (>4000x over 3 cycles)");
        assertLt(mn.compoundedX1000, 5_500_000, "Mini below raw HODL (fee drag), not above");
    }
}
