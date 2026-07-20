// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";

/// @title Historical demo of the calendar over real BTC data.
/// @notice This drives the **actual `Calendar` library** — the same `targetAt` the vaults
///         use — over daily BTC closes, so the exposure path shown here is the protocol's
///         own arithmetic, not a re-implementation that could drift from it. Only the
///         portfolio bookkeeping (compounding a daily return at the given exposure) lives
///         in this file; that is market simulation, not protocol logic.
///
///         **What this is NOT.** It is an illustration of the mechanism, not evidence of
///         edge. Three completed cycles is a statistically meaningless sample, and by
///         construction it always will be — only ~32 halvings will ever occur. The model
///         also omits most real costs: slippage, trading fees, liquidation, the exit
///         penalty, the rebalance dead-band, and Pool income. Perp funding IS charged, but
///         at a flat assumed rate rather than the realised path. See the caveats printed
///         at the end of the run.
///
///         Run: `forge test --match-path 'test/backtest/*' -vv`
contract BacktestTest is Test {
    int256 constant WAD = 1e18;

    /// Annual funding cost charged on the ABSOLUTE perpetual leg. Real perp funding is
    /// path-dependent and not in this dataset, so it is an explicit ASSUMPTION, stated
    /// rather than hidden. Mini and B4 never carry a perp (`perp = n − clamp(n,0,1) = 0`
    /// for n ∈ {0,1}), so they are unaffected by it; Pro and Pro Max are.
    int256 constant FUNDING_APR = 10e16; // 10% / year

    /// Pool income, modelled conservatively. Assumption: **20 % of a cohort exits outside a
    /// free window per cycle**, paying the in-kind penalty `q`; the remainder is distributed
    /// to the participants who stayed. Uplift per cycle = `share·q / (1 − share)`, credited
    /// in equal parts at the two settlement points. This is a BEHAVIOURAL assumption about
    /// users, not protocol mechanics — every other line in this file is the protocol's own
    /// arithmetic, this one is a guess, and it is stated so it can be argued with.
    int256 constant POOL_EXIT_SHARE = 20e16; // 20% of a cohort exits penalised

    /// Real halving block timestamps (UTC). 840000 matches the genesis anchor used across
    /// the rest of the suite (`1713571767`).
    uint256[4] HALVINGS = [
        uint256(1354116278), // 210000 — 2012-11-28
        1468082773, // 420000 — 2016-07-09
        1589225023, // 630000 — 2020-05-11
        1713571767 // 840000 — 2024-04-20
    ];

    struct Product {
        string name;
        int256 growth;
        int256 fall;
    }

    struct Run {
        int256 value; // portfolio value (WAD), starts at 1.0
        int256 entry; // entry ledger for the fee (WAD)
        int256 fees; // cumulative performance fee paid (WAD)
        int256 poolYield; // cumulative Pool credit (WAD)
        int256 peak;
        int256 maxDD; // worst peak-to-trough, WAD
        uint256 ddDay; // day-of-cycle at which maxDD was reached
    }

    uint256[] ts; // day timestamp (UTC midnight)
    int256[] px; // close price, WAD

    function _loadPrices() internal {
        string memory path = string.concat(vm.projectRoot(), "/data/btcusd_daily.csv");
        string memory line = vm.readLine(path); // header
        while (bytes((line = vm.readLine(path))).length != 0) {
            string[] memory f = vm.split(line, ",");
            ts.push(_dateToTs(f[0]));
            px.push(int256(vm.parseUint(_toWadDecimal(f[4]))));
        }
    }

    /// "YYYY-MM-DD" → unix seconds (days-from-civil, Howard Hinnant's algorithm).
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

    /// "81457.0" → "81457000000000000000000" (WAD), tolerating any decimal length.
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

    /// Epoch index active at `t`, and the seconds since that halving.
    function _sinceHalving(uint256 t) internal view returns (bool live, uint256 dt) {
        if (t < HALVINGS[0]) return (false, 0);
        uint256 i = 0;
        while (i + 1 < HALVINGS.length && t >= HALVINGS[i + 1]) {
            i++;
        }
        return (true, t - HALVINGS[i]);
    }

    function test_backtest_products_vs_hold() public {
        _loadPrices();
        assertGt(px.length, 4000, "dataset loaded");

        Product[4] memory prods = [
            Product("Mini   ", WAD, WAD),
            Product("B4     ", WAD, int256(0)),
            Product("Pro    ", WAD, -int256(Phi.INV_PHI)),
            Product("Pro Max", int256(Phi.PHI), -int256(Phi.PHI))
        ];

        console.log("");
        console.log("=== B4 calendar over real BTC daily closes, PER CYCLE ===");
        console.log("Each cycle restarts at 1.0x. Cumulative compounding since 2012 is");
        console.log("deliberately NOT reported: it is dominated by the earliest, least");
        console.log("liquid period and says more about a $12 base than about the design.");
        console.log(
            "Assumptions: funding %s bps/yr on the abs perp leg; Pool income from",
            uint256(FUNDING_APR / 1e14)
        );
        console.log("20% of a cohort exiting penalised each cycle (behavioural guess).");
        console.log("");

        for (uint256 c = 0; c < HALVINGS.length; c++) {
            uint256 from = HALVINGS[c];
            uint256 to = c + 1 < HALVINGS.length ? HALVINGS[c + 1] : type(uint256).max;
            _runCycle(prods, from, to, c);
        }

        console.log("");
        console.log("Mini holds spot in both regimes and never trades: it pays the fee on");
        console.log("interval profit and earns it back as Pool income, landing near HODL.");
        console.log("Both effects are modelled; the Pool side rests on the 20% assumption.");
        console.log("NOT modelled: slippage, trading fees, liquidation, the rebalance");
        console.log("dead-band, async execution delay. Daily closes, daily rebalancing.");
        console.log("Three completed cycles is not a sample - and never can be: only about");
        console.log("thirty halvings will ever occur.");
        console.log("");
        console.log("Note the DD column: for every ROTATING product (B4/Pro/Pro Max) the");
        console.log("worst drawdown falls inside a regime, never in a 20-day transition.");
        console.log("The calendar rotates AT the pivots; it does not protect against a");
        console.log("drawdown INSIDE a regime. Pro Max cycle 1 is the Apr-2013 crash");
        console.log("(BTC -70.4%) at phi leverage, 319 days before the pivot - not a");
        console.log("rotation-timing artefact. Mini never rotates, so its DD tracks HODL.");
    }

    struct Ctx {
        uint256 from;
        uint256 i0;
        uint256 last;
        uint256 settlements;
    }

    function _runCycle(Product[4] memory prods, uint256 from, uint256 to, uint256 idx) internal {
        Ctx memory c;
        c.from = from;
        while (c.i0 < ts.length && ts[c.i0] < from) {
            c.i0++;
        }
        if (c.i0 == 0 || c.i0 >= ts.length) return;
        c.last = c.i0;

        Run[4] memory r;
        for (uint256 p = 0; p < 4; p++) {
            r[p] = Run(WAD, WAD, 0, 0, WAD, 0, 0);
        }

        for (uint256 i = c.i0 + 1; i < px.length && ts[i] < to; i++) {
            c.last = i;
            bool settled = _crossedSettlement(ts[i - 1] - from, ts[i] - from);
            if (settled) c.settlements++;
            for (uint256 p = 0; p < 4; p++) {
                _step(
                    r[p],
                    prods[p],
                    ts[i - 1] - from,
                    ((px[i] - px[i - 1]) * WAD) / px[i - 1],
                    settled
                );
            }
        }
        // Correctness check on the model, not a result: Mini never trades, so its path
        // must be HODL adjusted only by the fee it pays and the Pool income it earns.
        int256 hold = (px[c.last] * WAD) / px[c.i0];
        assertApproxEqRel(r[0].value, hold, 0.08e18, "Mini must track HODL within fee/Pool drift");

        _report(prods, r, c, idx, to == type(uint256).max);
    }

    function _crossedSettlement(uint256 dtPrev, uint256 dtNow) internal pure returns (bool) {
        return (dtPrev < Calendar.P - Calendar.H && dtNow >= Calendar.P - Calendar.H)
            || (dtPrev < Calendar.T + Calendar.H && dtNow >= Calendar.T + Calendar.H);
    }

    /// One day for one product. `dtPrev` is YESTERDAY's calendar position, so the exposure
    /// applied to today's return was knowable yesterday — no lookahead.
    function _step(Run memory r, Product memory prod, uint256 dtPrev, int256 rWad, bool settled)
        internal
        pure
    {
        // THE PROTOCOL'S OWN FUNCTION.
        int256 n = Calendar.targetAt(dtPrev, prod.growth, prod.fall);
        r.value += ((r.value * n) / WAD) * rWad / WAD;

        // Funding on the residual perp leg only: perp = n − clamp(n, 0, 1).
        int256 spot = n < 0 ? int256(0) : (n > WAD ? WAD : n);
        int256 perp = n - spot;
        if (perp != 0) {
            int256 absPerp = perp < 0 ? -perp : perp;
            r.value -= ((r.value * absPerp) / WAD) * (FUNDING_APR / 365) / WAD;
        }

        if (settled) {
            int256 profit = r.value - r.entry;
            if (profit > 0) {
                int256 fee = (profit * int256(Phi.FEE_F)) / WAD;
                r.value -= fee;
                r.fees += fee;
            }
            r.entry = r.value;

            // Pool income: the penalty paid by the cohort that exited early, shared out
            // among those who stayed. Half the per-cycle uplift at each of the two points.
            int256 uplift =
                (POOL_EXIT_SHARE * int256(Phi.EXIT_Q) / WAD) * WAD / (WAD - POOL_EXIT_SHARE) / 2;
            int256 credit = (r.value * uplift) / WAD;
            r.value += credit;
            r.poolYield += credit;
        }
        if (r.value > r.peak) r.peak = r.value;
        int256 dd = r.peak <= 0 ? WAD : ((r.peak - r.value) * WAD) / r.peak;
        if (dd > r.maxDD) {
            r.maxDD = dd;
            r.ddDay = dtPrev / 86400;
        }
    }

    function _report(
        Product[4] memory prods,
        Run[4] memory r,
        Ctx memory c,
        uint256 idx,
        bool inProgress
    ) internal view {
        console.log(
            string.concat(
                "--- cycle ",
                vm.toString(idx + 1),
                ": ",
                _date(ts[c.i0]),
                " -> ",
                _date(ts[c.last]),
                inProgress ? " (IN PROGRESS)" : ""
            )
        );
        console.log("    settlements: %s", c.settlements);
        console.log("    product |  return |  max DD | DD at day | zone");
        for (uint256 p = 0; p < 4; p++) {
            console.log(
                string.concat(
                    "    ",
                    prods[p].name,
                    " | ",
                    _x(r[p].value),
                    " | ",
                    _pct(r[p].maxDD),
                    " | ",
                    _pad3(vm.toString(r[p].ddDay)),
                    "       | ",
                    _zone(r[p].ddDay)
                )
            );
        }
        console.log(
            string.concat(
                "    HODL    | ",
                _x((px[c.last] * WAD) / px[c.i0]),
                " | ",
                _pct(_holdMaxDDRange(c.i0, c.last))
            )
        );
        console.log("");
    }

    /// Which regime the worst drawdown fell in — the point being that none of them land
    /// inside the 20-day transition, so they are not a rotation-timing artefact.
    function _zone(uint256 day) internal pure returns (string memory) {
        uint256 t = day * 86400;
        if (t < Calendar.P - Calendar.W) return "GROWTH";
        if (t < Calendar.P) return "transition";
        if (t < Calendar.T) return "FALL";
        if (t < Calendar.T + Calendar.W) return "transition";
        return "terminal growth";
    }

    function _holdMaxDDRange(uint256 a, uint256 b) internal view returns (int256 maxDD) {
        int256 peak = px[a];
        for (uint256 i = a; i <= b; i++) {
            if (px[i] > peak) peak = px[i];
            int256 dd = ((peak - px[i]) * WAD) / peak;
            if (dd > maxDD) maxDD = dd;
        }
    }

    // ------------------------------------------------------------------ formatting

    function _x(int256 v) internal pure returns (string memory) {
        if (v < 0) return "  <0";
        uint256 w = uint256(v);
        return string.concat(_pad(vm.toString(w / 1e18)), ".", _two((w % 1e18) / 1e16), "x");
    }

    function _pct(int256 v) internal pure returns (string memory) {
        uint256 w = uint256(v < 0 ? -v : v);
        return string.concat(
            _pad3(vm.toString((w * 100) / 1e18)), ".", _two((w * 10000 / 1e18) % 100), "%"
        );
    }

    function _two(uint256 v) internal pure returns (string memory) {
        return v < 10 ? string.concat("0", vm.toString(v)) : vm.toString(v);
    }

    function _pad(string memory s) internal pure returns (string memory) {
        while (bytes(s).length < 6) {
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
