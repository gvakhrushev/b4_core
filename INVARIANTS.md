# Traceability: SECURITY_MODEL §2 invariants → tests

Layers: **U** unit/regression (`test/unit`), **I** integration (`test/integration`),
**S** stateful campaign (`test/invariant`, default 64×64, nightly `FOUNDRY_PROFILE=deep`
512×256). GAP markers are honest statements of what is *not* locally proven.

| # | Invariant | Tests | GAP / residual |
|---|---|---|---|
| 1 | One execution identity ⇔ one vault | U `test_createVault_atomicBinding` (identity = clone address, bound at init) | Structural (EVM address uniqueness); no runtime assert needed |
| 2 | No cross-vault movement authority | U `test_rogue_pool_and_vault_isolation`; I `test_multivault_independence`; S `invariant_config_immutable` | **GAP:** Core-side msg.sender scoping of CoreWriter actions is venue semantics — funded gate §5.10 |
| 3 | No accounting from unmeasured transfers | U `test_donation_not_accounted_recoverable`, `test_capture_measuredDelta_only`, `test_R7_fund_credit_capped`; S `invariant_books_never_exceed_assets` | — |
| 4 | Action success never finalizes accounting | U all `test_R1_*`, `test_R2_delayed_action_not_doubleApplied`, `test_spotOrder_*` | Live venue timing not reproducible locally — funded gates §5.8–10 |
| 5 | Core→EVM completion = debit + receipt | U `test_A7_return_never_resends_after_debit`, `test_R1_return_completes_despite_small_topUp` | — |
| 6 | Spot credit ≤ proven input × envelope | U `test_spotOrder_favorable_overfill_stays_unaccounted`, `test_spotOrder_partialFill_measured` | — |
| 7 | Harvest bounds; claim ≤ one-call settleable | U `test_harvest_bounds`, `test_R3_harvest_quota_deadlock_clamps_and_clears`, `test_R3_harvest_quota_withdrawable_zero_liquidation`, `test_R3_pending_claim_gates_nothing`, `test_R3_adversarial_drain_between_create_and_execute`; S runtime proxies `invariant_crank_never_reverts` + `invariant_books_never_exceed_assets` | The precise A5 quota-coexistence discipline (`pendingHarvest6 == 0` while its FromPerp/Harvest resolver is in flight) is proven deterministically by the `test_R3_*` harness tests. A dedicated campaign invariant was **removed as vacuous** (V3-COV-1): the adversarial `advWdDrain`/`advLiquidation` handlers keep the campaign out of the harvest-accrual state (`pendingHarvest6 > 0` observed 0 times over 4,096 calls), so the state it asserts is never reached |
| 8 | Owner margin separate from strategy capital | U `test_promax_opens_leveraged_long` (strategy value excludes margin; notional ≤ margin·maxLev/φ) | — |
| 9 | Sign change passes through verified zero | U `test_promax_sign_change_passes_through_zero`; S `invariant_no_sign_flip` | — |
| 10 | Pool liability by receipt; balance ≥ liability | U `test_capture_measuredDelta_only`, `test_claim_proRata_paysFixedOwner`; S `invariant_pool_balance_ge_liability` | — |
| 11 | Distribution ≤ nominal; order-independent socialization | U `test_shortfall_socialization_orderIndependent`, `test_failed_transfer_leaves_token_retryable` | — |
| 12 | Policy/scale change never exit/penalty | U `test_policyChange_noExit_noPenalty`; S ghost `policyMovedFunds` set in the `selectPolicy` handler, checked by `invariant_policy_never_moves_funds` (a ghost, not an in-line assert — a handler-local revert would be masked under `fail_on_revert = false`, RAW-E-001) | — |
| 13 | Emergency never discards an asset transfer | U `test_R4_asset_transfer_intents_not_discardable`, `test_R4_abandon_phase1_then_rerecover`, `test_R4_abandon_phase2_then_rerecover_via_spot` | — |
| 14 | Withdrawal: strict-flat NAV + full Core return before payment | U `test_R5_strict_flatness_blocks_margin_return`, `test_exit_returns_core_principal_before_payment`, `test_R5_recovery_requires_raw_zero` | Reduce-only-to-raw-zero on the live venue — funded gate §5.11 |
| 15 | Fee route immutable after creation | U `test_route_immutable_no_setter_exists`, `test_route_validation_matrix` (no setter exists in the ABI); S `invariant_config_immutable` | — |
| 16 | Multi-vault independence (same owner) | I `test_multivault_independence`; S per-vault book checks + `invariant_config_immutable` | — |
| 17 | Completion/retry on reliable balance only; resend = exact complement | U `test_R1_fromPerp_completes_under_withdrawable_drift`, `testFuzz_R1_fromPerp_completion_ignores_withdrawable`, `test_R1_toPerp_completes_despite_small_topUp`, `test_R2_subAmount_topUp_does_not_block_resend`, `test_R2_fromPerp_dropped_resend_reclamps`, `test_R7_source_topUp_equal_amount`, `test_R7_destination_topUp_fakes_completion_once_benign` | Delayed-double-execution across a resend excluded by assumption — funded gate §5.10 |
| 18 | Safe permissionless entrypoints; worst case = delayed liveness | U `test_onlyOwner_guards`, `test_claim_proRata_paysFixedOwner` (fixed recipient), pool bounded-asset loops at the MAX_DIRECTIONAL cap `test_V3Cov_max_directional_pool_lifecycle_and_cap` (8-directional pool full cycle + 9th-directional cap revert); U `test_missed_snapshot_makes_interval_unreportable_not_stuck`, `test_superseded_point_skipped`; U payout-defer under recipient blacklist: `test_settle_with_blacklisted_operator_defers_not_freezes`, `test_exit_with_blacklisted_operator_completes`, `test_keeper_retries_deferred`; S `invariant_crank_never_reverts`, `invariant_pool_advance_never_reverts` (the permissionless calendar-advance step, exercised by every `poolCrank()`), `reconcileHeals` handler | — |

