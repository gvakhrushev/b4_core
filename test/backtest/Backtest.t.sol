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
    int256 constant FEE_F = int256(Phi.FEE_F);
    int256 constant DAILY_FUNDING = 273972602739726; // 10%/yr ÷ 365, WAD (assumption)
    // Pool income (behavioural assumption): 20% of a cohort exits penalised per cycle ⇒
    // uplift = 0.2·q/0.8 = 0.25·q = 0.25 · EXIT_Q, credited in halves at the two settlements.
    int256 constant POOL_UPLIFT = 29508497187473712; // 0.25 · Phi.EXIT_Q, WAD

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
        console.log("=== B4 + structural leverage over real BTC closes, PER CYCLE ===");
        console.log("Sized once per regime and HELD (equity linear in price, no rebalance");
        console.log("drag). Pro Max leverage = StructuralLeverage, bounded by the cycle's");
        console.log("confirmed lows. Deposit assumed at the halving; each cycle at 1.0x.");
        console.log("READ 'vs dep' (worst value below the deposit), not 'return': the stop");
        console.log("bounds the long, the short and interim dips are real risk.");
        console.log("");

        for (uint256 c = 0; c < 4; c++) {
            _runCycle(prods, c);
        }

        console.log("Assumptions: funding 10%/yr on the abs perp leg; Pool income from 20%");
        console.log("of a cohort exiting penalised (behavioural guess). NOT modelled:");
        console.log("slippage, market impact, trading fees, async delay. Multiples are");
        console.log("arithmetic under perfect timing, not outcomes. Cycle 4 in progress.");
    }

    function _runCycle(Product[4] memory prods, uint256 c) internal {
        uint256 frm = HALVINGS[c];
        uint256 nxt = c + 1 < 4 ? HALVINGS[c + 1] : ts[ts.length - 1];
        // Anchors: floor = previous cycle's 62-window bottom; cap = this cycle's
        // post-halving-window low. Ratchet: at the halving the previous bottom is the
        // floor and the post-halving low is the cap (SPECIFICATION §7b).
        int256 floor_ = c >= 1
            ? _windowMin(HALVINGS[c - 1] + Calendar.T, HALVINGS[c - 1] + Calendar.T + Calendar.W)
            : int256(0);
        int256 cap_ = _windowMin(frm, frm + Calendar.W);

        // Three held regimes: long to the top (P), fall to the bottom (T), long again.
        uint256 pTop = _min(frm + Calendar.P, nxt);
        uint256 pBot = _min(frm + Calendar.T, nxt);

        console.log(
            string.concat(
                "--- cycle ",
                vm.toString(c + 1),
                ": ",
                _date(frm),
                " -> ",
                _date(nxt),
                c == 3 ? " (IN PROGRESS)" : ""
            )
        );
        console.log("    product |  return |  max DD | vs dep | entry L");

        for (uint256 p = 0; p < 4; p++) {
            Acc memory a = Acc(WAD, WAD, WAD, 0);
            int256 entryL;
            // regime 1: long [frm, pTop]
            entryL = _regime(a, prods[p], frm, pTop, prods[p].growth, floor_, cap_);
            // regime 2: fall [pTop, pBot]
            _regime(a, prods[p], pTop, pBot, prods[p].fall, floor_, cap_);
            // regime 3: long [pBot, nxt]
            _regime(a, prods[p], pBot, nxt, prods[p].growth, floor_, cap_);

            console.log(
                string.concat(
                    "    ",
                    prods[p].name,
                    " | ",
                    _x(a.eq),
                    " | ",
                    _pct(a.maxDD),
                    " | ",
                    _pctSigned(a.low - WAD),
                    " | ",
                    p == 3 ? _x(entryL) : "  1.00x"
                )
            );
        }
        console.log(
            string.concat(
                "    HODL    | ",
                _x((_pxAt(nxt) * WAD) / _pxAt(frm)),
                " | ",
                _pct(_holdDD(frm, nxt)),
                " |",
                "        |"
            )
        );
        console.log("");
    }

    /// One held regime. Sizes leverage once at entry, holds fixed units (equity linear in
    /// price), tracks drawdown day-by-day, charges funding on the perp leg, and takes the
    /// fee + Pool credit at the regime's end (a settlement point). Returns the entry leverage.
    struct Leg {
        int256 entry;
        int256 dir;
        int256 L;
        int256 perp;
        int256 eq0;
    }

    function _regime(
        Acc memory a,
        Product memory, /*prod*/
        uint256 from_,
        uint256 to_,
        int256 target,
        int256 floor_,
        int256 cap_
    ) internal view returns (int256) {
        if (to_ <= from_) return WAD;
        Leg memory g;
        g.entry = _pxAt(from_);
        g.dir = target >= 0 ? int256(1) : -int256(1);
        int256 mag = target >= 0 ? target : -target;
        if (target > WAD) {
            // Leveraged long: structural leverage, refusal (0) falls back to 1× spot.
            g.L = int256(
                StructuralLeverage.leverageWad(
                    uint256(g.entry), uint256(mag), uint256(floor_), uint256(cap_)
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
        if (a.eq > WAD) a.eq -= (a.eq - WAD) * FEE_F / WAD; // fee on profit at the rotation
        a.eq += a.eq * POOL_UPLIFT / WAD / 2; // Pool credit (two settlements per cycle)
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
