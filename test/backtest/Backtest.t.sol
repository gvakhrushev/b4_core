// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";

/// @title Historical demo — the calendar (shipped) + structural leverage (designed) over BTC.
/// @notice One benchmark table per cycle, HODL as the baseline row. A position is sized once
///         when the calendar rotates and then HELD (fixed units, equity linear in price — no
///         rebalance drag).
///
///         **Two different maturity levels are shown together — read the disclaimer.** The
///         calendar rotation (Mini/B4/Pro, and Pro Max's spot leg) is the SHIPPED mechanic.
///         Pro Max's *leverage* column uses the DESIGNED structural-leverage mechanism
///         (`StructuralLeverage` library + `B4Pool` anchor ratchet are on-chain, but the
///         2026-07-21 audit found the vault-engine wiring unsafe — margin never realizes the
///         structural stop, and a held position re-levers at the halving — so it was reverted;
///         the engine currently sizes leveraged perps flat-φ, NOT structurally). The Pro Max
///         leverage figures therefore illustrate the design target, not today's shipped code.
///         See `REPORT.md` and `PROPOSAL-structural-leverage.md` for the wiring status.
///
///         **Illustration, not evidence of edge and not a forecast.** Three completed
///         cycles is not a sample and never can be. Assumes entry at the halving, perfect
///         calendar timing, infinite depth; omits slippage, market impact, trading fees
///         and async execution delay.
///
///         Run: `forge test --match-path 'test/backtest/*' -vv`
contract BacktestTest is Test {
    int256 constant WAD = 1e18;
    int256 constant DAILY_FUNDING = 273972602739726; // 10%/yr ÷ 365, WAD (assumption)
    // Operator performance fee — the only fee that actually leaves a holder's equity.
    // FEE_F (4.5%) is a *virtual* fee on profit; only the operator's route share (≤ 38.19%
    // of it, B4VaultOps) is ever paid out in kind, so a holder loses ≤ ~1.72% of profit.
    // The rest of FEE_F is pool-weight accounting and never leaves NAV.
    int256 constant OP_FEE = int256(Phi.FEE_F) * 3819 / 10000; // ≈ 1.72% of profit
    // Pool income to a stayer, per cycle: 20% of the cohort exits through the
    // EXIT_Q = 11.8% (= φ⁻³/2) penalty door; the forfeited penalty is redistributed to the
    // ~80% who stay ⇒ +0.20·q/0.80 = 0.25·q ≈ +2.95%/cycle. Behavioural assumption.
    int256 constant POOL_U = int256(Phi.EXIT_Q) / 4;

    uint256[4] HALVINGS = [uint256(1354116278), 1468082773, 1589225023, 1713571767];

    struct Product {
        string name;
        int256 growth;
        int256 fall;
    }

    /// Per-cycle geometry + anchors (a memory struct to keep _runCycle off the stack).
    struct Cyc {
        uint256 frm;
        uint256 nxt;
        uint256 pTop;
        uint256 pBot;
        int256 floor_;
        int256 capG; // growth-long cap = post-halving-window low
        int256 capR; // recovery-long cap = 62-window low (re-seeded at T)
    }

    /// One row of the benchmark table.
    struct Row {
        int256 ret; // final equity, WAD (1.0x = deposit)
        int256 maxDD; // worst peak-to-trough, WAD fraction
        uint256 ddAt; // when the worst drawdown printed
        int256 low; // worst equity ever seen (vs the 1.0x deposit)
        int256 pool; // pool income earned, in deposit units
        int256 lev; // entry leverage (0 ⇒ not applicable)
    }

    struct Acc {
        int256 eq;
        int256 peak;
        int256 low;
        int256 maxDD;
        uint256 ddAt;
        int256 hw; // high-water mark for the operator performance fee
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

    function test_backtest_products() public {
        _loadPrices();
        assertGt(px.length, 4000, "dataset loaded");

        Product[4] memory prods = [
            Product("Mini   ", WAD, WAD),
            Product("B4     ", WAD, int256(0)),
            Product("Pro    ", WAD, -WAD),
            Product("Pro Max", int256(Phi.PHI), -int256(Phi.PHI))
        ];

        console.log("");
        console.log(
            "================ B4 vs BUY & HOLD, real BTC closes, per cycle ================"
        );
        console.log("ret = final equity (deposit = 1.00x).  maxDD = worst peak-to-trough.");
        console.log("zone = calendar phase the worst drawdown landed in (GROWTH [0,P] / FALL");
        console.log("[P,T] / RECOV [T,end]).  vs dep = worst value ever, against the deposit.");
        console.log("pool = share of that strategy's profit paid by the penalised leavers.");
        console.log("");

        Row[5][4] memory all;
        for (uint256 c = 0; c < 4; c++) {
            all[c] = _runCycle(prods, c);
        }
        _summary(prods, all);
    }

    function _runCycle(Product[4] memory prods, uint256 c)
        internal
        view
        returns (Row[5] memory out)
    {
        // Anchors, as B4Pool.sampleAnchor's ratchet would actually hold them (audit C10):
        // floor = previous cycle's 62-window bottom (set by the halving flip, unchanged all
        // cycle). The cap differs by regime, because the 62-window at T re-seeds it:
        //  - growth long (opens at the halving): cap = this cycle's post-halving-window low;
        //  - recovery long (opens at T): cap = this cycle's 62-window low (freshly re-seeded).
        Cyc memory k;
        k.frm = HALVINGS[c];
        k.nxt = c + 1 < 4 ? HALVINGS[c + 1] : ts[ts.length - 1];
        k.floor_ = c >= 1
            ? _windowMin(HALVINGS[c - 1] + Calendar.T, HALVINGS[c - 1] + Calendar.T + Calendar.W)
            : int256(0);
        k.capG = _windowMin(k.frm, k.frm + Calendar.W);
        k.capR = _windowMin(k.frm + Calendar.T, k.frm + Calendar.T + Calendar.W);
        k.pTop = _min(k.frm + Calendar.P, k.nxt);
        k.pBot = _min(k.frm + Calendar.T, k.nxt);

        console.log(
            string.concat(
                "cycle ",
                vm.toString(c + 1),
                ":  ",
                _date(k.frm),
                " -> ",
                _date(k.nxt),
                c == 3 ? "   (IN PROGRESS)" : ""
            )
        );
        console.log("  strategy      ret     maxDD   worst DD on   zone     vs dep    pool     lev");

        out[0] = _hodl(k.frm, k.nxt);
        _print("  HODL   ", out[0], k.frm);

        for (uint256 p = 0; p < 4; p++) {
            Acc memory a = Acc(WAD, WAD, WAD, 0, k.frm, WAD);
            // regime 1: long [frm, pTop] | regime 2: fall [pTop, pBot] | regime 3: long [pBot, nxt]
            int256 lev = _regime(a, k.frm, k.pTop, prods[p].growth, k.floor_, k.capG);
            _regime(a, k.pTop, k.pBot, prods[p].fall, k.floor_, k.capG); // short: cap unused
            _regime(a, k.pBot, k.nxt, prods[p].growth, k.floor_, k.capR);
            // Pool income, credited once per cycle: the 20% penalised exits, redistributed.
            int256 pool = a.eq * POOL_U / WAD;
            a.eq += pool;

            out[p + 1] = Row(a.eq, a.maxDD, a.ddAt, a.low, pool, p == 3 ? lev : int256(0));
            _print(string.concat("  ", prods[p].name), out[p + 1], k.frm);
        }
        console.log("");
    }

    /// Buy & hold the directional asset: no calendar, no pool, no fees — the baseline.
    function _hodl(uint256 frm, uint256 nxt) internal view returns (Row memory r) {
        int256 e0 = _pxAt(frm);
        r.low = WAD;
        int256 peak = WAD;
        r.ddAt = frm;
        for (uint256 i = 0; i < ts.length; i++) {
            if (ts[i] < frm || ts[i] > nxt) continue;
            int256 eq = (px[i] * WAD) / e0;
            if (eq > peak) peak = eq;
            if (eq < r.low) r.low = eq;
            int256 dd = ((peak - eq) * WAD) / peak;
            if (dd > r.maxDD) {
                r.maxDD = dd;
                r.ddAt = ts[i];
            }
        }
        r.ret = (_pxAt(nxt) * WAD) / e0;
    }

    /// One held regime: size leverage once at entry, hold fixed units (equity linear in
    /// price), mark drawdown daily, charge funding on the perp leg, then take the operator
    /// performance fee on new profit above the high-water mark. Returns the entry leverage.
    struct Leg {
        int256 entry;
        int256 dir;
        int256 L;
        int256 perp;
        int256 eq0;
    }

    function _regime(
        Acc memory a,
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
            // Leveraged long: structural leverage; a refusal (0) falls back to 1x spot.
            g.L = int256(
                StructuralLeverage.leverageWad(
                    uint256(g.entry), uint256(mag), uint256(floor_), uint256(cap_)
                )
            );
            if (g.L == 0) g.L = WAD;
        } else {
            // target ∈ {0 flat/USDC, 1 spot, −1 or −φ short}: exposure = |target|, no
            // structural amplification. A zero target is genuinely flat (exposure 0).
            g.L = mag;
        }
        g.perp = g.L > WAD ? g.L - WAD : (target < 0 ? mag : int256(0));
        g.eq0 = a.eq;

        for (uint256 i = 0; i < ts.length; i++) {
            if (ts[i] < from_ || ts[i] >= to_) continue;
            int256 pos = _value(g, px[i], (ts[i] - from_) / 86400);
            if (pos > a.peak) a.peak = pos;
            if (pos < a.low) a.low = pos;
            int256 dd = a.peak <= 0 ? WAD : ((a.peak - pos) * WAD) / a.peak;
            if (dd > a.maxDD) {
                a.maxDD = dd;
                a.ddAt = ts[i];
            }
        }
        a.eq = _value(g, _pxAt(to_), (to_ - from_) / 86400);
        // Operator performance fee on profit above the ledger baseline. The shipped contract
        // (B4VaultOps.opsSettle: `entryLedgerWad = nav - paidVal`, unconditional) re-anchors
        // the baseline to NAV at EVERY settlement — there is NO high-water mark, so a loss
        // regime resets the baseline DOWN and the subsequent recovery is charged again as
        // fresh profit. Model that faithfully (audit C9): charge on the gain, then re-anchor
        // whether the regime gained or lost.
        if (a.eq > a.hw) a.eq -= (a.eq - a.hw) * OP_FEE / WAD;
        a.hw = a.eq;
        return g.L;
    }

    /// Held-units equity at price `p`, `d` days into the leg (equity linear in price).
    function _value(Leg memory g, int256 p, uint256 d) internal pure returns (int256 v) {
        int256 ret = ((p - g.entry) * WAD) / g.entry;
        v = g.eq0 + (g.eq0 * g.dir * g.L / WAD) * ret / WAD;
        v -= g.eq0 * g.perp / WAD * DAILY_FUNDING / WAD * int256(d);
        if (v < 0) v = 0;
    }

    // ------------------------------------------------------------------ summary

    function _summary(Product[4] memory prods, Row[5][4] memory all) internal pure {
        console.log(
            "=========== 3 COMPLETE CYCLES COMPOUNDED (2012-11-28 -> 2024-04-20) ==========="
        );
        console.log("  strategy          total ret   worst maxDD   worst vs dep   pool factor");
        for (uint256 s = 0; s < 5; s++) {
            int256 tot = WAD;
            int256 wdd;
            int256 wlow = WAD;
            for (uint256 c = 0; c < 3; c++) {
                tot = tot * all[c][s].ret / WAD;
                if (all[c][s].maxDD > wdd) wdd = all[c][s].maxDD;
                if (all[c][s].low < wlow) wlow = all[c][s].low;
            }
            // Pool factor: (1 + u)^3 for a stayer, 1.00x for the outside baseline.
            int256 pf = WAD;
            if (s > 0) {
                for (uint256 k = 0; k < 3; k++) {
                    pf = pf * (WAD + POOL_U) / WAD;
                }
            }
            console.log(
                string.concat(
                    "  ",
                    s == 0 ? "HODL   " : prods[s - 1].name,
                    "  ",
                    _padTo(_big(tot), 14),
                    "     ",
                    _pct(wdd),
                    "        ",
                    _pctS(wlow - WAD),
                    "        ",
                    s == 0 ? "     -" : _x(pf)
                )
            );
        }
        console.log("");
        console.log(
            "Assumptions: funding 10%/yr on the abs perp leg; operator fee <=1.72% of profit"
        );
        console.log(
            "(max route); 20% penalised exits/cycle. NOT modelled: slippage, market impact,"
        );
        console.log(
            "trading fees, async delay. Perfect calendar timing. Cycle 4 still in progress."
        );
    }

    // ------------------------------------------------------------------ printing

    function _print(string memory name, Row memory r, uint256 frm) internal pure {
        uint256 off = r.ddAt - frm;
        string memory zone = off < Calendar.P ? "GROWTH" : (off < Calendar.T ? "FALL  " : "RECOV ");
        // Pool as a share of this strategy's profit (can exceed 100% in a flat cycle).
        int256 profit = r.ret - WAD;
        string memory poolCol =
            r.pool == 0 ? "     -" : (profit <= 0 ? "  n/a " : _pctW(r.pool * WAD / profit));
        console.log(
            string.concat(
                name,
                " ",
                _big(r.ret),
                "   ",
                _pct(r.maxDD),
                "   ",
                _date(r.ddAt),
                "   ",
                zone,
                "   ",
                _pctS(r.low - WAD),
                "   ",
                poolCol,
                "   ",
                r.lev == 0 ? "    -" : _x(r.lev)
            )
        );
    }

    // ------------------------------------------------------------------ formatting

    /// Multiple, width 9 (handles 5-digit multiples): "  52.30x".
    function _big(int256 v) internal pure returns (string memory) {
        if (v < 0) return "      <0x";
        uint256 w = uint256(v);
        return _padTo(string.concat(vm.toString(w / 1e18), ".", _two((w % 1e18) / 1e16), "x"), 9);
    }

    /// Multiple, width 6: " 1.61x".
    function _x(int256 v) internal pure returns (string memory) {
        if (v < 0) return "   <0x";
        uint256 w = uint256(v);
        return _padTo(string.concat(vm.toString(w / 1e18), ".", _two((w % 1e18) / 1e16), "x"), 6);
    }

    /// Unsigned percent, width 7: " 84.18%".
    function _pct(int256 v) internal pure returns (string memory) {
        uint256 w = uint256(v < 0 ? -v : v);
        return _padTo(
            string.concat(vm.toString((w * 100) / 1e18), ".", _two((w * 10000 / 1e18) % 100), "%"),
            7
        );
    }

    /// Unsigned percent, width 6, no decimals: "  2.9%".
    function _pctW(int256 v) internal pure returns (string memory) {
        uint256 w = uint256(v < 0 ? -v : v);
        return _padTo(
            string.concat(
                vm.toString((w * 100) / 1e18), ".", vm.toString((w * 1000 / 1e18) % 10), "%"
            ),
            6
        );
    }

    /// Signed percent, width 7: " -0.32%".
    function _pctS(int256 v) internal pure returns (string memory) {
        uint256 w = uint256(v < 0 ? -v : v);
        string memory body = string.concat(
            v < 0 ? "-" : "+",
            vm.toString((w * 100) / 1e18),
            ".",
            _two((w * 10000 / 1e18) % 100),
            "%"
        );
        return _padTo(body, 7);
    }

    function _two(uint256 v) internal pure returns (string memory) {
        return v < 10 ? string.concat("0", vm.toString(v)) : vm.toString(v);
    }

    function _padTo(string memory s, uint256 n) internal pure returns (string memory) {
        while (bytes(s).length < n) {
            s = string.concat(" ", s);
        }
        return s;
    }

    function _min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
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
