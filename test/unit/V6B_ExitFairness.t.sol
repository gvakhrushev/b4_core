// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice V6 scope B, item 2(b)/2(d): adversarial quantification of the exit-fairness
///         critic ("exiter redeems at full recorded margin while a held perp carries
///         hidden losses, dumping them on stayers") and of the settle/exit phi-rounding
///         waterfall ("repeated settle+exit drains or inflates").
contract V6B_ExitFairnessTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    function p1() internal pure returns (uint256) {
        return Calendar.P - Calendar.H;
    }

    function readSzi(address who) internal view returns (int64) {
        (bool ok, bytes memory ret) =
            CoreTypes.PRECOMPILE_POSITION.staticcall(abi.encode(who, uint16(PERP_MKT)));
        require(ok, "read");
        CoreTypes.Position memory p = abi.decode(ret, (CoreTypes.Position));
        return p.szi;
    }

    // --------------------------------------------------------------- 2(b) exit fairness

    /// Critic #2 attempted on current code: open a leveraged long, crash the venue 30%,
    /// exit 50% BEFORE any reconcile. If the critic were right, the exiter would redeem
    /// against the full recorded 2,500 USD perp margin and the hidden loss would land on
    /// the remaining share. Measures exactly what the exiter carries vs what stays.
    function test_V6B_2b_exit_realizes_hidden_loss_before_payment() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 1e8, 20_000e6); // 1 BTC ($100k) + $20k USDC, all strategy capital; E = $120k
        crankUntilIdle(v, 40);
        int64 szi = readSzi(address(v));
        assertGt(szi, 0); // pure φ perp long on the whole $120k strategy (SPEC §5)
        uint64 marginOpened = v.perpMargin6();
        // Structural §7b: the WHOLE $120k strategy is the margin (margin = notional/L, whole
        // deposit deployed — audit C6/C7), NOT the old flat-φ notional·φ/maxLev reserve.
        assertApproxEqAbs(
            uint256(marginOpened), 120_000e6, 500e6, "whole $120k deposit is the margin"
        );

        // Venue crashes 30% while the vault is idle. The perp carries a hidden unrealized loss;
        // the exit MUST realize it on the venue and reconcile it out of the NAV BEFORE paying —
        // the security property this test pins is sizing-independent (below).
        hub.setSpotPx(SPOT_MKT, 70_000e4);
        hub.setMarkPx(PERP_MKT, 70_000e2);

        vm.prank(user);
        v.initiateExit(5e17); // exit 50%, free window (t = 0 growth)

        uint256 ubtcUserBefore = ubtc.balanceOf(user);
        uint256 usdcUserBefore = usdc.balanceOf(user);

        _crankUntilExitDone(v, 40);
        assertEq(v.exitShareWad(), 0, "exit finalized");

        // The security property is sizing-independent (pinned relationally; exact amounts
        // change with the pure-perp φ sizing and again once §7b lands — PROPOSAL-pure-perp-promax):
        // 1. The hidden loss was REALIZED on the venue by the exit's own flatten.
        assertGt(hub.realizedLoss6(address(v)), 0, "venue realized the hidden loss");
        // 2. The recorded margin was written down to actual withdrawable BEFORE valuation — no
        //    phantom margin entered the exit NAV.
        assertEq(v.perpMargin6(), 0, "margin reconciled to zero");
        // 3. Symmetry: the exiter's proceeds value == the stayer's remainder — nothing was
        //    dumped on stayers (a 50% exit splits the post-loss NAV in half).
        uint256 exiterDir = ubtc.balanceOf(user) - ubtcUserBefore;
        uint256 exiterUsdc = usdc.balanceOf(user) - usdcUserBefore;
        uint256 exiterValueWad = exiterDir * 70_000e18 / 1e8 + exiterUsdc * 1e12;
        assertGt(exiterValueWad, 0, "exiter paid in kind");
        assertApproxEqRel(
            v.navWad(), exiterValueWad, 0.01e18, "stayer remainder == exiter proceeds"
        );
        assertEq(v.entryLedgerWad(), 60_000e18, "entry scaled by (1-x)");
        // 4. No fee/weight on a loss exit.
        assertEq(v.rewardBaseWad(), 0);
        assertEq(ubtc.balanceOf(operator), 0);
        assertEq(usdc.balanceOf(operator), 0);
    }

    // --------------------------------------------------------------- 2(d) waterfall

    /// Rounding-waterfall attack: settle with profit (fee split + weight), then three
    /// free dust exits (x = 10%) and one PENALTY exit (pool leg + capture). After every
    /// step assert (i) ledger writes match the SPEC §8/§9 formulas EXACTLY, (ii) token
    /// flow per exit is conservative (recipient deltas == bucket decrements, dust ≤ a
    /// few wei and stays in the vault), (iii) reward weight is never re-reported or
    /// duplicated by exits. Mini vault (spot-only, no trades) so the in-kind dir leg of
    /// _payBucket is exercised with live profit at every exit.
    /// V8-L-8: each exit is measured AT FINALIZATION (`_crankUntilExitDone`), not after
    /// cranking to idle — post pure-perp routing the sync planner redeploys the remaining
    /// rotated USDC into spot (decompose(1) → spot 1, USDC deposits are strategy capital),
    /// so an idle-boundary measurement would count that legitimate redeployment as exit
    /// "dust" (the phantom 17,784 USDC; V8 refutation: per-exit bucket decrements ==
    /// recipient deltas EXACTLY on all 4 exits).
    function test_V6B_2d_settle_exit_waterfall_conservation() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 20_000e6); // E = 120k; dir held, margin parked

        // +20% into the checkpoint.
        hub.setSpotPx(SPOT_MKT, 120_000e4);
        warpTo(p1());
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);
        v.settle(id);

        // Post-settle anchors: nav = 140,000 USD; E re-anchored to nav − operatorCut.
        uint256 nav0 = 140_000e18;
        uint256 profit0 = nav0 - 120_000e18;
        uint256 vf0 = Phi.wmul(profit0, Phi.FEE_F);
        uint256 oc0 = Phi.bps(vf0, 3000);
        uint256 cs0 = vf0 - oc0;
        assertEq(v.entryLedgerWad(), nav0 - oc0, "settle re-anchor exact");
        assertEq(v.rewardBaseWad(), cs0, "client share retained");
        assertEq(pool.weightOf(id, address(v)), cs0, "weight reported once");
        assertGt(ubtc.balanceOf(operator) + ubtc.balanceOf(referrer), 0, "fee paid in kind");

        // Live price runs to 130k AFTER the lock: every exit now carries real profit
        // (live-oracle valuation, decision C2) → real operator carve per exit.
        hub.setSpotPx(SPOT_MKT, 130_000e4);
        uint256 weightBefore = pool.weightOf(id, address(v));

        // Three free dust exits x = 10% (OpeningFall zone: free).
        for (uint256 i; i < 3; i++) {
            _exitOnce(v, id, weightBefore, false);
        }

        // Fourth exit OUTSIDE the free window (Fall zone): penalty leg, operator carve,
        // pool remainder + capture(). Same conservation discipline, pool share > 0.
        warpTo(Calendar.P + 1 days);
        _exitOnce(v, id, weightBefore, true);
    }

    function _usdcOpRef() internal view returns (uint256) {
        return usdc.balanceOf(operator) + usdc.balanceOf(referrer);
    }

    function _ubtcOpRef() internal view returns (uint256) {
        return ubtc.balanceOf(operator) + ubtc.balanceOf(referrer);
    }

    function _ubtcSum() internal view returns (uint256) {
        return ubtc.balanceOf(user) + ubtc.balanceOf(operator) + ubtc.balanceOf(referrer)
            + ubtc.balanceOf(address(pool));
    }

    /// One x = 10% exit with full waterfall assertions, measured at finalization (see the
    /// test's V8-L-8 note: the post-exit spot redeployment must NOT be counted as exit
    /// dust). expectPool=false for a free window (pool share must be exactly 0), true for
    /// a penalty exit (pool share > 0).
    function _exitOnce(B4Vault v, uint256 id, uint256 weightBefore, bool expectPool) internal {
        uint256 cs = _clientShareNow(v);
        uint256[4] memory pre =
            [v.entryLedgerWad(), v.usdcRotatedEvm() + v.usdcMarginEvm(), _usdcSum(), _ubtcSum()];
        uint256 rPre = v.rewardBaseWad();
        uint256 userPre = usdc.balanceOf(user) + ubtc.balanceOf(user);
        uint256 opRefPre = _usdcOpRef() + _ubtcOpRef();
        uint256 poolPre = usdc.balanceOf(address(pool)) + ubtc.balanceOf(address(pool));

        vm.prank(user);
        v.initiateExit(0.1e18);
        _crankUntilExitDone(v, 20);
        _checkExit(v, id, weightBefore, expectPool, cs, rPre, pre, userPre, opRefPre, poolPre);
    }

    function _checkExit(
        B4Vault v,
        uint256 id,
        uint256 weightBefore,
        bool expectPool,
        uint256 cs,
        uint256 rPre,
        uint256[4] memory pre,
        uint256 userPre,
        uint256 opRefPre,
        uint256 poolPre
    ) internal {
        assertEq(v.exitShareWad(), 0);
        // (i) SPEC §9 ledger formulas, exact.
        assertEq(v.entryLedgerWad(), Phi.wmul(pre[0], 0.9e18), "entry formula");
        assertEq(
            v.rewardBaseWad(), Phi.wmul(rPre + Phi.wmul(cs, 0.1e18), 0.9e18), "rewardBase formula"
        );
        // (ii) conservative token flow per exit: recipients == bucket decrement,
        //      rounding dust bounded and left in the vault (B5).
        assertLe(
            _usdcSum() - pre[2],
            pre[1] - v.usdcRotatedEvm() - v.usdcMarginEvm(),
            "no usdc over-payment"
        );
        assertLe(
            pre[1] - v.usdcRotatedEvm() - v.usdcMarginEvm() - (_usdcSum() - pre[2]),
            10,
            "usdc dust bounded, stays in vault"
        );
        // (iii) owner and operator carve paid; pool share only outside the free window.
        assertGt(usdc.balanceOf(user) + ubtc.balanceOf(user), userPre, "owner paid");
        assertGt(_usdcOpRef() + _ubtcOpRef(), opRefPre, "operator carve paid");
        uint256 poolDelta = usdc.balanceOf(address(pool)) + ubtc.balanceOf(address(pool)) - poolPre;
        if (expectPool) {
            assertGt(poolDelta, 0, "pool received penalty share in kind");
        } else {
            assertEq(poolDelta, 0, "no pool share in a free exit");
        }
        // (iv) exits never re-report or duplicate weight.
        assertEq(pool.weightOf(id, address(v)), weightBefore, "no exit-time report");
    }

    /// Crank until the pending exit finalizes (a partial exit leaves the vault live —
    /// the sync planner immediately re-establishes target exposure, so cranking to
    /// idle would measure the RE-OPENED position, not the exit's own outcome).
    function _crankUntilExitDone(B4Vault v, uint256 maxSteps) internal {
        for (uint256 i; i < maxSteps && v.exitShareWad() != 0; i++) {
            v.crank();
        }
    }

    function _clientShareNow(B4Vault v) internal view returns (uint256) {
        uint256 e = v.entryLedgerWad();
        uint256 nav = v.navWad();
        uint256 profit = nav > e ? nav - e : 0;
        uint256 vf = Phi.wmul(profit, Phi.FEE_F);
        return vf - Phi.bps(vf, 3000);
    }

    function _usdcSum() internal view returns (uint256) {
        return usdc.balanceOf(user) + usdc.balanceOf(operator) + usdc.balanceOf(referrer)
            + usdc.balanceOf(address(pool));
    }
}