## Mandatory regressions (TEST_PLAN §2–4) — checklist

| §2 regression | Test(s) |
|---|---|
| 1 Reliable-balance completion (A2) | `test_R1_*` ×3 + fuzz |
| 2 Exact-complement resend (A3) | `test_R2_*` ×3 |
| 3 Harvest-quota deadlock incl. wd == 0 (A4/A5) | `test_R3_*` ×4 |
| 4 Emergency recovery vs. discard (A6) | `test_R4_*` ×4 |
| 5 Strict custody flatness (A10) | `test_R5_*` ×2 |
| 6 Surplus recovery spot AND perp, two-phase abandon (B6) | `test_R6_*` ×4 + `test_R4_abandon_*` |
| 7 Top-up == and > amount (A11) | `test_R7_*` ×3 |
| 8 Realized-loss reconciliation in settle/exit/sync (B2) | `test_R8_*` ×2 + `test_sync_reconciles_loss_before_sizing` |
| §3.9 Checkpoint-price poisoning (D1) | `test_checkpointPrice_poisoning_transientZero_retries` |
| §3.10 balance ≥ liability + socialization (D2/D3) | `test_shortfall_socialization_orderIndependent` + S campaign |
| §3.11 Halving acceptance, fast cycle, no wall clock (E1/E2), key continuity | `test_accepts_ultraFast_cycle_noWallClockWindow`, `test_intervalKey_continuity_across_epoch_boundary`, genesis-edge tests |
| §3.12 Cross-chain bindings (E3) | `test_rejects_untrusted_paths`, `test_idempotent_and_conflicting_redelivery`, `test_delegate_renounce_oneShot`, `test_prover_publishes_bound_fact` |
| §3b.13 Equal-target no-trade / same-sign interpolation | `test_mini_never_trades` (all-transition sweep), `testFuzz_sameSign_direct_interpolation` (non-equal same-sign direct path), `test_zero_endpoint_piecewise`; fee-on-profit without trades: `test_settle_profit_fee_weight` (Mini) |
| §3b.14 Dust-exit weight minting | `test_repeated_partial_exits_no_weight_duplication` (10 dust exits + honest 50%), `test_partial_exit_ledger_math` |
| Settle-mid-flight entry integrity (B1/B4) | `test_settle_requires_idle_then_no_phantom_profit` — the settle-requires-idle hardening (RAW-A-001) means a valuation never runs while funding is in flight, so returning principal can never read as profit. (Prior map entry named `test_settle_midFundFlight_no_phantom_profit`, which never existed — corrected per V3-COV-1.) |
| Payout-defer liveness (H3; USDC blacklist is in-model) | `test_settle_with_blacklisted_operator_defers_not_freezes`, `test_exit_with_blacklisted_operator_completes`, `test_deferred_not_recoverable_as_surplus`, `test_keeper_retries_deferred` |
| Settle requires idle; reconcile at idle only (B2 dual trap, RAW-A-001) | `test_A001_settle_requires_idle_during_marginReturn`, `test_settle_requires_idle_then_no_phantom_profit`, `test_A001_marginReturn_value_conserved_at_idle`, `test_A001_coincident_loss_reconciled_at_idle_before_settle`; real-loss reconcile at settle preserved by `test_R8_settle_reconciles_realized_loss_before_valuation` |
| Order-size overflow safety (RAW-D writer, adversarial) | `test_D_writer_units_no_overflow_micro_asset` (clamp, no revert), `test_D_writer_units_asymmetric_szDecimals` (mock-collusion guard), `test_D_binding_rejects_bad_decimals_and_widths` |
| Spot-only perp-policy degradation (RAW-D NO_MARKET) | `test_D_spot_only_perp_policy_degrades_and_recovers` (Pro on spot-only: rotate-only, inert margin paid at exit, perp surplus recoverable) |
| Harvest claim reserved from surplus recovery (AUDIT-1, C1) | `test_AUDIT1_recoverPerpSurplus_reserves_harvest_claim`; stressed by the `recover` handler in the stateful campaign |
| Pool sibling reentrancy guard (AUDIT-2, F4) | `test_AUDIT2_pool_siblings_nonreentrant_during_claim`, `test_AUDIT2_exit_capture_still_works` |
| Malformed-token fail-soft (D5, RAW-B-001) | `test_B001_tryTransfer_never_reverts_on_malformed_return`, `test_B001_pool_claim_isolates_malformed_token` |
| CoreWriter fixed-1e8 units (RAW-D scales; funded gates §5.4–5) | `test_D_spot_order_encodes_fixed_1e8_units`, `test_D_perp_order_encodes_fixed_1e8_units` (exact emitted-calldata) |
| Spot-only descriptor lifecycle (RAW-D NO_MARKET) | `test_D_spot_only_vault_full_lifecycle` (mock fails invalid-asset position reads) |
| Extended perp-id rejection (RAW-D HIP-3) | `test_D_hip3_wide_perp_id_rejected` |
| §4.15 Permissionless safety | `test_onlyOwner_guards`, fixed-recipient claim tests |
| §4.16 Atomic init / re-init guards | `test_reinit_guarded_oneShot`, `test_implementation_cannot_be_initialized`, `test_createVault_atomicBinding` |
| §4.17 Rogue pool/vault isolation | `test_rogue_pool_and_vault_isolation` |
