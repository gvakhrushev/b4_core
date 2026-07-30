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
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {Origin} from "src/interfaces/ILayerZero.sol";
import {StrategyB4, StrategyPro, StrategyProMax} from "src/periphery/ReferenceStrategies.sol";

/// @title Legacy preliminary population fixture — withdrawn from reporting.
/// @notice This contract remains as a reusable fixture for the replacement closed-population
/// runner in `ClosedPopulation.t.sol`. Its former public shard tests deliberately no longer use
/// Foundry's `test_*` prefix: their one shared stayer/exiter book plus eight unrelated cohorts
/// diluted individual claims, so their artifacts must not be used in documentation or a UI.
/// `PoolClaimFlow.t.sol` is the contract-level accounting proof; `ClosedPopulation.t.sol` is the
/// current strict-pool population runner. This file stays only as shared CSV/calendar/venue
/// plumbing; its preliminary public methods are intentionally not `test_*` methods.
///
///  QUESTION ANSWERED: "If I enter at time T with strategy S while the population's
///  penalized-exiter share is r (10% or 20%), what do I get vs HODL — in MULTIPLES and
///  SHARE-OF-POOL growth, not dollars?" Every figure is read off the real B4Vault /
///  B4VaultOps / B4Pool / HalvingOracle + reference strategies, cranked and settled
///  day-by-day across the real halving epochs exactly like BacktestReal — there is NO
///  parallel equity re-implementation anywhere in this file.
///
///  POPULATION (per run, full history HALVING_TS[0] → last CSV day):
///   - STAYER book: one StrategyB4 vault, deposits normalized $1000·(1−r)/day, never exits.
///     Cranked weekly (deploys DCA tranches toward target) + at every calendar
///     transition + settle, so its pool weight reflects real strategy execution.
///   - EXITER book: one StrategyB4 vault, deposits normalized $1000·r/day and partial-exits the
///     same day via initiateExit(share), share = min(1, dayInflow/navWad) → daily exit
///     ≈ daily inflow (steady-state ~1-day balance). Exits inside Calendar.freeExit
///     windows are free; outside they pay q = EXIT_Q ≈ 11.8034%. FIDELITY SHORTCUT
///     (deliberate): the exiter is never sync-cranked to Core, so its exits finalize
///     in ONE crank (EVM buckets only) instead of 3+. This changes nothing measurable:
///     the standing balance is ~1 day of inflow (normalized ~$100–$200; $1–$2 executed),
///     so strategy-execution PnL on the book is < 0.1% of flows either way, exit gross is sized from LIVE
///     navWad (exact), and the free/penalized split is computed from the same
///     Calendar.freeExit the contract uses. The WAD penalty split is checked exactly;
///     physical in-kind inventory is recorded separately to expose token flooring.
///
///  MEASURED USERS (per shard): 8 entry dates × ONE strategy {B4, Pro, ProMax}.
///  Each DCA-deposits normalized $1000/day from entry to run end and NEVER exits (so per B3 the
///  equity multiple of Pro/ProMax understates while a perp leg is open — unrealized
///  PnL enters navWad only when the leg closes at a transition; documented, faithful).
///  Entry sweep: full (h0), c1prepeak (h0+P−W−30d), c1mid (h0+1191d), c2postwin
///  (h1+10d), c2prepeak (h1+P−W−30d), c3start (h2), c3prepeak (h2+P−W−30d),
///  c4postwin (h3+10d). "full" is the anchor scenario. One shard = one r × one
///  strategy ⇒ 6 shards; each shard re-runs the SAME 2-book population, so
///  share-of-pool figures are per-shard populations with the stayer book as the
///  common yardstick (a 26-vault single run does not fit the 240 s shell limit).
///
///  DEPOSIT RULE: deposits are accepted throughout the cycle; a late entry follows the
///  current partial target and reaches the full target at the end of the 20-day transition.
///  Deposits are BTC (dir) only, valued at the day's close,
///  mirroring BacktestReal's funding convention (V6-M-2: perp products self-fund
///  margin by selling spot; no separate USDC posted).
///
///  SCALE: every cohort DCAs $10/day (NOT $1000). All reported quantities are
///  multiples, basis-point ratios or weight shares — scale-invariant by construction —
///  and $10/day keeps the full-period ProMax DCA position inside MockCore's uint64
///  spot/perp accounting through cycle 4 (the same mock limitation that made
///  BacktestReal pick a $1000 base; verified: $1000/day overflows at the cycle-1
///  transition with a ~1.7e18-wei-scale order, $10/day leaves ~100x headroom).
///  Absolute penalty/claim USD figures in the preliminary logs are therefore 1/100th
///  of a displayed "$1000/day population" — every bp ratio is unaffected.
///
///  KEEPER DUTIES in the sim (exactly what the on-chain keeper does):
///   - daily pool.sampleAnchor(1) inside the three sampling windows (density gate
///     V8-M-1/2: ≥10 daily samples spanning ≥W/2 — daily sampling confirms every window, so
///     Pro/ProMax get production structural sizing);
///   - at each settlement point (h+P−H, h+T+H): claimFor every vault on the PREVIOUS
///     interval (latest-interval-only gate!), advance(), sweep() the expired interval,
///     lockPrices(), crank every vault idle, settle() every vault;
///   - final claim pass at run end for the last interval;
///   - measured vaults crank every 14 days (staggered) + at every checkpoint — a
///     documented deployment-lag approximation of daily DCA execution.
///
///  CHECKPOINTS: the penalty-free zone boundaries {0, W, P−W, P−H, P, T, T+H, T+W}
///  per cycle (P−H / T+H are also the settlement points) + run end. At each: date,
///  price, equity multiple (navWad + cumClaims vs cumDeposits), HODL multiple
///  (off-chain DCA from the SAME CSV, normalized $1000/day into BTC at close from same entry),
///  cum pool payout, pool weight share, running max drawdown of the multiple curve
///  (tracked on weekly samples + checkpoints; headline scenarios daily).
///
///  PENALTY VERIFICATION: per run per cycle — exiter gross exited (penalized/free
///  split), penalty, operator cut (min(ocx, penalty)), pool receipts (expected from
///  pre-exit state AND actual accruing deltas — cross-checked), vs theory r·q/(1−r)
///  (20% → 2.95%/cycle; 10% → 1.31%/cycle) and README 3-cycle compounding (×1.091 /
///  ×1.040). Deviations explained: free-zone exits (60 d/cycle ≈ 4.1% of days),
///  weight/claims timing, undistributed tail in accruing at run end.
///
contract SimTest is VenueTestBase {
    uint32 constant SRC_EID = 30_101;
    bytes32 constant SRC_SENDER = bytes32(uint256(1));

    uint256[4] HALVING_HEIGHT = [uint256(210_000), 420_000, 630_000, 840_000];
    uint256[4] HALVING_TS = [uint256(1_354_116_278), 1_468_082_773, 1_589_225_023, 1_713_571_767];

    uint256 constant DAILY_BOOK_WAD = 10e18; // $10/day population book DCA (see note)
    uint256 constant DAILY_USER_WAD = 10e18; // $10/day measured-user DCA (see note)
    uint256 constant CRANK_EVERY = 14 days; // measured-vault deployment cadence
    uint256 constant EQUITY_EVERY = 7 days; // equity sampling cadence for maxDD

    MockLzEndpoint endpoint;
    HalvingOracle oracle;
    B4Factory factory;
    B4Pool pool;

    uint256[] ts; // absolute unix seconds (CSV midnights)
    int256[] px; // WAD dollars
    uint256 pxIdx; // running pointer (days processed in order)

    // ------------------------------------------------------------------ cohort model

    uint8 constant K_STAYER = 0;
    uint8 constant K_EXITER = 1;
    uint8 constant K_MEASURED = 2;

    struct Ck {
        uint256 t; // checkpoint timestamp
        uint256 pxWad;
        uint256 eq6; // equity multiple x1e6
        uint256 hodl6; // HODL multiple x1e6
        uint256 claimsWad; // cumulative pool payout (WAD USD at claim-day px)
        uint256 shareBp; // pool weight share, basis points
    }

    struct Cohort {
        B4Vault v;
        address owner;
        uint8 kind;
        string tag; // entry tag ("book-stayer","full","c1prepeak",...)
        uint256 entryTs;
        uint256 cumDepWad;
        uint256 cumClaimsWad;
        uint256 peakEq6;
        uint256 maxDDbp;
        uint256 firstShareBp;
        uint256 lastShareBp;
        uint256 firstWeightWad;
        uint256 lastWeightWad;
        Ck[] cks;
    }

    Cohort[] cohorts; // [0]=stayer, [1]=exiter, [2..]=measured
    uint256[8] entryTsA;
    string[8] entryTags;
    uint256[] cps; // checkpoint timestamps (sorted)
    uint256[] pts; // settlement point timestamps (sorted)
    // Per-cycle cash flows, not NAV. `r·q/(1−r)` describes the current exiter
    // flow relative to the current stayer flow, so accumulated capital from earlier
    // cycles is not a valid denominator for the penalty-economy check.
    uint256[4] cycStayerFlowWad;
    uint256[4] cycNonExiterFlowWad;

    struct Hodl {
        uint256 btcWad;
        uint256 depWad;
    }
    Hodl[8] hodls;

    // penalty verification accumulators (per cycle)
    uint256[4] penGrossWad;
    uint256[4] freeGrossWad;
    uint256[4] penWad;
    uint256[4] penOpCutWad;
    uint256[4] freeOpCutWad;
    uint256[4] poolExpWad;
    uint256[4] poolActWad;
    uint256[4] claimsLandedWad;

    uint256 rWad;
    uint256 stratIdx;
    string shardTag;
    uint256 dayLimit; // probe truncation (0 = full)
    uint256[2] headlineIdx; // cohort indices written to the series CSV

    function setUp() public {
        vm.warp(HALVING_TS[0]);
        setUpVenue();
        _loadPrices();
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

    /// First close on/after `t`, via the monotonic running pointer.
    function _pxLive(uint256 t) internal returns (uint256) {
        while (pxIdx + 1 < ts.length && ts[pxIdx] < t) pxIdx++;
        return uint256(px[pxIdx]);
    }

    // ------------------------------------------------------------------ venue plumbing

    function _freshProtocol() internal {
        vm.warp(HALVING_TS[0]);
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

    function _setPx(uint256 pxWad) internal {
        hub.setSpotPx(SPOT_MKT, uint64(pxWad / 1e14)); // WAD $ -> $ * 1e4
        hub.setMarkPx(PERP_MKT, uint64(pxWad / 1e16)); // WAD $ -> $ * 1e2
        hub.setOraclePx(PERP_MKT, uint64(pxWad / 1e16));
    }

    function _crankUntilIdle(B4Vault v, uint256 maxSteps) internal returns (uint256 steps) {
        for (steps = 0; steps < maxSteps; steps++) {
            if (!v.crank()) break;
        }
    }

    // ------------------------------------------------------------------ cohort setup

    function _strategy(uint256 idx) internal returns (address) {
        if (idx == 0) return address(new StrategyB4());
        if (idx == 1) return address(new StrategyPro());
        return address(new StrategyProMax());
    }

    function _stratName(uint256 idx) internal pure returns (string memory) {
        if (idx == 0) return "B4";
        if (idx == 1) return "Pro";
        return "ProMax";
    }

    function _deployCohort(uint8 kind, string memory tag, uint256 entryTs, uint256 strat_)
        internal
        returns (uint256 idx)
    {
        idx = cohorts.length;
        Cohort storage c = cohorts.push();
        c.kind = kind;
        c.tag = tag;
        c.entryTs = entryTs;
        c.owner = address(uint160(0xB400 + idx * 7 + 1));
        address strat = _strategy(strat_); // deploy BEFORE prank: a CREATE consumes it
        vm.prank(c.owner);
        c.v = B4Vault(
            factory.createVault(
                address(pool),
                CoreTypes.descriptorHash(ubtcDescriptor()),
                strat,
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
        vm.prank(c.owner);
        ubtc.approve(address(c.v), type(uint256).max);
    }

    /// $`usdWad` worth of BTC at the current price, minted to the owner and deposited.
    function _deposit(uint256 idx, uint256 usdWad, uint256 pxWad) internal {
        Cohort storage c = cohorts[idx];
        uint256 dirAmount = (usdWad * 1e18 / pxWad) / 1e10; // 8-dec BTC
        if (dirAmount == 0) return;
        ubtc.mint(c.owner, dirAmount);
        vm.prank(c.owner);
        c.v.deposit(dirAmount, 0);
        c.cumDepWad += usdWad;
    }

    // ------------------------------------------------------------------ schedule build

    function _buildSchedule() internal {
        uint256 P = Calendar.P;
        uint256 W = Calendar.W;
        uint256 T = Calendar.T;
        uint256 H = Calendar.H;
        uint256 last = ts[ts.length - 1];

        // settlement points
        for (uint256 c = 0; c < 4; c++) {
            if (HALVING_TS[c] + (P - H) <= last) pts.push(HALVING_TS[c] + (P - H));
            if (HALVING_TS[c] + (T + H) <= last) pts.push(HALVING_TS[c] + (T + H));
        }
        // checkpoints: free-zone boundaries per cycle + run end
        uint256[8] memory offs = [uint256(0), W, P - W, P - H, P, T, T + H, T + W];
        for (uint256 c = 0; c < 4; c++) {
            for (uint256 k = 0; k < 8; k++) {
                uint256 cp = HALVING_TS[c] + offs[k];
                if (cp < last && cp >= HALVING_TS[0]) cps.push(cp);
            }
        }
        // run-end checkpoint is recorded separately by _finalCheckpoint (after the
        // final claim pass, so claims are included)

        // entry sweep (8 entries, shared across strategies)
        entryTsA[0] = HALVING_TS[0];
        entryTsA[1] = HALVING_TS[0] + (P - W) - 30 days;
        entryTsA[2] = HALVING_TS[0] + 1191 days;
        entryTsA[3] = HALVING_TS[1] + 10 days;
        entryTsA[4] = HALVING_TS[1] + (P - W) - 30 days;
        entryTsA[5] = HALVING_TS[2];
        entryTsA[6] = HALVING_TS[2] + (P - W) - 30 days;
        entryTsA[7] = HALVING_TS[3] + 10 days;
        entryTags = [
            "full",
            "c1prepeak",
            "c1mid",
            "c2postwin",
            "c2prepeak",
            "c3start",
            "c3prepeak",
            "c4postwin"
        ];
    }

    // ------------------------------------------------------------------ main run

    function _runShard(uint256 rWad_, uint256 strat_, string memory tag, uint256 dayLimit_)
        internal
    {
        rWad = rWad_;
        stratIdx = strat_;
        shardTag = tag;
        dayLimit = dayLimit_;
        _freshProtocol();
        _buildSchedule();
        _deployCohort(K_STAYER, "book-stayer", HALVING_TS[0], 0);
        _deployCohort(K_EXITER, "book-exiter", HALVING_TS[0], 0);
        for (uint256 k = 0; k < 8; k++) {
            _deployCohort(K_MEASURED, entryTags[k], entryTsA[k], strat_);
        }
        headlineIdx[0] = 2; // "full" entry
        headlineIdx[1] = 4; // "c1mid" entry

        uint256 stayerInflow = DAILY_BOOK_WAD * (1e18 - rWad) / 1e18;
        uint256 exiterInflow = DAILY_BOOK_WAD * rWad / 1e18;

        uint256 n = ts.length;
        if (dayLimit_ != 0 && dayLimit_ < n) n = dayLimit_;
        uint256 cpIdx;
        uint256 ptIdx;
        uint256 halvNext = 1;
        uint256 curCyc;
        uint256 lastI;

        for (uint256 i = 0; i < n; i++) {
            if (ts[i] < HALVING_TS[0]) continue;
            lastI = i;
            vm.warp(ts[i]);
            uint256 pxWad = _pxLive(ts[i]);
            _setPx(pxWad);
            // halving facts, accepted at their real timestamps (day granularity)
            while (halvNext < 4 && ts[i] >= HALVING_TS[halvNext]) {
                _acceptHalving(HALVING_HEIGHT[halvNext], HALVING_TS[halvNext]);
                curCyc = halvNext;
                halvNext++;
            }
            uint256 t = ts[i] - HALVING_TS[curCyc];

            // keeper: settlement blocks (claims -> advance -> sweep -> lock -> settle)
            while (ptIdx < pts.length && ts[i] >= pts[ptIdx]) {
                _settleBlock(pxWad, curCyc);
                ptIdx++;
            }
            // checkpoints: crank all + record
            while (cpIdx < cps.length && ts[i] >= cps[cpIdx]) {
                _checkpointBlock(cps[cpIdx], pxWad);
                cpIdx++;
            }
            // keeper: anchor sampling (density gate needs >=10 daily samples / >=W/2 span)
            if (_inAnchorWindow(t)) {
                try pool.sampleAnchor(1) {} catch {}
            }

            bool open = true;
            if (open) {
                _deposit(0, stayerInflow, pxWad); // stayer book
                cycStayerFlowWad[curCyc] += stayerInflow;
                cycNonExiterFlowWad[curCyc] += stayerInflow;
                _deposit(1, exiterInflow, pxWad); // exiter book
                for (uint256 j = 2; j < cohorts.length; j++) {
                    if (ts[i] >= cohorts[j].entryTs) {
                        _deposit(j, DAILY_USER_WAD, pxWad);
                        cycNonExiterFlowWad[curCyc] += DAILY_USER_WAD;
                    }
                }
                for (uint256 k = 0; k < 8; k++) {
                    if (ts[i] >= entryTsA[k]) {
                        hodls[k].btcWad += DAILY_USER_WAD * 1e18 / pxWad;
                        hodls[k].depWad += DAILY_USER_WAD;
                    }
                }
            }
            if (open) _exiterExit(exiterInflow, pxWad, t, curCyc);

            // staggered deployment cranks + equity tracking
            for (uint256 j = 0; j < cohorts.length; j++) {
                if (j != 1 && cohorts[j].cumDepWad > 0 && (i + j) % 14 == 0) {
                    _crankUntilIdle(cohorts[j].v, 40);
                }
            }
            bool eqDay = i % 7 == 0;
            for (uint256 j = 0; j < cohorts.length; j++) {
                if (j == 1) continue;
                bool headline = j == headlineIdx[0] || j == headlineIdx[1];
                if (eqDay || headline) _trackEquity(j);
                if (headline && eqDay) _writeSeriesRow(j, i, pxWad);
            }
        }

        // final claim pass for the last interval + final records + artifacts
        vm.warp(ts[lastI]);
        uint256 pxEnd = _pxLive(ts[lastI]);
        _setPx(pxEnd);
        _claimPass(pool.intervalCount() - 1, pxEnd, curCyc);
        _finalCheckpoint(pxEnd);
        _writeSummary(pxEnd);
        _logPenaltyTables();
    }

    function _inAnchorWindow(uint256 t) internal pure returns (bool) {
        if (t < Calendar.W) return true; // post-halving window
        if (t >= Calendar.P - Calendar.W && t < Calendar.P) return true; // peak window
        if (t >= Calendar.T && t < Calendar.T + Calendar.W) return true; // 62-window
        return false;
    }

    // ------------------------------------------------------------------ keeper blocks

    /// Claims on the previous interval (latest-only gate) -> advance -> sweep -> lock
    /// -> crank every vault idle -> settle every vault into the new interval.
    function _settleBlock(uint256 pxWad, uint256 curCyc) internal {
        uint256 count = pool.intervalCount();
        if (count > 0) _claimPass(count - 1, pxWad, curCyc);
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        if (id > 0) pool.sweep(id - 1);
        pool.lockPrices(id);
        for (uint256 j = 0; j < cohorts.length; j++) {
            _crankUntilIdle(cohorts[j].v, 80);
            cohorts[j].v.settle(id);
        }
    }

    /// Claim interval `id` for every vault that reported weight; value proceeds in kind
    /// at the day's price and accumulate per-cohort and per-cycle totals.
    function _claimPass(uint256 id, uint256 pxWad, uint256 curCyc) internal {
        if (pool.intervalCount() == 0) return;
        (,, bool swept,) = pool.intervalInfo(id);
        if (swept) return;
        if (block.timestamp <= pool.reportDeadline(id)) return;
        for (uint256 j = 0; j < cohorts.length; j++) {
            if (pool.weightOf(id, address(cohorts[j].v)) == 0) continue;
            address o = cohorts[j].owner;
            uint256 b0 = ubtc.balanceOf(o);
            uint256 u0 = usdc.balanceOf(o);
            pool.claimFor(id, address(cohorts[j].v));
            uint256 val =
                (ubtc.balanceOf(o) - b0) * 1e10 * pxWad / 1e18 + (usdc.balanceOf(o) - u0) * 1e12;
            cohorts[j].cumClaimsWad += val;
            claimsLandedWad[curCyc] += val;
        }
    }

    /// Crank every vault idle (transition execution) and record per-cohort metrics.
    /// Runs at the current day warp (ts[i] >= cp, same-day state; `cp` labels the
    /// canonical zone-boundary timestamp) — no backward warps.
    function _checkpointBlock(uint256 cp, uint256 pxWad) internal {
        for (uint256 j = 0; j < cohorts.length; j++) {
            if (cohorts[j].cumDepWad > 0) _crankUntilIdle(cohorts[j].v, 60);
        }
        uint256 latest = pool.intervalCount() == 0 ? type(uint256).max : pool.intervalCount() - 1;
        for (uint256 j = 0; j < cohorts.length; j++) {
            if (j == 1) continue; // exiter is flows, not a scenario
            Cohort storage c = cohorts[j];
            if (c.cumDepWad == 0 && c.kind == K_MEASURED) continue;
            _recordCk(j, cp, pxWad, latest);
            _trackEquity(j);
        }
    }

    function _recordCk(uint256 j, uint256 cp, uint256 pxWad, uint256 latest) internal {
        Cohort storage c = cohorts[j];
        uint256 shareBp;
        uint256 weight;
        if (latest != type(uint256).max) {
            (,,, uint256 totW) = pool.intervalInfo(latest);
            weight = pool.weightOf(latest, address(c.v));
            if (totW > 0) shareBp = weight * 10_000 / totW;
        }
        if (weight > 0) {
            if (c.firstWeightWad == 0) {
                c.firstWeightWad = weight;
                c.firstShareBp = shareBp;
            }
            c.lastWeightWad = weight;
            c.lastShareBp = shareBp;
        }
        uint256 eq6 = c.cumDepWad == 0 ? 0 : (c.v.navWad() + c.cumClaimsWad) * 1e6 / c.cumDepWad;
        uint256 hodl6 = _hodl6(j, pxWad);
        c.cks
            .push(
                Ck({
                    t: cp,
                    pxWad: pxWad,
                    eq6: eq6,
                    hodl6: hodl6,
                    claimsWad: c.cumClaimsWad,
                    shareBp: shareBp
                })
            );
    }

    function _hodl6(uint256 j, uint256 pxWad) internal view returns (uint256) {
        if (cohorts[j].kind != K_MEASURED) return 0;
        Hodl storage h = hodls[j - 2];
        if (h.depWad == 0) return 0;
        return h.btcWad * pxWad / 1e18 * 1e6 / h.depWad;
    }

    /// Equity multiple + running max drawdown of the multiple curve.
    function _trackEquity(uint256 j) internal {
        Cohort storage c = cohorts[j];
        if (c.cumDepWad == 0) return;
        uint256 eq6 = (c.v.navWad() + c.cumClaimsWad) * 1e6 / c.cumDepWad;
        if (eq6 > c.peakEq6) c.peakEq6 = eq6;
        if (c.peakEq6 > 0) {
            uint256 dd = (c.peakEq6 - eq6) * 10_000 / c.peakEq6;
            if (dd > c.maxDDbp) c.maxDDbp = dd;
        }
    }

    // ------------------------------------------------------------------ exiter book

    struct ExitCalc {
        uint256 x;
        uint256 gross;
        uint256 penalty;
        uint256 opCut;
        uint256 poolExp;
        bool free;
    }

    /// Daily penalized/free partial exit sized to the day's inflow. Computes the exact
    /// expected split from pre-exit state (the same arithmetic _finalizeExit runs) and
    /// cross-checks pool receipts via accruing deltas.
    function _exiterExit(uint256 inflowWad, uint256 pxWad, uint256 t, uint256 curCyc) internal {
        Cohort storage c = cohorts[1];
        uint256 nav = c.v.navWad();
        if (nav == 0) return;
        ExitCalc memory ec;
        ec.x = inflowWad >= nav ? 1e18 : inflowWad * 1e18 / nav;
        uint256 e = c.v.entryLedgerWad();
        uint256 profit = nav > e ? nav - e : 0;
        uint256 ocx = Phi.wmul(Phi.wmul(profit, Phi.FEE_F) * 3819 / 10_000, ec.x);
        ec.free = Calendar.freeExit(t);
        ec.gross = Phi.wmul(nav, ec.x);
        ec.penalty = ec.free ? 0 : Phi.wmul(ec.gross, Phi.EXIT_Q);
        ec.opCut = ec.free ? ocx : (ocx < ec.penalty ? ocx : ec.penalty);
        // free exit: operator takes ocx, pool takes 0 (NOT penalty - opCut)
        ec.poolExp = ec.free ? 0 : ec.penalty - ec.opCut;

        uint256 a0 = pool.accruing(0);
        uint256 a1 = pool.accruing(1);
        vm.prank(c.owner);
        c.v.initiateExit(ec.x);
        _crankUntilIdle(c.v, 40);
        require(c.v.exitShareWad() == 0, "exiter exit did not finalize");
        uint256 act = (pool.accruing(0) - a0) * 1e12 + (pool.accruing(1) - a1) * 1e10 * pxWad / 1e18;

        if (ec.free) {
            freeGrossWad[curCyc] += ec.gross;
            freeOpCutWad[curCyc] += ec.opCut;
        } else {
            penGrossWad[curCyc] += ec.gross;
            penOpCutWad[curCyc] += ec.opCut;
        }
        penWad[curCyc] += ec.penalty;
        poolExpWad[curCyc] += ec.poolExp;
        poolActWad[curCyc] += act;
    }

    // ------------------------------------------------------------------ artifacts

    function _finalCheckpoint(uint256 pxEnd) internal {
        uint256 latest = pool.intervalCount() - 1;
        for (uint256 j = 0; j < cohorts.length; j++) {
            if (j == 1) continue;
            Cohort storage c = cohorts[j];
            if (c.cumDepWad == 0) continue;
            _recordCk(j, ts[ts.length - 1], pxEnd, latest);
            _trackEquity(j);
        }
    }

    // ------------------------------------------------------------------ formatting

    function _tsToDate(uint256 t) internal pure returns (string memory) {
        uint256 z = t / 86400 + 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 d = doy - (153 * mp + 2) / 5 + 1;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y += 1;
        return string.concat(_pad(y, 4), "-", _pad(m, 2), "-", _pad(d, 2));
    }

    function _pad(uint256 v, uint256 w) internal pure returns (string memory s) {
        s = vm.toString(v);
        while (bytes(s).length < w) s = string.concat("0", s);
    }

    function _outPath(string memory kind) internal view returns (string memory) {
        return string.concat("test/backtest/out/sim_", shardTag, kind);
    }

    // ------------------------------------------------------------------ series CSV

    function _writeSeriesRow(uint256 j, uint256 i, uint256 pxWad) internal {
        Cohort storage c = cohorts[j];
        if (c.cumDepWad == 0) return;
        uint256 eq6 = (c.v.navWad() + c.cumClaimsWad) * 1e6 / c.cumDepWad;
        string memory line = string.concat(
            _tsToDate(ts[i]),
            ",",
            vm.toString(rWad * 100 / 1e18),
            ",",
            _stratName(stratIdx),
            ",",
            c.tag,
            ",",
            vm.toString(pxWad / 1e12), // price x1e6 USD
            ",",
            vm.toString(eq6),
            ",",
            vm.toString(_hodl6(j, pxWad)),
            ",",
            vm.toString(c.maxDDbp)
        );
        vm.writeLine(_outPath("_series.csv"), line);
    }

    // ------------------------------------------------------------------ summary JSONL

    function _writeSummary(uint256 pxEnd) internal {
        console.log("");
        console.log(
            string.concat(
                "=== shard ", shardTag, " - scenario table (x1e6 multiples, bp shares) ==="
            )
        );
        console.log("entryDate  entry     finalX1e6  hodlX1e6  poolContribX1e6  shareBp  maxDDbp");
        for (uint256 j = 0; j < cohorts.length; j++) {
            if (j == 1) continue;
            Cohort storage c = cohorts[j];
            if (c.cumDepWad == 0) continue;
            uint256 fin6 = (c.v.navWad() + c.cumClaimsWad) * 1e6 / c.cumDepWad;
            uint256 pool6 = c.cumClaimsWad * 1e6 / c.cumDepWad;
            string memory strat = c.kind == K_MEASURED ? _stratName(stratIdx) : "B4";
            console.log(
                string.concat(
                    _tsToDate(c.entryTs),
                    "  ",
                    c.tag,
                    "  ",
                    strat,
                    "  final=",
                    vm.toString(fin6),
                    "  hodl=",
                    vm.toString(_hodl6(j, pxEnd)),
                    "  pool=",
                    vm.toString(pool6),
                    "  shareBp=",
                    vm.toString(c.lastShareBp),
                    "  maxDDbp=",
                    vm.toString(c.maxDDbp)
                )
            );
            string memory line = _scenarioJson(j, strat, fin6, pool6, pxEnd);
            vm.writeLine(_outPath("_summary.jsonl"), line);
        }
    }

    function _scenarioJson(
        uint256 j,
        string memory strat,
        uint256 fin6,
        uint256 pool6,
        uint256 pxEnd
    ) internal view returns (string memory) {
        Cohort storage c = cohorts[j];
        string memory part1 = string.concat(
            "{\"entryDate\":\"",
            _tsToDate(c.entryTs),
            "\",\"entryTag\":\"",
            c.tag,
            "\",\"strategy\":\"",
            strat,
            "\",\"r\":",
            vm.toString(rWad * 100 / 1e18),
            ",\"finalMultipleX1e6\":",
            vm.toString(fin6),
            ",\"hodlMultipleX1e6\":",
            vm.toString(_hodl6(j, pxEnd)),
            ",\"poolPayoutContributionX1e6\":",
            vm.toString(pool6)
        );
        string memory part2 = string.concat(
            ",\"shareOfPoolBp\":",
            vm.toString(c.lastShareBp),
            ",\"weightGrowthX1e6\":",
            vm.toString(c.firstWeightWad == 0 ? 0 : c.lastWeightWad * 1e6 / c.firstWeightWad),
            ",\"maxDrawdownBp\":",
            vm.toString(c.maxDDbp),
            ",\"cumDepositsWad\":\"",
            vm.toString(c.cumDepWad),
            "\",\"finalNavWad\":\"",
            vm.toString(c.v.navWad()),
            "\",\"cumClaimsWad\":\"",
            vm.toString(c.cumClaimsWad),
            "\""
        );
        string memory line = string.concat(
            part1,
            part2,
            ",\"firstWeightWad\":\"",
            vm.toString(c.firstWeightWad),
            "\",\"lastWeightWad\":\"",
            vm.toString(c.lastWeightWad),
            "\",\"checkpoints\":["
        );
        for (uint256 k = 0; k < c.cks.length; k++) {
            Ck storage ck = c.cks[k];
            if (k > 0) line = string.concat(line, ",");
            line = string.concat(
                line,
                "{\"date\":\"",
                _tsToDate(ck.t),
                "\",\"priceUsdX1e6\":",
                vm.toString(ck.pxWad / 1e12),
                ",\"equityMultipleX1e6\":",
                vm.toString(ck.eq6),
                ",\"hodlMultipleX1e6\":",
                vm.toString(ck.hodl6),
                ",\"cumPoolPayoutWad\":\"",
                vm.toString(ck.claimsWad),
                "\",\"weightBp\":",
                vm.toString(ck.shareBp),
                "}"
            );
        }
        return string.concat(line, "]}");
    }

    // ------------------------------------------------------------------ penalty tables

    function _effRatios(uint256 c)
        internal
        view
        returns (uint256 effStayer, uint256 effAll, uint256 freeShare)
    {
        uint256 stayerFlow = cycStayerFlowWad[c];
        uint256 nonExiterFlow = cycNonExiterFlowWad[c];
        effStayer = stayerFlow == 0 ? 0 : poolActWad[c] * 10_000 / stayerFlow;
        effAll = nonExiterFlow == 0 ? 0 : poolActWad[c] * 10_000 / nonExiterFlow;
        uint256 tot = freeGrossWad[c] + penGrossWad[c];
        freeShare = tot == 0 ? 0 : freeGrossWad[c] * 10_000 / tot;
    }

    function _logPenaltyCycle(uint256 c, uint256 theoryBp) internal view {
        (uint256 effStayer, uint256 effAll, uint256 freeShare) = _effRatios(c);
        string memory p1 = string.concat(
            "cycle ",
            vm.toString(c + 1),
            ": penGross=",
            vm.toString(penGrossWad[c] / 1e18),
            " freeGross=",
            vm.toString(freeGrossWad[c] / 1e18),
            " penalty=",
            vm.toString(penWad[c] / 1e18),
            " penOpCut=",
            vm.toString(penOpCutWad[c] / 1e18)
        );
        console.log(
            string.concat(
                p1,
                " freeOpCut=",
                vm.toString(freeOpCutWad[c] / 1e18),
                " poolExp=",
                vm.toString(poolExpWad[c] / 1e18),
                " poolAct=",
                vm.toString(poolActWad[c] / 1e18),
                " claimsLanded=",
                vm.toString(claimsLandedWad[c] / 1e18)
            )
        );
        console.log(
            string.concat(
                "  freeShareBp=",
                vm.toString(freeShare),
                "  effPool/StayerFlowBp=",
                vm.toString(effStayer),
                "  effPool/AllNonExiterFlowBp=",
                vm.toString(effAll),
                "  theoryBp=",
                vm.toString(theoryBp)
            )
        );
    }

    function _penaltyCycleJson(uint256 c, uint256 theoryBp) internal view returns (string memory) {
        (uint256 effStayer, uint256 effAll,) = _effRatios(c);
        string memory p1 = string.concat(
            "{\"cycle\":",
            vm.toString(c + 1),
            ",\"penGrossWad\":\"",
            vm.toString(penGrossWad[c]),
            "\",\"freeGrossWad\":\"",
            vm.toString(freeGrossWad[c]),
            "\",\"penaltyWad\":\"",
            vm.toString(penWad[c]),
            "\",\"penalizedOperatorCutWad\":\"",
            vm.toString(penOpCutWad[c]),
            "\",\"freeExitOperatorCutWad\":\"",
            vm.toString(freeOpCutWad[c]),
            "\""
        );
        string memory p2 = string.concat(
            ",\"poolExpectedWad\":\"",
            vm.toString(poolExpWad[c]),
            "\",\"poolActualWad\":\"",
            vm.toString(poolActWad[c]),
            "\",\"claimsLandedWad\":\"",
            vm.toString(claimsLandedWad[c]),
            "\""
        );
        return string.concat(
            p1,
            p2,
            ",\"effPoolPerStayerFlowBp\":",
            vm.toString(effStayer),
            ",\"effPoolPerNonExiterFlowBp\":",
            vm.toString(effAll),
            ",\"theoryBp\":",
            vm.toString(theoryBp),
            "}"
        );
    }

    function _logPenaltyTables() internal {
        uint256 theoryBp = rWad * Phi.EXIT_Q / (1e18 - rWad) / 1e14; // r*q/(1-r) in bp
        console.log("");
        console.log(
            string.concat("=== shard ", shardTag, " - penalty verification per cycle (WAD USD) ===")
        );
        console.log(string.concat("theory r*q/(1-r) bp/cycle: ", vm.toString(theoryBp)));
        string memory pline = string.concat("{\"shard\":\"", shardTag, "\",\"cycles\":[");
        uint256 endCyc = oracle.epoch() < 4 ? oracle.epoch() : 3;
        for (uint256 c = 0; c <= endCyc && c < 4; c++) {
            // The expected pool leg is exactly the non-free penalty less the operator
            // carve. Physical token amounts can round down in kind, so actual receipt
            // is deliberately bounded above by the WAD split and reported separately.
            assertEq(poolExpWad[c], penWad[c] - penOpCutWad[c], "penalty pool conservation");
            assertLe(poolActWad[c], poolExpWad[c], "in-kind pool cannot exceed WAD split");
            _logPenaltyCycle(c, theoryBp);
            if (c > 0) pline = string.concat(pline, ",");
            pline = string.concat(pline, _penaltyCycleJson(c, theoryBp));
        }
        // undistributed tail: penalties accrued after the last materialized point
        uint256 pxEnd = _pxLive(ts[ts.length - 1]);
        uint256 tail = pool.accruing(0) * 1e12 + pool.accruing(1) * 1e10 * pxEnd / 1e18;
        pline = string.concat(pline, "],\"undistributedTailWad\":\"", vm.toString(tail), "\"}");
        vm.writeLine(_outPath("_penalty.json"), pline);
        console.log(
            string.concat("undistributed tail in accruing (USD): ", vm.toString(tail / 1e18))
        );
        // Full-period normalized HODL DCA cross-check (the lump reference is ~5,214x).
        Hodl storage h0 = hodls[0];
        uint256 hodlFull6 = h0.btcWad * pxEnd / 1e18 * 1e6 / h0.depWad;
        console.log(
            string.concat(
                "cross-check: full-period $10/day normalized DCA HODL x1e6 = ",
                vm.toString(hodlFull6),
                " (lump-at-h0 reference ~5214x by design differs)"
            )
        );
    }

    // ------------------------------------------------------------------ shards

    function _initFiles() internal {
        vm.writeFile(_outPath("_summary.jsonl"), "");
        vm.writeFile(
            _outPath("_series.csv"),
            "date,r,strategy,entry,price_usd_x1e6,eq_mult_x1e6,hodl_mult_x1e6,max_dd_bp\n"
        );
        vm.writeFile(_outPath("_penalty.json"), "");
    }

    /// Full shard runner; asserts the whole schedule was consumed.
    function _shard(uint256 rWad_, uint256 strat_, string memory tag) internal {
        shardTag = tag;
        _initFiles();
        _runShard(rWad_, strat_, tag, 0);
        assertEq(pool.intervalCount(), pts.length, "every settlement point materialized");
    }

    function preliminary_sim_r20_b4() public {
        _shard(0.2e18, 0, "r20_b4");
    }

    function preliminary_sim_r20_pro() public {
        _shard(0.2e18, 1, "r20_pro");
    }

    function preliminary_sim_r20_promax() public {
        _shard(0.2e18, 2, "r20_promax");
    }

    function preliminary_sim_r10_b4() public {
        _shard(0.1e18, 0, "r10_b4");
    }

    function preliminary_sim_r10_pro() public {
        _shard(0.1e18, 1, "r10_pro");
    }

    function preliminary_sim_r10_promax() public {
        _shard(0.1e18, 2, "r10_promax");
    }

    /// Short probe: first ~720 days (covers settle #1, the P transition, settle #2 and
    /// interval-0 claims) to validate mechanics and extrapolate shard timing.
    function preliminary_sim_zzprobe() public {
        shardTag = "probe";
        _initFiles();
        _runShard(0.2e18, 0, "probe", 1040);
    }
}
