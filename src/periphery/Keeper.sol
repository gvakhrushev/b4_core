// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {B4Pool} from "../core/B4Pool.sol";
import {B4Vault} from "../core/B4Vault.sol";

/// @title Keeper — one permissionless crank for EVERY protocol step (HAZARDS G2).
/// @notice Advance-calendar, lock-prices, capture, sweep, per-vault verify/sync/
///         progress-exit/finalize (all inside vault.crank), settle, and distribute.
///         A keeper has no privilege: every call it makes is permissionless liveness
///         (F2) — it cannot choose targets, markets, prices or recipients. Steps are
///         wrapped in try/catch so one unavailable step never strands the rest.
contract Keeper {
    /// Bounded catch-up window for sweeping expired-unswept intervals (2 points/epoch,
    /// so this covers many epochs of keeper downtime while keeping the loop bounded, F2).
    uint256 internal constant SWEEP_LOOKBACK = 16;

    event Cranked(address pool, uint256 vaults, uint256 stepsAdvanced);

    function crank(B4Pool pool, address[] calldata vaults, uint256 maxVaultSteps) external {
        uint256 advanced;

        // Calendar: materialize any passed settlement points (bounded by 2 per epoch).
        while (true) {
            try pool.advance() returns (bool moved) {
                if (!moved) break;
                advanced++;
            } catch {
                break;
            }
        }

        uint256 count = pool.intervalCount();
        if (count > 0) {
            try pool.lockPrices(count - 1) {
                advanced++;
            } catch {}
            // Sweep a bounded catch-up window, not just the one-back interval: if several
            // intervals materialized since the last keeper run, each expired-unswept one
            // must roll its inventory forward (G2 — crank EVERY step). sweep() is
            // idempotent (AlreadySwept/NotExpired revert into the try/catch), so this only
            // advances legitimate state. SWEEP_LOOKBACK ≫ any realistic keeper outage
            // (2 points/epoch), and is bounded so the loop can never grow unbounded (F2).
            uint256 window = count - 1 < SWEEP_LOOKBACK ? count - 1 : SWEEP_LOOKBACK;
            for (uint256 back = 2; back <= window + 1; back++) {
                try pool.sweep(count - back) {
                    advanced++;
                } catch {}
            }
        }
        try pool.capture() {} catch {}

        // Pool views wrapped in try/catch too: one malformed vault entry (or a transient
        // pool revert) must never roll back the whole crank — every step is isolated (F2).
        bool reportable;
        uint256 reportId;
        try pool.currentReportable() returns (bool r, uint256 id) {
            reportable = r;
            reportId = id;
        } catch {}

        for (uint256 i = 0; i < vaults.length; i++) {
            B4Vault v = B4Vault(vaults[i]);
            // Every per-vault call goes through an external SELF-call wrapper: a high-level
            // call on a codeless entry reverts via the compiler's extcodesize pre-check in
            // the CALLER's frame, which a local try/catch does NOT catch — inside a
            // self-call that revert stays within the external call and IS caught, so one
            // malformed entry can never roll back the whole crank (V4-VENUE-1).
            try this.crankVault(v, maxVaultSteps) returns (uint256 n) {
                advanced += n;
            } catch {}
            if (reportable) {
                try this.settleVault(v, reportId) returns (bool ok) {
                    if (ok) advanced++;
                } catch {}
            }
            // Distribute the latest interval (count-1). Older intervals are served while
            // they are the latest and are swept before they fall to count-2, so claiming
            // count-2 here is a no-op (V3-VENUE-5).
            if (count > 0) {
                try pool.claimFor(count - 1, vaults[i]) {
                    advanced++;
                } catch {}
            }
            // Isolated so a malformed vault entry can't revert the whole crank (V3-VENUE-1).
            try this.retryDeferred(v) returns (uint256 n) {
                advanced += n;
            } catch {}
        }
        emit Cranked(address(pool), vaults.length, advanced);
    }

    /// @dev External wrapper so the keeper can try/catch a whole per-vault crank burst —
    ///      including a codeless entry's extcodesize pre-check revert, which a try/catch
    ///      in the crank frame itself could NOT catch (V4-VENUE-1).
    function crankVault(B4Vault v, uint256 maxVaultSteps) external returns (uint256 advanced) {
        require(msg.sender == address(this), "self");
        for (uint256 s = 0; s < maxVaultSteps; s++) {
            try v.crank() returns (bool progressed) {
                if (!progressed) break;
                advanced++;
            } catch {
                break;
            }
        }
    }

    /// @dev External wrapper isolating a per-vault settle (same rationale as crankVault).
    function settleVault(B4Vault v, uint256 reportId) external returns (bool) {
        require(msg.sender == address(this), "self");
        v.settle(reportId);
        return true;
    }

    /// @dev External wrapper so the keeper can try/catch a per-vault deferred-payout sweep.
    function retryDeferred(B4Vault v) external returns (uint256) {
        require(msg.sender == address(this), "self");
        return _retryDeferred(v);
    }

    /// @dev Retry deferred payouts for every route participant on both accounted tokens.
    function _retryDeferred(B4Vault v) internal returns (uint256 advanced) {
        (address operator,, address referrer,) = v.route();
        address[4] memory recipients = [v.owner(), operator, referrer, v.pool()];
        address[2] memory tokens = [v.dirDescriptor().evmToken, v.usdcDescriptor().evmToken];
        for (uint256 r = 0; r < recipients.length; r++) {
            if (recipients[r] == address(0)) continue;
            for (uint256 t = 0; t < tokens.length; t++) {
                if (v.deferredPayout(recipients[r], tokens[t]) == 0) continue;
                try v.claimDeferred(recipients[r], tokens[t]) {
                    advanced++;
                } catch {}
            }
        }
    }
}
