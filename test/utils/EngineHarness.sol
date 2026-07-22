// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {B4VaultEngine} from "src/core/B4VaultEngine.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice Surgical test access to the async engine: create any intent from any recorded
///         state, then drive verification against the adversarial venue mock. Used for
///         the leg-level regressions of TEST_PLAN §2 where full lifecycles would obscure
///         the exact trap being tested.
contract EngineHarness is B4VaultEngine {
    function setup(
        CoreTypes.AssetDescriptor calldata dir_,
        CoreTypes.AssetDescriptor calldata usdc_,
        address oracle_
    ) external {
        _dir = dir_;
        _usdc = usdc_;
        oracle = oracle_;
        owner = msg.sender;
        slippageBps = 100;
        _initialized = true;
        pool = address(this); // be our own anchor source: genesis (0,0) ⇒ flat base leverage
    }

    /// Stand-in for `B4Pool.anchors`. Defaults to genesis (0, 0) ⇒ the structural-leverage
    /// path degrades to the flat base `g`; a test may `setAnchors` to exercise it.
    uint256 public aFloor;
    uint256 public aCap;

    function setAnchors(uint256 floor_, uint256 cap_) external {
        aFloor = floor_;
        aCap = cap_;
    }

    function anchors(uint256) external view returns (uint256 floor, uint256 cap) {
        return (aFloor, aCap);
    }

    function sizePxWad() external view returns (uint256) {
        return _sizePxWad;
    }

    function setBuckets(
        uint256 dirEvm_,
        uint256 rotEvm_,
        uint256 marEvm_,
        uint64 coreDir_,
        uint64 coreRot_,
        uint64 coreMar_,
        uint64 perp6_
    ) external {
        dirEvm = dirEvm_;
        usdcRotatedEvm = rotEvm_;
        usdcMarginEvm = marEvm_;
        coreDirWei = coreDir_;
        coreUsdcRotatedWei = coreRot_;
        coreUsdcMarginWei = coreMar_;
        perpMargin6 = perp6_;
    }

    function setPendingHarvest(uint64 claim6) external {
        pendingHarvest6 = claim6;
    }

    function setEntry(uint256 e) external {
        entryLedgerWad = e;
    }

    function setTargets(int256 growth, int256 fall) external {
        growthTarget = growth;
        fallTarget = fall;
    }

    // ---- intent creation ----
    function startFund(bool dirToken, Purpose p, uint256 evmAmount) external {
        _requireIdle();
        _startFund(dirToken, p, evmAmount);
    }

    function startSpotOrder(bool isBuy, uint64 inputWei) external {
        _requireIdle();
        _startSpotOrder(isBuy, inputWei);
    }

    function startReturn(bool dirToken, Purpose p, uint64 weiAmount) external {
        _requireIdle();
        _startReturn(dirToken, p, weiAmount);
    }

    function startToPerp(uint64 amount6) external {
        _requireIdle();
        _startToPerp(amount6);
    }

    function startFromPerp(Purpose p, uint64 amount6) external {
        _requireIdle();
        _startFromPerp(p, amount6);
    }

    function startPerpOrder(bool isBuy, uint64 sz, bool reduceOnly) external {
        _requireIdle();
        _startPerpOrder(isBuy, sz, reduceOnly);
    }

    function startRecoverySpot(bool dirToken, uint64 weiAmount) external {
        _requireIdle();
        _startRecoverySpot(
            dirToken ? IntentKind.RecoverSpotDir : IntentKind.RecoverSpotUsdc, weiAmount
        );
    }

    // ---- driving ----
    function verify() external returns (bool) {
        return _verifyIntent();
    }

    function planSync() external returns (bool) {
        if (intent.kind != IntentKind.None) return _verifyIntent();
        return _planSyncStep();
    }

    function reconcile() external {
        _reconcile();
    }

    function clearIntentForTest() external {
        _clearIntent();
    }

    // ---- views ----
    function intentKind() external view returns (IntentKind) {
        return intent.kind;
    }

    function intentAmount() external view returns (uint64) {
        return intent.amount;
    }

    function navView(uint256 pxWad) external view returns (uint256) {
        return _navWad(pxWad);
    }
}
