// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {EquiHook, IERC20, IDividendVault} from "../src/EquiHook.sol";

// =========================================================================
//                         Test Harness Contract
// =========================================================================

/// @notice Exposes internal EquiHook functions for testing without requiring
/// a valid hook address (which would need specific address bits).
contract EquiHookHarness {
    // Identity-weighted pricing tiers (mirrors EquiHook constants)
    uint256 public constant TIER0_FEE = 20000;  // 2.0% — no SBT
    uint256 public constant TIER1_FEE = 3000;   // 0.3% — SBT holder
    uint256 public constant TIER2_FEE = 1500;   // 0.15% — long-term holder
    uint256 public constant TIER2_THRESHOLD = 30 days;
    uint256 public constant SIZE_THRESHOLD_BPS = 200;
    uint256 public constant SIZE_SCALING_FACTOR = 10;

    mapping(address => bool) public isCompliant;
    mapping(address => uint256) public complianceSince;

    function registerCompliance(address user) external {
        isCompliant[user] = true;
        if (complianceSince[user] == 0) complianceSince[user] = block.timestamp;
    }

    function clearCompliance(address user) external {
        isCompliant[user] = false;
    }

    function identityFee(address user) external view returns (uint24) {
        if (!isCompliant[user]) return uint24(TIER0_FEE);
        if (block.timestamp - complianceSince[user] >= TIER2_THRESHOLD) return uint24(TIER2_FEE);
        return uint24(TIER1_FEE);
    }

    function calculateHookFee(BalanceDelta delta) external pure returns (uint256) {
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        int128 amountOut = amount1 > 0 ? amount1 : amount0;
        if (amountOut <= 0) return 0;
        return uint256(uint128(amountOut)) / 20;
    }
}

// =========================================================================
//                           Test Contract
// =========================================================================

contract EquiHookTest is Test {
    EquiHookHarness public harness;

    address public user1 = address(0xA1);
    address public user2 = address(0xA2);

    function setUp() public {
        harness = new EquiHookHarness();
    }

    // =========================================================================
    //                       Compliance: register & clear
    // =========================================================================

    function test_registerCompliance_setsCompliant() public {
        assertFalse(harness.isCompliant(user1));
        harness.registerCompliance(user1);
        assertTrue(harness.isCompliant(user1));
    }

    function test_registerCompliance_multipleUsers() public {
        harness.registerCompliance(user1);
        harness.registerCompliance(user2);
        assertTrue(harness.isCompliant(user1));
        assertTrue(harness.isCompliant(user2));
    }

    function test_clearCompliance_removesCompliance() public {
        harness.registerCompliance(user1);
        assertTrue(harness.isCompliant(user1));
        harness.clearCompliance(user1);
        assertFalse(harness.isCompliant(user1));
    }

    function test_clearCompliance_nonCompliantUser_doesNotRevert() public {
        assertFalse(harness.isCompliant(user1));
        harness.clearCompliance(user1);
        assertFalse(harness.isCompliant(user1));
    }

    function test_registerCompliance_idempotent() public {
        harness.registerCompliance(user1);
        harness.registerCompliance(user1);
        assertTrue(harness.isCompliant(user1));
    }

    function test_compliance_independenceBetweenUsers() public {
        harness.registerCompliance(user1);
        assertTrue(harness.isCompliant(user1));
        assertFalse(harness.isCompliant(user2));
        harness.clearCompliance(user1);
        assertFalse(harness.isCompliant(user1));
        assertFalse(harness.isCompliant(user2));
    }

    // =========================================================================
    //        Identity-Weighted Pricing: 3-tier fee structure
    // =========================================================================

    function test_identityFee_tier0_noSBT_returnsMaxFee() public {
        // No SBT → 2.0% deterrent fee
        assertEq(harness.identityFee(user1), 20000);
    }

    function test_identityFee_tier1_newSBT_returnsBaseFee() public {
        harness.registerCompliance(user1);
        // Fresh SBT → 0.3% base fee
        assertEq(harness.identityFee(user1), 3000);
    }

    function test_identityFee_tier2_longTermHolder_returnsDiscount() public {
        harness.registerCompliance(user1);
        // Fast-forward 31 days
        vm.warp(block.timestamp + 31 days);
        // Long-term holder → 0.15% discount fee
        assertEq(harness.identityFee(user1), 1500);
    }

    function test_identityFee_tier2_exactThreshold_returnsTier1() public {
        harness.registerCompliance(user1);
        vm.warp(block.timestamp + 30 days - 1);
        // 1 second before threshold → still Tier 1
        assertEq(harness.identityFee(user1), 3000);
    }

    function test_identityFee_afterClear_revertsToTier0() public {
        harness.registerCompliance(user1);
        assertEq(harness.identityFee(user1), 3000); // Tier 1

        harness.clearCompliance(user1);
        assertEq(harness.identityFee(user1), 20000); // Back to Tier 0
    }

    function test_identityFee_complianceSince_persists() public {
        harness.registerCompliance(user1);
        uint256 since = harness.complianceSince(user1);
        assertTrue(since > 0);

        // Clear and re-register — timestamp should NOT reset
        harness.clearCompliance(user1);
        harness.registerCompliance(user1);
        assertEq(harness.complianceSince(user1), since);
    }

    // =========================================================================
    //        Default parameter values
    // =========================================================================

    function test_defaultParameters() public {
        assertEq(harness.TIER0_FEE(), 20000);
        assertEq(harness.TIER1_FEE(), 3000);
        assertEq(harness.TIER2_FEE(), 1500);
        assertEq(harness.SIZE_THRESHOLD_BPS(), 200);
        assertEq(harness.SIZE_SCALING_FACTOR(), 10);
    }

    // =========================================================================
    //           Hook Fee: output amount calculation
    // =========================================================================

    function test_hookFee_zeroDelta_returnsZero() public {
        BalanceDelta zeroDelta = BalanceDeltaLibrary.ZERO_DELTA;
        assertEq(harness.calculateHookFee(zeroDelta), 0);
    }

    function test_hookFee_negativeDelta_returnsZero() public {
        BalanceDelta negativeDelta = toBalanceDelta(-1000, -500);
        assertEq(harness.calculateHookFee(negativeDelta), 0);
    }

    function test_hookFee_positiveAmount1_returns5Percent() public {
        BalanceDelta delta = toBalanceDelta(0, 1000);
        assertEq(harness.calculateHookFee(delta), 50);
    }

    function test_hookFee_positiveAmount0_returns5Percent() public {
        BalanceDelta delta = toBalanceDelta(2000, 0);
        assertEq(harness.calculateHookFee(delta), 100);
    }

    function test_hookFee_bothPositive_prefersAmount1() public {
        BalanceDelta delta = toBalanceDelta(500, 1000);
        assertEq(harness.calculateHookFee(delta), 50);
    }

    function test_hookFee_amount1Zero_usesAmount0() public {
        BalanceDelta delta = toBalanceDelta(4000, 0);
        assertEq(harness.calculateHookFee(delta), 200);
    }

    function test_hookFee_largeOutput_correctFee() public {
        BalanceDelta delta = toBalanceDelta(0, 1_000_000);
        assertEq(harness.calculateHookFee(delta), 50_000);
    }

    function test_hookFee_smallOutput_truncated() public {
        BalanceDelta delta = toBalanceDelta(0, 19);
        assertEq(harness.calculateHookFee(delta), 0);
    }

    function test_hookFee_exact20_returns1() public {
        BalanceDelta delta = toBalanceDelta(0, 20);
        assertEq(harness.calculateHookFee(delta), 1);
    }
}
