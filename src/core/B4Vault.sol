// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {B4VaultEngine} from "./B4VaultEngine.sol";
import {B4VaultOps} from "./B4VaultOps.sol";
import {B4VaultRecovery} from "./B4VaultRecovery.sol";
import {Phi} from "../libraries/Phi.sol";
import {SafeTransfer} from "../libraries/SafeTransfer.sol";
import {CoreTypes} from "../venue/CoreTypes.sol";
import {CoreReader} from "../venue/CoreReader.sol";
import {DescriptorLib} from "../venue/DescriptorLib.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IB4PoolPolicy} from "../interfaces/IB4PoolPolicy.sol";

/// @title B4Vault — isolated per-user vault: deposits, policy, crank, settle, exit,
///        recovery.
/// @notice One fixed owner, one immutable fee route, no admin (F1). Every remedy is a
///         permissionless crank or an owner-only recovery that cannot create authority.
///         Settle / exit-finalize / recovery bodies live in the B4VaultOps module,
///         reached by delegatecall through an immutable address fixed at implementation
///         deployment — code organization for EIP-170, not an upgrade path.
contract B4Vault is B4VaultEngine {
    using SafeTransfer for address;

    address public immutable ops;
    /// Second delegatecall module holding the cold path (owner recovery, deferred payouts).
    /// Split out of `ops` for EIP-170 headroom, on the same terms: immutable, unrepointable,
    /// same inherited storage layout — code organization, never an upgrade path (F1).
    address public immutable recovery;

    error ZeroOps();

    constructor(address ops_, address recovery_) {
        // The delegatecall target is immutable; a zero here would silently no-op every
        // settle/exit/recovery dispatch, so reject it at deployment.
        // Equal modules would silently route every cold-path dispatch into `ops`, where
        // those selectors do not exist — bricking recovery and deferred payouts forever on
        // a vault implementation that can never be redeployed for existing clones.
        if (ops_ == address(0) || recovery_ == address(0) || ops_ == recovery_) {
            revert ZeroOps();
        }
        ops = ops_;
        recovery = recovery_;
        _initialized = true; // the implementation itself can never be initialized
    }

    // ================================================================= initialization

    /// @notice One-shot atomic initialization by the factory (F3). Verifies the
    ///         descriptors against the venue before any funds can be accepted (SPEC §2).
    function initialize(
        address owner_,
        address pool_,
        address oracle_,
        CoreTypes.AssetDescriptor calldata dir_,
        CoreTypes.AssetDescriptor calldata usdc_,
        uint256 dirAssetIndex_,
        address strategy,
        uint256 scaleWad,
        int256 growth,
        int256 fall,
        uint16 slippageBps_,
        FeeRoute calldata route_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        factory = msg.sender;
        owner = owner_;
        pool = pool_;
        oracle = oracle_;
        _dir = dir_;
        _usdc = usdc_;
        _dirAssetIndex = dirAssetIndex_;
        DescriptorLib.verifySettlement(usdc_);
        DescriptorLib.verifyDirectional(dir_, usdc_);
        // Bounded from BELOW as well (audit L-5): `slippageBps` is immutable and has no
        // setter, so a vault created at 0 emits every IOC at the mid, where a taker order
        // does not cross — permanently, with no way to repair it. MIN_SLIPPAGE_BPS is the
        // smallest envelope that reliably crosses a normal spot spread; the exact live
        // figure is a funded gate, so this is a floor against a bricked vault, not a
        // claim about execution quality.
        if (slippageBps_ > 500 || slippageBps_ < MIN_SLIPPAGE_BPS) revert BadSlippage();
        slippageBps = slippageBps_;
        _validateRoute(route_);
        route = route_;
        if (!IB4PoolPolicy(pool_)
                .policyAllowedForVault(address(0), strategy, growth, fall, scaleWad)) {
            revert BadPolicy();
        }
        _setPolicyResolved(strategy, growth, fall, scaleWad);
        emit Initialized(owner_, pool_, CoreTypes.descriptorHash(dir_));
    }

    function _validateRoute(FeeRoute calldata r) internal pure {
        if (r.operatorBps > Phi.MAX_OPERATOR_BPS) revert BadRoute();
        if (r.operatorBps > 0 && r.operator == address(0)) revert BadRoute();
        if (r.referrer != address(0)) {
            // A referrer requires a non-zero operator rate and a protected share (SPEC §2).
            if (r.operatorBps == 0) revert BadRoute();
            if (r.referrerBps < Phi.MIN_REFERRER_BPS || r.referrerBps > Phi.BPS) {
                revert BadRoute();
            }
        } else if (r.referrerBps != 0) {
            revert BadRoute();
        }
    }

    // ================================================================= policy

    /// @notice Select an enabled policy.  In configured pools this is an immutable
    ///         product-domain transition: only an equal-or-higher product is accepted;
    ///         downscaling requires a normal exit and a new vault.
    function selectPolicy(address strategy, uint256 scaleWad) external onlyOwner {
        if (exitShareWad != 0) revert ExitPending();
        _delegate(abi.encodeCall(B4VaultOps.opsSelectPolicy, (strategy, scaleWad)));
    }

    /// @dev Factory-resolved strategy targets are passed into initialization instead of
    ///      being read by the clone. This closes a time-of-check/time-of-use gap for a
    ///      mutable strategy contract while preserving the one-read rule on selection.
    function _setPolicyResolved(address strategy, int256 g, int256 f, uint256 scaleWad) internal {
        if (scaleWad == 0 || scaleWad > Phi.MAX_SCALE) revert BadPolicy();
        if (Phi.abs(g) > Phi.MAX_BASE_TARGET || Phi.abs(f) > Phi.MAX_BASE_TARGET) {
            revert BadPolicy();
        }
        int256 rg = g * int256(scaleWad) / int256(Phi.WAD);
        int256 rf = f * int256(scaleWad) / int256(Phi.WAD);
        if (Phi.abs(rg) > Phi.PHI || Phi.abs(rf) > Phi.PHI) revert BadPolicy();
        growthTarget = rg;
        fallTarget = rf;
        emit PolicySelected(strategy, rg, rf, scaleWad);
    }

    // ================================================================= deposits

    /// @notice Owner-only. Directional capital and/or USDC margin; accepted throughout the
    ///         cycle; accounted from the actual received delta (B1); adds current value to
    ///         the interval entry ledger (B4).
    function deposit(uint256 dirAmount, uint256 usdcAmount) external onlyOwner nonReentrant {
        if (exitShareWad != 0) revert ExitPending();
        if (dirAmount == 0 && usdcAmount == 0) revert ZeroDeposit();

        uint256 valueWad = 0;
        if (dirAmount > 0) {
            uint256 received = _pull(_dir.evmToken, dirAmount);
            dirEvm += received;
            // A zero read is not a cost basis (audit H-3): it would book this principal at
            // 0, and the next checkpoint would then charge a performance fee on the whole
            // NAV and mint the matching pool weight — out of the depositor's own capital.
            // The guard stays INSIDE this branch on purpose: a USDC-only top-up is
            // price-independent (C3) and must stay possible during a feed outage, which is
            // exactly when an owner needs to add margin to a leveraged position.
            uint256 pxWad = _livePxWad();
            if (pxWad == 0) revert ZeroPrice();
            valueWad += Phi.wmul(_toWad(received, _dir.evmDecimals), pxWad);
        }
        if (usdcAmount > 0) {
            uint256 received = _pull(_usdc.evmToken, usdcAmount);
            // USDC is STRATEGY capital, not a segregated owner-margin reserve: for the
            // self-funding pure-perp products a deposit must be able to open the position
            // (a perp margins from strategy USDC via the reclassify path). It lands in the
            // rotation bucket so `_strategyValueWad` counts it and the perp sizes on it.
            usdcRotatedEvm += received;
            valueWad += _toWad(received, _usdc.evmDecimals); // fixed 1 USD (C3)
        }
        entryLedgerWad += valueWad;
        emit Deposited(dirAmount, usdcAmount, valueWad, entryLedgerWad);
    }

    function _pull(address token, uint256 amount) internal returns (uint256 received) {
        uint256 before = IERC20(token).balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - before;
    }

    // ================================================================= crank

    /// @notice Permissionless: advance the pending intent, else one exit step, else one
    ///         sync step. Liveness only — a keeper cannot choose target, market, price or
    ///         recipient (F2).
    function crank() external nonReentrant returns (bool progressed) {
        if (intent.kind != IntentKind.None) return _verifyIntent();
        bytes memory ret = _delegate(abi.encodeCall(B4VaultOps.opsPlanStep, ()));
        return abi.decode(ret, (bool));
    }

    // ================================================================= exit

    /// @notice Begin exiting share `x ∈ (0, 1]`. The exit is then driven by the LIVE
    ///         position through permissionless cranks (SPEC §9).
    function initiateExit(uint256 shareWad) external onlyOwner {
        if (exitShareWad != 0) revert ExitPending();
        if (shareWad == 0 || shareWad > Phi.WAD) revert BadShare();
        exitShareWad = shareWad;
        emit ExitInitiated(shareWad);
    }

    /// @notice Withdraw a pending exit request. Owner-only, no timeout, moves no funds.
    /// @dev The escape for a deferred finalize (H-3): `exitShareWad != 0` gates `deposit`,
    ///      `settle`, `selectPolicy` and both recovery paths, so a permanently dead price
    ///      feed would otherwise leave the vault stuck in ExitPending with no admin, no
    ///      pause and no way out. Safe to allow unconditionally: every step before
    ///      `_finalizeExit` only flattens the perp and moves Core principal back to EVM —
    ///      all NAV-neutral — and nothing is paid until the atomic finalize, so cancelling
    ///      cannot strand a partial payout. The sync planner simply rebuilds the position.
    ///      `onlyOwner` is satisfiable for EVERY vault, including a pool-owned sleeve whose
    ///      owner is the B4Pool: the pool relays this call through `cancelSleeveExit`,
    ///      gated on the same dead-feed predicate `_finalizeExit` defers on (audit L-1).
    function cancelExit() external onlyOwner {
        if (exitShareWad == 0) revert NoExitPending();
        emit ExitCancelled(exitShareWad);
        exitShareWad = 0;
    }

    // ================================================================= module dispatch

    function settle(uint256 intervalId) external nonReentrant {
        _delegate(abi.encodeCall(B4VaultOps.opsSettle, (intervalId)));
    }

    /// @dev The three recovery entrypoints and `emergencyClearRecovery` pay/act only for the
    ///      fixed `owner`, so `onlyOwner` is an identity check, never an authority. For a
    ///      pool-owned sleeve the owner is the B4Pool, which relays each of them with fixed
    ///      arguments (`B4Pool.recoverSleeve*` / `clearSleeveRecovery`) and folds the proceeds
    ///      back into claim inventory — without that relay HAZARDS B6 was unimplemented for
    ///      every sleeve (audit L-1).
    function recoverEvm(address token) external onlyOwner nonReentrant {
        _delegateTo(recovery, abi.encodeCall(B4VaultRecovery.opsRecoverEvm, (token)));
    }

    function recoverCoreSpot(bool dirToken) external onlyOwner nonReentrant {
        _delegateTo(recovery, abi.encodeCall(B4VaultRecovery.opsRecoverCoreSpot, (dirToken)));
    }

    function recoverPerpSurplus() external onlyOwner nonReentrant {
        _delegateTo(recovery, abi.encodeCall(B4VaultRecovery.opsRecoverPerpSurplus, ()));
    }

    /// @notice Retry a payout that was deferred because its token transfer failed —
    ///         permissionless; pays only the recorded recipient (F2).
    function claimDeferred(address recipient, address token) external nonReentrant {
        _delegateTo(recovery, abi.encodeCall(B4VaultRecovery.opsClaimDeferred, (recipient, token)));
    }

    function _delegate(bytes memory data) internal returns (bytes memory) {
        return _delegateTo(ops, data);
    }

    /// @dev Both module addresses are constructor immutables and every call site encodes a
    ///      fixed selector, so no caller-chosen calldata or target can ever reach a module.
    function _delegateTo(address module, bytes memory data) internal returns (bytes memory) {
        (bool ok, bytes memory ret) = module.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    // ================================================================= emergency (A6)

    /// @notice Owner escape for a stuck SURPLUS-RECOVERY intent only (A6): the funds stay
    ///         on Core and remain re-recoverable. Asset-transfer intents can never be
    ///         discarded — with A2/A3 they always progress after the timeout.
    function emergencyClearRecovery() external onlyOwner {
        IntentKind k = intent.kind;
        if (
            k != IntentKind.RecoverSpotDir && k != IntentKind.RecoverSpotUsdc
                && k != IntentKind.RecoverPerpPhase1 && k != IntentKind.RecoverPerpPhase2
        ) revert NotRecoveryIntent();
        if (block.timestamp < intent.createdAt + EMERGENCY_TIMEOUT) revert TooEarly();
        emit EmergencyCleared(k);
        _clearIntent();
    }

    // ================================================================= views

    function currentTarget() external view returns (int256) {
        return _currentTarget();
    }

    function navWad() external view returns (uint256) {
        return _navWad(_livePxWad());
    }

    function strategyValueWad() external view returns (uint256) {
        return _strategyValueWad(_livePxWad());
    }
}
