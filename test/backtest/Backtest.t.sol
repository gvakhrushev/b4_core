// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";

/// @title Historical demo — the calendar + structural leverage over real BTC data.
/// @notice Models the SHIPPED mechanic: a position is sized once when the calendar rotates
///         and then **held** (fixed units, not re-balanced to a moving NAV ratio), and a
///         leveraged long's leverage comes from `StructuralLeverage` — the protocol's own
///         function — bounded by the cycle's confirmed structural lows.
///
///         Held-units matters: within a regime, equity is **linear** in price
///         (`eq · (1 + dir·L·(px/entry − 1))`), not daily-compounded, so there is no
///         volatility drag and no explosive compounding — the numbers are what fixed
///         leverage actually returns over a move.
///
///         **This is an illustration, not evidence of edge and not a forecast.** Three
///         completed cycles is not a sample and never can be (~32 halvings will ever occur).
///         It assumes entry at the halving, perfect calendar timing, and infinite depth at
///         any size; it omits slippage, market impact, trading fees, and the async execution
///         delay. Leveraged multiples are arithmetic, not outcomes. Read the `vs deposit`
///         column, not the return column: the structural stop bounds the long's downside,
///         but the short side and interim dips are real risk.
///
///         Run: `forge test --match-path 'test/backtest/*' -vv`
contract BacktestTest is Test {
    int256 constant WAD = 1e18;
    int256 constant DAILY_FUNDING = 273972602739726; // 10%/yr ÷ 365, WAD (assumption)
    // Operator performance fee that actually leaves a holder's equity. FEE_F (4.5%) is a
    // *virtual* fee on profit; only the operator's route share (≤ 38.19% of it, B4VaultOps)
    // is ever paid out in kind, so a holder loses ≤ ~1.72% of profit — the remaining FEE_F is
    // pool-weight accounting and never leaves NAV. (The old demo removed the full 4.5% three
    // times on *cumulative* profit, which is why Mini sagged below plain hold — a modelling
    // bug, not a real drag.)
    int256 constant OP_FEE = int256(Phi.FEE_F) * 3819 / 10000; // ≈ 1.72% of profit
    // Pool income to a stayer per cycle — the protocol's core value capture. 20% of the
    // cohort exits through the EXIT_Q = 11.8% (= φ⁻³/2) penalty door; the forfeited penalty is
    // redistributed to the ~80% who stay ⇒ +0.20·q/0.80 = 0.25·q ≈ +2.95%/cycle. Behavioural.
    int256 constant POOL_U = int256(Phi.EXIT_Q) / 4; // 0.25 · q ≈ 2.95%

    uint256[4] HALVINGS = [uint256(1354116278), 1468082773, 1589225023, 1713571767];

    struct Product {
        string name;
        int256 growth;
        int256 fall;
    }

    uint256[] ts;
    int256[] px;

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

    // ------------------------------------------------------------------ helpers

    /// Price on/after `t` (step function on daily closes).
    function _pxAt(uint256 t) internal view returns (int256) {
        for (uint256 i = 0; i < ts.length; i++) {
            if (ts[i] >= t) return px[i];
        }
        return px[px.length - 1];
    }

    /// Minimum close in `[a, b]`.
    function _windowMin(uint256 a, uint256 b) internal view returns (int256 m) {
        m = type(int256).max;
        for (uint256 i = 0; i < ts.length; i++) {
            if (ts[i] >= a && ts[i] <= b && px[i] < m) m = px[i];
        }
        if (m == type(int256).max) m = 0;
    }

    // ------------------------------------------------------------------ the run

    struct Seg {
        uint256 a;
        uint256 b;
        int256 target; // signed regime exposure over [a,b]
        bool longLeg; // structural leverage applies (long, g>1)
    }

    struct Acc {
        int256 eq; // equity, WAD (1.0x = deposit)
        int256 peak;
        int256 low;
        int256 maxDD;
        int256 hw; // high-water mark for the operator performance fee
    }

    function test_backtest_products() public {
        _loadPrices();
        assertGt(px.length, 4000, "dataset loaded");

        Product[4] memory prods = [
            Product("Mini   ", WAD, WAD),
            Product("B4     ", WAD, int256(0)),
            Product("Pro    ", WAD, -int256(Phi.INV_PHI)),
            Product("Pro Max", int256(Phi.PHI), -int256(Phi.PHI))
        ];

        console.log("");
        console.log("=== B4 over real BTC closes, PER CYCLE (held-units + structural leverage) ===");
        console.log("Sized once per regime and HELD: equity is linear in price, no rebalance drag.");
        console.log("Pro Max leverage = StructuralLeverage, bounded by the cycle's confirmed lows.");
        console.log("Read the three benchmarks together:");
        console.log("  - HODL: raw buy & hold BTC, no pool, no protocol - the thing to beat.");
        console.log("  - max DD / DD-HODL: our drawdown, and how much LESS it is than holding.");
        console.log("    B4/Pro sit in USDC through the fall, so their drawdown is intra-bull");
        console.log("    only; HODL (and Mini) eat the full top-to-bottom cycle bear.");
        console.log("  - Pool income: 20% of exits pay the q=11.8% penalty to the stayers,");
        console.log("    +2.95%/cycle to everyone who stays (shown per cycle below).");
        console.log(
            "Read 'vs dep' (worst value below deposit) for the real downside, not 'return'."
        );
        console.log("");

        for (uint256 c = 0; c < 4; c++) {
            _runCycle(prods, c);
        }

        console.log("Pool income is the protocol's core value capture: every stayer is paid by the");
        console.log(
            "penalised leavers, +2.95%/cycle, compounding if held across cycles. Assumptions:"
        );
        console.log(
            "funding 10%/yr on the abs perp leg; operator fee <=1.72% of profit (max route);"
        );
        console.log(
            "20% penalised exits/cycle. NOT modelled: slippage, market impact, trading fees,"
        );
        console.log(
            "async delay. Multiples are arithmetic under perfect timing. Cycle 4 in progress."
        );
    }

    // Per-cycle context, bundled so the per-product/-regime calls stay under the stack limit.
    struct Cyc {
        uint256 frm; // cycle start (halving)
        uint256 pTop; // pivot P (top): long → fall
        uint256 pBot; // pivot T (bottom): fall → long
        uint256 nxt; // cycle end (next halving, or dataset end)
        int256 floor_; // delta anchor (prev cycle's bear low)
        int256 cap_; // stop ceiling (this cycle's post-halving low)
        int256 holdDD; // HODL max drawdown, for the DD-HODL column
    }

    function _runCycle(Product[4] memory prods, uint256 c) internal view {
        Cyc memory k;
        k.frm = HALVINGS[c];
        k.nxt = c + 1 < 4 ? HALVINGS[c + 1] : ts[ts.length - 1];
        // Anchors: floor = previous cycle's 62-window bottom; cap = this cycle's
        // post-halving-window low. Ratchet: at the halving the previous bottom is the
        // floor and the post-halving low is the cap (SPECIFICATION §7b).
        k.floor_ = c >= 1
            ? _windowMin(HALVINGS[c - 1] + Calendar.T, HALVINGS[c - 1] + Calendar.T + Calendar.W)
            : int256(0);
        k.cap_ = _windowMin(k.frm, k.frm + Calendar.W);
        // Three held regimes: long to the top (P), fall to the bottom (T), long again.
        k.pTop = _min(k.frm + Calendar.P, k.nxt);
        k.pBot = _min(k.frm + Calendar.T, k.nxt);

        console.log(
            string.concat(
                "--- cycle ",
                vm.toString(c + 1),
                ": ",
                _date(k.frm),
                " -> ",
                _date(k.nxt),
                c == 3 ? " (IN PROGRESS)" : ""
            )
        );
        // HODL benchmark first: raw buy & hold, no pool, no protocol - the thing to beat.
        int256 holdRet = (_pxAt(k.nxt) * WAD) / _pxAt(k.frm);
        k.holdDD = _holdDD(k.frm, k.nxt);
        console.log(
            string.concat(
                "    HODL benchmark: ", _x(holdRet), " return, ", _pct(k.holdDD), " max DD"
            )
        );
        console.log("    product |  return |  max DD | DD-HODL |  vs dep | entry L");

        // Mini has HODL exposure; Mini vs HODL isolates the pool income net of the fee.
        int256 miniRet = _logProduct(prods[0], false, k);
        _logProduct(prods[1], false, k);
        _logProduct(prods[2], false, k);
        _logProduct(prods[3], true, k);

        console.log(
            string.concat(
                "    Pool income to stayers: ",
                _pctSigned(POOL_U),
                "/cycle (20% exit x q=11.8%, redistributed) - included above"
            )
        );
        // Isolate the pool: Mini holds 1x long always (HODL exposure), so its edge over raw
        // HODL is exactly the pool income net of the operator fee.
        console.log(
            string.concat(
                "    -> Mini ", _x(miniRet), " vs HODL ", _x(holdRet), ": that gap IS the pool"
            )
        );
        console.log("");
    }

    /// Runs one product across the cycle's three held regimes, credits the per-cycle pool
    /// income, logs the row, and returns the product's final equity. Split out of `_runCycle`
    /// to keep each stack frame small (the per-regime call is stack-heavy on its own).
    function _logProduct(Product memory prod, bool isProMax, Cyc memory k)
        internal
        view
        returns (int256)
    {
        Acc memory a = Acc(WAD, WAD, WAD, 0, WAD);
        int256 entryL = _regime(a, k, k.frm, k.pTop, prod.growth); // regime 1: long
        _regime(a, k, k.pTop, k.pBot, prod.fall); // regime 2: fall
        _regime(a, k, k.pBot, k.nxt, prod.growth); // regime 3: long again
        // Pool income credited once per cycle: the 20% penalised exits, redistributed.
        a.eq += a.eq * POOL_U / WAD;

        console.log(
            string.concat(
                "    ",
                prod.name,
                " | ",
                _x(a.eq),
                " | ",
                _pct(a.maxDD),
                " | ",
                _ppSigned(a.maxDD - k.holdDD), // negative = LESS drawdown than holding
                " | ",
                _pctSigned(a.low - WAD),
                " | ",
                isProMax ? _x(entryL) : "  1.00x"
            )
        );
        return a.eq;
    }

    /// One held regime. Sizes leverage once at entry, holds fixed units (equity linear in
    /// price), tracks drawdown day-by-day, charges funding on the perp leg, and takes the
    /// operator performance fee on new profit at the regime's end (a settlement point). The
    /// pool income is credited once per cycle by the caller. Returns the entry leverage.
    struct Leg {
        int256 entry;
        int256 dir;
        int256 L;
        int256 perp;
        int256 eq0;
    }

    function _regime(Acc memory a, Cyc memory k, uint256 from_, uint256 to_, int256 target)
        internal
        view
        returns (int256)
    {
        if (to_ <= from_) return WAD;
        Leg memory g;
        g.entry = _pxAt(from_);
        g.dir = target >= 0 ? int256(1) : -int256(1);
        int256 mag = target >= 0 ? target : -target;
        if (target > WAD) {
            // Leveraged long: structural leverage, refusal (0) falls back to 1× spot.
            g.L = int256(
                StructuralLeverage.leverageWad(
                    uint256(g.entry), uint256(mag), uint256(k.floor_), uint256(k.cap_)
                )
            );
            if (g.L == 0) g.L = WAD;
        } else {
            // target ∈ {0 flat/USDC, 1 spot, −1/φ or −φ short}: exposure = |target|, no
            // structural amplification. A zero target is genuinely flat (exposure 0).
            g.L = mag;
        }
        g.perp = g.L > WAD ? g.L - WAD : (target < 0 ? mag : int256(0));
        g.eq0 = a.eq;

        for (uint256 i = 0; i < ts.length; i++) {
            if (ts[i] < from_ || ts[i] >= to_) continue;
            _mark(a, g, _value(g, px[i], (ts[i] - from_) / 86400));
        }
        a.eq = _value(g, _pxAt(to_), (to_ - from_) / 86400);
        // Operator performance fee on NEW profit above the high-water mark. Only the
        // operator's cut actually leaves NAV (OP_FEE ≈ 1.72% of profit); the rest of FEE_F is
        // virtual pool-weight accounting. High-water ⇒ never charged twice on the same gain.
        if (a.eq > a.hw) {
            a.eq -= (a.eq - a.hw) * OP_FEE / WAD;
            a.hw = a.eq;
        }
        return g.L;
    }

    /// Held-units equity at price `p`, `d` days into the leg (equity linear in price).
    function _value(Leg memory g, int256 p, uint256 d) internal pure returns (int256 v) {
        int256 ret = ((p - g.entry) * WAD) / g.entry;
        v = g.eq0 + (g.eq0 * g.dir * g.L / WAD) * ret / WAD;
        v -= g.eq0 * g.perp / WAD * DAILY_FUNDING / WAD * int256(d);
        if (v < 0) v = 0;
    }

    function _mark(
        Acc memory a,
        Leg memory,
        /*g*/
        int256 pos
    )
        internal
        pure
    {
        if (pos > a.peak) a.peak = pos;
        if (pos < a.low) a.low = pos;
        int256 dd = a.peak <= 0 ? WAD : ((a.peak - pos) * WAD) / a.peak;
        if (dd > a.maxDD) a.maxDD = dd;
    }

    function _holdDD(uint256 from_, uint256 to_) internal view returns (int256 maxDD) {
        int256 peak;
        for (uint256 i = 0; i < ts.length; i++) {
            if (ts[i] < from_ || ts[i] > to_) continue;
            if (px[i] > peak) peak = px[i];
            int256 dd = peak <= 0 ? int256(0) : ((peak - px[i]) * WAD) / peak;
            if (dd > maxDD) maxDD = dd;
        }
    }

    function _min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }

    // ------------------------------------------------------------------ formatting

    function _x(int256 v) internal pure returns (string memory) {
        if (v < 0) return "   <0x";
        uint256 w = uint256(v);
        return string.concat(_pad(vm.toString(w / 1e18)), ".", _two((w % 1e18) / 1e16), "x");
    }

    function _pct(int256 v) internal pure returns (string memory) {
        uint256 w = uint256(v < 0 ? -v : v);
        return string.concat(
            _pad3(vm.toString((w * 100) / 1e18)), ".", _two((w * 10000 / 1e18) % 100), "%"
        );
    }

    function _pctSigned(int256 v) internal pure returns (string memory) {
        return string.concat(v < 0 ? "-" : "+", _pct(v));
    }

    /// Signed percentage-point delta (one decimal), for "our drawdown minus HODL's". A
    /// negative value means the product drew down LESS than buy-and-hold.
    function _ppSigned(int256 v) internal pure returns (string memory) {
        uint256 w = uint256(v < 0 ? -v : v);
        return string.concat(
            v < 0 ? "-" : "+",
            _pad2(vm.toString((w * 100) / 1e18)),
            ".",
            vm.toString((w * 1000 / 1e18) % 10),
            "pp"
        );
    }

    function _pad2(string memory s) internal pure returns (string memory) {
        while (bytes(s).length < 2) {
            s = string.concat(" ", s);
        }
        return s;
    }

    function _two(uint256 v) internal pure returns (string memory) {
        return v < 10 ? string.concat("0", vm.toString(v)) : vm.toString(v);
    }

    function _pad(string memory s) internal pure returns (string memory) {
        while (bytes(s).length < 7) {
            s = string.concat(" ", s);
        }
        return s;
    }

    function _pad3(string memory s) internal pure returns (string memory) {
        while (bytes(s).length < 3) {
            s = string.concat(" ", s);
        }
        return s;
    }

    function _date(uint256 t) internal pure returns (string memory) {
        uint256 z = t / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 d = doy - (153 * mp + 2) / 5 + 1;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        return string.concat(vm.toString(m <= 2 ? y + 1 : y), "-", _two(m), "-", _two(d));
    }
}
