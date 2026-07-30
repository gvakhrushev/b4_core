// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";

/// @notice Regression for AUDIT-2026-07-29 F2 — the peak-anchor daily slot could be SQUATTED.
///
/// M-3's first remedy tied the peak VALUE to the density counter's daily slot, so the value
/// belonged to whoever called first after `last + 1 day`. An attacker taking every slot at an
/// intraday low had every honest observation of the true high refused (`counted == false`) while
/// their own samples kept the count and span growing — so `peaks()` served a density-CONFIRMED
/// but systematically SUPPRESSED `peakC`. Suppressing `C` in
/// `shortStructStop = C + (C − Pp)/φ` pulls the stop toward the price and RAISES every
/// structural short's leverage: the anti-conservative direction the mechanism exists to prevent.
///
/// The audit itself recorded that the daily gate alone was insufficient and asked for a
/// dispersion remedy that was never built (REVIEW-2026-07-25 item 11, "Finish M-3's peak side").
/// Both halves now exist and are pinned here:
///   * the value binds only inside the daily CLOSE window, on a grid fixed to the peak window's
///     own opening — so it is not owned by whoever calls first, and an off-close wick cannot
///     bind at all;
///   * a level must be reached at TWO distinct closes before it is served or promoted — so a
///     print that does land at a close is still worthless on its own.
contract AuditF2_PeakSlotSquatTest is VaultTestBase {
    uint256 constant DIR = 1;

    address constant SQUATTER = address(0xF2515);
    address constant HONEST = address(0xF2ABC);

    function setUp() public {
        setUpProtocol();
    }

    function _setPx(uint256 usd) internal {
        hub.setSpotPx(SPOT_MKT, uint64(usd * 1e4));
    }

    function _peakC() internal view returns (uint256) {
        (, uint256 c,) = pool.peaks(DIR);
        return c;
    }

    /// The k-th daily close of the peak window, absolute time. The grid is anchored to the
    /// window's opening, so close k is exactly `P − W + k days`.
    function _close(uint256 k) internal pure returns (uint256) {
        return GENESIS_TS + Calendar.P - Calendar.W + k * 1 days;
    }

    /// THE ATTACK. The squatter takes every daily slot first, at a low; the honest keeper follows
    /// within the same close window with the real market price. Before the fix the squatter's low
    /// became the confirmed anchor; now the honest observation lands regardless of who was first.
    function test_F2_slot_squatter_cannot_suppress_the_true_peak() public {
        for (uint256 k = 1; k <= 12; k++) {
            // Squatter is always first, always at a low.
            vm.warp(_close(k));
            _setPx(90_000);
            vm.prank(SQUATTER);
            pool.sampleAnchor(DIR);

            // Honest keeper, seconds later — still inside the close window — at the true high.
            vm.warp(_close(k) + 5 minutes);
            _setPx(110_000);
            vm.prank(HONEST);
            pool.sampleAnchor(DIR);
        }

        (, bool peakConfirmed) = pool.anchorConfirmed(DIR);
        assertTrue(peakConfirmed, "the window is density-confirmed either way");
        assertEq(_peakC(), 110_000e18, "the honest high is recorded, not the squatter's low");
    }

    /// The harm the suppression caused, stated as leverage rather than as a number: a suppressed
    /// peak moves the structural stop toward the entry price and levers the short UP. Pinning the
    /// direction keeps any future change to the anchor honest.
    function test_F2_suppression_would_have_raised_short_leverage() public {
        uint256 entry = 80_000e18;
        uint256 prevPeak = 69_000e18;
        uint256 honestStop = StructuralLeverage.shortStructStop(entry, prevPeak, 110_000e18);
        uint256 suppressedStop = StructuralLeverage.shortStructStop(entry, prevPeak, 90_000e18);

        assertLt(suppressedStop, honestStop, "a suppressed peak pulls the stop toward price");
        assertGt(
            StructuralLeverage.shortStructLev(entry, prevPeak, 90_000e18),
            StructuralLeverage.shortStructLev(entry, prevPeak, 110_000e18),
            "and therefore RAISES leverage: the anti-conservative direction"
        );
    }

    /// An off-close print cannot bind at all, whoever makes it and however often. This is the
    /// ordinary exchange wick, and it is the cheap arm of M-3.
    function test_F2_off_close_print_never_binds() public {
        for (uint256 k = 1; k <= 12; k++) {
            vm.warp(_close(k));
            _setPx(50_000);
            pool.sampleAnchor(DIR);
        }
        assertEq(_peakC(), 50_000e18, "honest closes confirmed");

        // Mid-day, far from any close: spam a wick.
        vm.warp(_close(12) + 11 hours);
        _setPx(500_000);
        pool.sampleAnchor(DIR);
        pool.sampleAnchor(DIR);
        pool.sampleAnchor(DIR);
        assertEq(_peakC(), 50_000e18, "an off-close wick cannot move the anchor");
    }

    /// The window OPENING is not a free anchor either. It used to be: the reseed took whatever
    /// the first caller into the window read, with no cadence condition at all, and since the
    /// value only ratchets up a wick at that instant survived all 20 days.
    function test_F2_window_opening_is_not_a_free_anchor() public {
        // First caller into the window, mid-day, at an absurd price.
        vm.warp(_close(0) + 7 hours);
        _setPx(900_000);
        pool.sampleAnchor(DIR);
        assertEq(_peakC(), 0, "the opening observation is not served");

        // An honest fortnight of closes decides the anchor instead.
        for (uint256 k = 1; k <= 12; k++) {
            vm.warp(_close(k));
            _setPx(50_000);
            pool.sampleAnchor(DIR);
        }
        assertEq(_peakC(), 50_000e18, "the honest closes decide it");
    }

    /// A single at-close print — the expensive arm, where the attacker manages to hit the
    /// published close instant — is still worthless without a second close at the same level.
    function test_F2_single_at_close_print_needs_corroboration() public {
        for (uint256 k = 1; k <= 12; k++) {
            vm.warp(_close(k));
            _setPx(50_000);
            pool.sampleAnchor(DIR);
        }

        vm.warp(_close(13));
        _setPx(500_000);
        pool.sampleAnchor(DIR);
        assertEq(_peakC(), 50_000e18, "one at-close print is a candidate, not an anchor");

        // Two distinct closes at the level is the documented cost of moving the anchor.
        vm.warp(_close(14));
        _setPx(500_000);
        pool.sampleAnchor(DIR);
        assertEq(_peakC(), 500_000e18, "two do move it: stated, not hidden");
    }
}
