// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";
import {Phi} from "src/libraries/Phi.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice V8 Scope A, item 6: the 0 < n < 1 spot interlude. Pro Max ClosingGrowth ramps
///         the target phi -> 0, crossing n = 1: perp-only -> SPOT-only -> zero at the
///         settlement point, then OpeningFall ramps the short up. The engine must
///         choreograph perp-reduce -> perp-close -> margin-return -> spot-buy(n*v) ->
///         spot-sell -> short-open with no value leak, no wrong-sign state, and never a
///         steady state holding spot-BTC alongside perp margin exposure.
contract V8A_SpotInterludeTest is VaultTestBase {
    uint256 constant DIR = 1;

    function setUp() public {
        setUpProtocol();
    }

    function readPos(address who) internal view returns (CoreTypes.Position memory) {
        (bool ok, bytes memory ret) =
            CoreTypes.PRECOMPILE_POSITION.staticcall(abi.encode(who, uint16(PERP_MKT)));
        require(ok, "read pos");
        return abi.decode(ret, (CoreTypes.Position));
    }

    function _setPx(uint256 usd) internal {
        hub.setSpotPx(SPOT_MKT, uint64(usd * 1e4));
        hub.setMarkPx(PERP_MKT, uint64(usd * 1e2));
        hub.setOraclePx(PERP_MKT, uint64(usd * 1e2));
    }

    function _dirValWad(B4Vault v, uint256 pxWad) internal view returns (uint256) {
        uint256 tokensWad =
            Phi.mulDiv(v.dirEvm(), Phi.WAD, 1e8) + Phi.mulDiv(v.coreDirWei(), Phi.WAD, 1e8);
        return Phi.wmul(tokensWad, pxWad);
    }

    function test_V8A_closing_growth_interlude_choreography_no_leak() public {
        warpTo(300 days); // Growth plateau
        _setPx(100_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        assertGt(readPos(address(v)).szi, 0, "phi long open");
        uint256 nav0 = v.navWad();
        assertEq(nav0, 120_000e18, "NAV baseline");

        // Walk the transition day by day: ClosingGrowth [P-W, P-H) -> OpeningFall [P-H, P)
        // -> Fall. Price slides 100k -> 70k across the window (the fall the short profits
        // from). At every idle step: never spot-BTC next to a live perp, never wrong-sign.
        bool sawSpotOnly;
        bool sawFlatAtSettlement;
        uint256 frozenShortStop;
        bool shortSeen;
        for (uint256 d = 0; d <= 32; d++) {
            uint256 t = Calendar.P - Calendar.W - 2 days + d * 1 days;
            warpTo(t);
            // Gentle decline across the 32 days.
            _setPx(100_000 - (30_000 * d) / 32);
            crankUntilIdle(v, 60);

            CoreTypes.Position memory p = readPos(address(v));
            (, int256 perpF) =
                Calendar.decompose(Calendar.targetAt(t, int256(Phi.PHI), -int256(Phi.PHI)));
            uint256 dirVal = _dirValWad(v, (100_000 - (30_000 * d) / 32) * 1e18);

            // Sign discipline: any live perp matches the target sign.
            if (p.szi != 0 && perpF != 0) {
                assertEq(p.szi > 0, perpF > 0, "wrong-sign perp at idle");
            }
            // The one-capital invariant: a live perp leaves no spot-BTC behind (>$10).
            if (p.szi != 0) {
                assertLe(dirVal, 10e18, "spot BTC held alongside perp margin");
            }
            if (p.szi == 0 && perpF == 0 && dirVal > 10e18) {
                sawSpotOnly = true; // the spot interlude actually happened
            }

            if (t == Calendar.P - Calendar.H) {
                sawFlatAtSettlement = p.szi == 0 && v.perpMargin6() == 0;
            }
            if (p.szi < 0 && !shortSeen) {
                shortSeen = true;
                frozenShortStop = v.perpStopWad(); // first-slice S-win freeze
            }
        }

        assertTrue(sawSpotOnly, "the 0<n<1 spot interlude was exercised");
        assertTrue(sawFlatAtSettlement, "fully unwound + margin home at the settlement point");

        // End state (Fall, px 70k): the short is open on the whole NAV, still pinned to
        // the stop it froze at its first S-win slice (NOT re-derived at the lower price).
        CoreTypes.Position memory p = readPos(address(v));
        assertLt(p.szi, 0, "short open in Fall");
        assertTrue(shortSeen, "short opened during the walk");
        uint256 stop = v.perpStopWad();
        assertFalse(v.perpStopLong(), "short side frozen");
        assertEq(stop, frozenShortStop, "freeze held across the whole window + Fall boundary");
        assertApproxEqRel(
            uint256(v.perpMargin6()) * 1e12, v.navWad(), 0.02e18, "whole NAV short margin"
        );
        // And the realized venue liquidation sits on that frozen stop.
        uint256 liq = Phi.mulDiv(
            (uint256(p.entryNtl) + v.perpMargin6()) * 1e4, Phi.WAD, uint256(uint64(-p.szi)) * 1e6
        );
        assertApproxEqRel(liq, stop, 0.01e18, "realized short liq on the frozen stop");

        // No value leak: the long rode 100k -> ~76k before unwinding (a real trading loss
        // is honest), but NAV must not have GROWN (no phantom minting, no wrong-sign win),
        // and the loss is bounded by the long's notional over the slide (~2x NAV worst).
        uint256 nav1 = v.navWad();
        assertLe(nav1, nav0 + nav0 / 100, "NAV grew through a falling window: leak/wrong-sign");
        assertGt(nav1, nav0 / 2, "loss beyond the position's honest downside");
    }
}
