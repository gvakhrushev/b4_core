// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {Calendar} from "src/libraries/Calendar.sol";

/// @notice A state that could not exist before the close-window / corroboration split: the peak
///         window is DENSITY-confirmed while no value was ever corroborated.
///
/// Density counts observations; the value binds only at a daily close, and only once two distinct
/// closes reach it. A keeper that samples daily but always mid-day therefore satisfies the density
/// gate and never binds a close — the window ends confirmed, with `peakC == 0`.
///
/// It is fail-safe for the engine: a zero peak reads as "absent", so a leveraged short falls back
/// to the flat base exactly as an under-sampled window does, and the promotion into `prevPeak`
/// carries the zero rather than a stale higher value — a LOWER `Pp` widens `(C - Pp)`, pushing the
/// stop further out, which is the conservative direction. What it is not is a state an operator
/// should be told is healthy, which is why `anchorConfirmed` reports the served value and not just
/// the count.
contract AuditF2_ConfirmedWithoutValueTest is VaultTestBase {
    uint256 constant DIR = 1;

    function setUp() public {
        setUpProtocol();
    }

    function _close(uint256 k) internal pure returns (uint256) {
        return GENESIS_TS + Calendar.P - Calendar.W + k * 1 days;
    }

    function test_density_can_confirm_while_no_close_was_ever_corroborated() public {
        // A keeper that samples daily but always MID-DAY: density counts, closes never bind.
        for (uint256 k = 1; k <= 12; k++) {
            vm.warp(_close(k) + 11 hours);
            hub.setSpotPx(SPOT_MKT, uint64(50_000 * 1e4));
            pool.sampleAnchor(DIR);
        }
        (, bool peakConfirmed) = pool.anchorConfirmed(DIR);
        (, uint256 peakC,) = pool.peaks(DIR);
        assertEq(peakC, 0, "no close was ever corroborated, so nothing is served");
        assertFalse(peakConfirmed, "and the getter must not call that confirmed");

        // Sampling the SAME window at its closes does confirm it — the flag tracks the value.
        for (uint256 k = 1; k <= 3; k++) {
            vm.warp(_close(12 + k));
            hub.setSpotPx(SPOT_MKT, uint64(50_000 * 1e4));
            pool.sampleAnchor(DIR);
        }
        (, peakConfirmed) = pool.anchorConfirmed(DIR);
        (, peakC,) = pool.peaks(DIR);
        assertEq(peakC, 50_000e18, "closes bind the value");
        assertTrue(peakConfirmed, "and only then is it confirmed");
    }
}
