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

    /// Gas the bounded loops below leave untouched so the calendar/sweep/capture tail and
    /// the `Cranked` receipt always run. MEASURED (test/unit/GasBounds.t.sol): that tail
    /// costs ~0.7M at MAX_DIRECTIONAL with both settlement points pending and the full
    /// 16-deep sweep window, so this is ~2x the worst observation.
    uint256 internal constant TAIL_RESERVE = 1_500_000;

    /// Ceiling on ONE sleeve step. MEASURED (test/unit/GasBounds.t.sol): the heaviest
    /// single step is a fold (approve/approve/deposit + a full sleeve crank) at 0.49M,
    /// then a sleeve crank at 0.51M and a sleeve-exit opening at 0.05M — so this is ~4x
    /// the worst observation. It is enforced by forwarding at most this much, which is
    /// what makes the reserve above an arithmetic guarantee rather than an estimate: with
    /// an explicit `{gas: n}` the frame keeps `gasleft() − n` no matter what the callee
    /// does (EIP-150's 63/64 rule can only leave MORE). Same technique, and the same F2
    /// rationale, as `B4Pool.TOKEN_READ_GAS` and `SafeTransfer`'s 500k cap: a step that
    /// somehow needed more is not lost, it is still reachable by calling the pool's own
    /// permissionless entry point directly.
    uint256 internal constant STEP_GAS = 2_000_000;

    /// Ceiling on ONE anchor sample — deliberately NOT `STEP_GAS`. MEASURED: the most
    /// expensive `sampleAnchor` write (post-halving window, cold `Anchor` slot) is 0.09M,
    /// two orders of magnitude under a fold, so this is ~4x the worst observation.
    ///
    /// Gating the anchor loop on the SLEEVE budget would defeat the reordering directly
    /// above it: a caller below `TAIL_RESERVE + STEP_GAS` = 3.5M would sample ZERO anchors
    /// rather than "as many as fit", which is the opposite of the F2 partial-progress rule
    /// every other bound here follows. That threshold is above HyperEVM's 2M small-block
    /// limit, so on a legacy (mask 0) pool — whose whole crank measures 1.57M and needs no
    /// sleeve budget at all — the L-2 competitor would become unreachable to any keeper
    /// that has not opted into big blocks. Sizing the gate to the step actually being
    /// forwarded keeps the reserve arithmetic identical and keeps sampling reachable.
    uint256 internal constant ANCHOR_GAS = 400_000;

    event Cranked(address pool, uint256 vaults, uint256 stepsAdvanced);

    /// @dev True while there is enough gas to forward `stepGas` to one more bounded step
    ///      AND still pay for the calendar tail. A caller that supplies less simply
    ///      advances fewer steps and the next crank resumes — every step here is
    ///      independently idempotent, so the worst case is delayed liveness, never a lost
    ///      transaction (F2/H3).
    function _canStep(uint256 stepGas) internal view returns (bool) {
        return gasleft() >= TAIL_RESERVE + stepGas;
    }

    function crank(B4Pool pool, address[] calldata vaults, uint256 maxVaultSteps) external {
        uint256 advanced;

        // Structural anchors (audit L-2). `sampleAnchor` had NO caller anywhere in `src/`,
        // so the anchor ratchet's only documented safety mechanism — competitive honest
        // sampling — was unimplemented: in practice nobody sampled, and the anchors that
        // size every structural position would be whatever a single interested party chose
        // to submit. Sampling here makes the honest keeper a standing competitor.
        // Bounded by the immutable MAX_DIRECTIONAL, and each call is isolated: outside a
        // sampling window the pool reverts `NotInWindow`, which is the normal case, so it
        // must never stop calendar or vault liveness. (An in-window repeat does NOT revert;
        // it is simply not counted as a distinct daily observation — see `_recordDistinctSample`.)
        //
        // This runs FIRST, ahead of the sleeve loop, and on its own small `ANCHOR_GAS`
        // budget. Sampling moves no funds and only reads the venue price, so nothing
        // downstream depends on the order; but it is cheap (<0.1M each), safety-critical
        // and time-sensitive (the density gate counts DAYS), and the sleeve loop below can
        // legitimately consume a whole block on a wide aggregate pool. Ordering it first
        // AND budgeting it separately is what stops the ratchet's only honest competitor
        // from being starved by discretionary sleeve work.
        uint256 assets = pool.assetCount();
        for (uint256 i = 1; i < assets; i++) {
            if (!_canStep(ANCHOR_GAS)) break;
            try pool.sampleAnchor{gas: ANCHOR_GAS}(i) {
                advanced++;
            } catch {}
        }

        // Strict Product Pools keep a non-free penalty out of ordinary claimant
        // inventory while its fixed product sleeve trades. Drive that entirely
        // permissionlessly here: fold only measured escrow, try a full sleeve exit
        // (the pool itself admits it only in Calendar.freeExit), then advance each
        // sleeve through its normal vault state machine. Both dimensions are bounded
        // by immutable pool limits (4 policies × MAX_DIRECTIONAL), and every call is
        // isolated so one failed sleeve cannot stop calendar/vault liveness.
        advanced += _crankProductSleeves(pool, maxVaultSteps);

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
            // The vault list and `maxVaultSteps` are the CALLER's own bounds, so this loop
            // is not protocol-bounded — but a keeper that over-sizes either must still not
            // lose the whole transaction. Stop before a burst there is no budget for; the
            // untried tail of the list is served by the next crank (F2).
            if (gasleft() < TAIL_RESERVE) break;
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

    function _crankProductSleeves(B4Pool pool, uint256 maxSteps)
        internal
        returns (uint256 advanced)
    {
        uint8 mask = pool.policyMask();
        if (mask == 0) return 0; // legacy basket: no sleeves
        uint256 n = pool.assetCount();
        for (uint256 assetIndex = 1; assetIndex < n; assetIndex++) {
            for (uint8 policy = 1; policy <= 4; policy++) {
                if ((mask & (uint8(1) << (policy - 1))) == 0) continue;
                // Gas bound (F2). This body runs up to 4 × MAX_DIRECTIONAL = 32 times, and
                // `maxSteps` multiplies INSIDE it — so a value that is perfectly sane for
                // the caller's own vault list is not sane here. MEASURED (test/unit/
                // GasBounds.t.sol) on an 8-directional aggregate pool with all 32 escrow
                // slots funded, at a settlement point inside a free-exit window: 17.0M gas
                // at maxSteps=0, 30.0M at 2, and 35.1M — ABOVE a 30M block — from
                // maxSteps=4 up. Unbounded, that whole transaction reverts and NOTHING
                // advances, the calendar included. Bounded, the loop stops where the budget
                // stops, the tail still runs, and the next crank resumes: delayed liveness,
                // which is the worst case this path is allowed to have.
                if (!_canStep(STEP_GAS)) return advanced;
                try pool.foldPenalty{gas: STEP_GAS}(policy, assetIndex) returns (bool folded) {
                    if (folded) advanced++;
                } catch {}
                // Outside a free window this reverts into the catch; during a free
                // window it starts the full realised-return path. The pool rejects a
                // duplicate pending exit, so retrying on later cranks is safe.
                if (!_canStep(STEP_GAS)) return advanced;
                try pool.initiateSleeveExit{gas: STEP_GAS}(policy, assetIndex) returns (
                    bool started
                ) {
                    if (started) advanced++;
                } catch {}
                for (uint256 step = 0; step < maxSteps; step++) {
                    if (!_canStep(STEP_GAS)) return advanced;
                    try pool.crankSleeve{gas: STEP_GAS}(policy, assetIndex) returns (
                        bool progressed
                    ) {
                        if (!progressed) break;
                        advanced++;
                    } catch {
                        break;
                    }
                }
            }
        }
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
