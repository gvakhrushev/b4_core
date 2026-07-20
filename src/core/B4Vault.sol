// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {B4VaultEngine} from "./B4VaultEngine.sol";
import {B4VaultOps} from "./B4VaultOps.sol";
import {Phi} from "../libraries/Phi.sol";
import {Calendar} from "../libraries/Calendar.sol";
import {SafeTransfer} from "../libraries/SafeTransfer.sol";
import {CoreTypes} from "../venue/CoreTypes.sol";
import {CoreReader} from "../venue/CoreReader.sol";
import {DescriptorLib} from "../venue/DescriptorLib.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IHalvingOracle} from "../interfaces/IHalvingOracle.sol";

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

    error ZeroOps();

    constructor(address ops_) {
        // The delegatecall target is immutable; a zero here would silently no-op every
        // settle/exit/recovery dispatch, so reject it at deployment.
        if (ops_ == address(0)) revert ZeroOps();
        ops = ops_;
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
        if (slippageBps_ > 500) revert BadSlippage();
        slippageBps = slippageBps_;
        _validateRoute(route_);
        route = route_;
        _setPolicy(strategy, scaleWad);
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

    /// @notice Read the strategy ONCE and store resolved targets. Product/scale changes
    ///         rebalance this same vault in place — never exit or penalty logic
    ///         (invariant 12); the resulting trades are ordinary sync events.
    function selectPolicy(address strategy, uint256 scaleWad) external onlyOwner {
        if (exitShareWad != 0) revert ExitPending();
        _setPolicy(strategy, scaleWad);
    }

    function _setPolicy(address strategy, uint256 scaleWad) internal {
        (int256 g, int256 f) = IStrategy(strategy).targets();
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

    /// @notice Owner-only. Directional capital and/or USDC margin; accepted only in open
    ///         windows; accounted from the actual received delta (B1); adds current value
    ///         to the interval entry ledger (B4).
    function deposit(uint256 dirAmount, uint256 usdcAmount) external onlyOwner nonReentrant {
        if (exitShareWad != 0) revert ExitPending();
        if (dirAmount == 0 && usdcAmount == 0) revert ZeroDeposit();
        uint256 t = IHalvingOracle(oracle).timeSinceHalving();
        if (!Calendar.depositOpen(t)) revert DepositWindowClosed();

        uint256 valueWad = 0;
        if (dirAmount > 0) {
            uint256 received = _pull(_dir.evmToken, dirAmount);
            dirEvm += received;
            valueWad += Phi.wmul(_toWad(received, _dir.evmDecimals), _livePxWad());
        }
        if (usdcAmount > 0) {
            uint256 received = _pull(_usdc.evmToken, usdcAmount);
            usdcMarginEvm += received;
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

    // ================================================================= module dispatch

    function settle(uint256 intervalId) external nonReentrant {
        _delegate(abi.encodeCall(B4VaultOps.opsSettle, (intervalId)));
    }

    function recoverEvm(address token) external onlyOwner nonReentrant {
        _delegate(abi.encodeCall(B4VaultOps.opsRecoverEvm, (token)));
    }

    function recoverCoreSpot(bool dirToken) external onlyOwner nonReentrant {
        _delegate(abi.encodeCall(B4VaultOps.opsRecoverCoreSpot, (dirToken)));
    }

    function recoverPerpSurplus() external onlyOwner nonReentrant {
        _delegate(abi.encodeCall(B4VaultOps.opsRecoverPerpSurplus, ()));
    }

    /// @notice Retry a payout that was deferred because its token transfer failed —
    ///         permissionless; pays only the recorded recipient (F2).
    function claimDeferred(address recipient, address token) external nonReentrant {
        _delegate(abi.encodeCall(B4VaultOps.opsClaimDeferred, (recipient, token)));
    }

    function _delegate(bytes memory data) internal returns (bytes memory) {
        (bool ok, bytes memory ret) = ops.delegatecall(data);
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
