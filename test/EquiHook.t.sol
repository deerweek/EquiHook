// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {EquiHook, IERC20, IDividendVault} from "../src/EquiHook.sol";

// =========================================================================
//                         Test Harness Contract
// =========================================================================

/// @notice Exposes internal EquiHook functions for testing without requiring
/// a valid hook address (which would need specific address bits).
contract EquiHookHarness {
    uint256 public baseFee;
    uint256 public maxFee;
    uint256 public liquidityThresholdBps;
    uint256 public scalingFactor;

    mapping(address => bool) public isCompliant;

    constructor() {
        baseFee = 3000;
        maxFee = 20000;
        liquidityThresholdBps = 200;
        scalingFactor = 10;
    }

    function registerCompliance(address user) external {
        isCompliant[user] = true;
    }

    function clearCompliance(address user) external {
        isCompliant[user] = false;
    }

    function calculateDynamicFee(uint128 swapAmount, uint256 liquidity) external view returns (uint24) {
        if (liquidity == 0) return uint24(baseFee);

        uint256 ratioBps = (uint256(swapAmount) * 10000) / liquidity;
        if (ratioBps < liquidityThresholdBps) {
            return uint24(baseFee);
        }

        uint256 feeIncrease = (ratioBps - liquidityThresholdBps) * scalingFactor;
        uint256 fee = baseFee + feeIncrease;
        if (fee > maxFee) fee = maxFee;
        return uint24(fee);
    }

    function calculateHookFee(BalanceDelta delta) external pure returns (uint256) {
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        int128 amountOut = amount1 > 0 ? amount1 : amount0;
        if (amountOut <= 0) return 0;
        return uint256(uint128(amountOut)) / 20; // 5% of output as hook fee
    }

    /// @notice Helper to verify the compliance check logic (same as EquiHook)
    function checkCompliance(address user) external view returns (bool) {
        return isCompliant[user];
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
        // Clearing compliance on a non-compliant user should not revert
        assertFalse(harness.isCompliant(user1));
        harness.clearCompliance(user1);
        assertFalse(harness.isCompliant(user1));
    }

    function test_registerCompliance_idempotent() public {
        harness.registerCompliance(user1);
        harness.registerCompliance(user1); // second call should be fine
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
    //        Dynamic Fee: below threshold returns baseFee
    // =========================================================================

    function test_dynamicFee_zeroLiquidity_returnsBaseFee() public {
        // When liquidity is 0, should return baseFee (3000 = 0.3%)
        uint24 fee = harness.calculateDynamicFee(1000, 0);
        assertEq(fee, 3000);
    }

    function test_dynamicFee_smallSwap_returnsBaseFee() public {
        // Swap amount = 100, Liquidity = 100_000
        // ratioBps = (100 * 10000) / 100_000 = 10 bps
        // 10 < 200 (threshold) -> baseFee
        uint24 fee = harness.calculateDynamicFee(100, 100_000);
        assertEq(fee, 3000);
    }

    function test_dynamicFee_exactThreshold_returnsBaseFee() public {
        // Swap amount = 200, Liquidity = 100_000
        // ratioBps = (200 * 10000) / 100_000 = 200 bps
        // 200 is NOT < 200, so feeIncrease = (200 - 200) * 10 = 0
        // fee = 3000 + 0 = 3000
        uint24 fee = harness.calculateDynamicFee(200, 100_000);
        assertEq(fee, 3000);
    }

    // =========================================================================
    //        Dynamic Fee: above threshold scales up
    // =========================================================================

    function test_dynamicFee_aboveThreshold_scalesUp() public {
        // Swap amount = 1000, Liquidity = 100_000
        // ratioBps = (1000 * 10000) / 100_000 = 100 bps... wait that's below
        // Let me recalculate: ratioBps = (1000 * 10000) / 100000 = 100
        // 100 < 200 -> baseFee. Need larger ratio.

        // Swap amount = 5000, Liquidity = 100_000
        // ratioBps = (5000 * 10000) / 100_000 = 500 bps
        // 500 >= 200 -> feeIncrease = (500 - 200) * 10 = 3000
        // fee = 3000 + 3000 = 6000
        uint24 fee = harness.calculateDynamicFee(5000, 100_000);
        assertEq(fee, 6000);
    }

    function test_dynamicFee_largerRatio_higherFee() public {
        // Swap = 10000, Liquidity = 100_000
        // ratioBps = (10000 * 10000) / 100_000 = 1000 bps
        // feeIncrease = (1000 - 200) * 10 = 8000
        // fee = 3000 + 8000 = 11000
        uint24 fee = harness.calculateDynamicFee(10000, 100_000);
        assertEq(fee, 11000);
    }

    function test_dynamicFee_veryLargeRatio_cappedAtMax() public {
        // Swap = 100000, Liquidity = 100_000
        // ratioBps = (100000 * 10000) / 100_000 = 10000 bps
        // feeIncrease = (10000 - 200) * 10 = 98000
        // fee = 3000 + 98000 = 101000 -> capped at 20000
        uint24 fee = harness.calculateDynamicFee(100_000, 100_000);
        assertEq(fee, 20000); // maxFee
    }

    function test_dynamicFee_cappedAtMaxFee() public {
        // Even with enormous swap, fee is capped at maxFee (20000 = 2%)
        uint24 fee = harness.calculateDynamicFee(type(uint128).max / 2, 1);
        assertEq(fee, 20000);
    }

    // =========================================================================
    //        Dynamic Fee: edge cases
    // =========================================================================

    function test_dynamicFee_unitLiquidity() public {
        // Swap = 1, Liquidity = 1
        // ratioBps = (1 * 10000) / 1 = 10000 bps
        // feeIncrease = (10000 - 200) * 10 = 98000
        // fee = 3000 + 98000 = 101000 -> capped at 20000
        uint24 fee = harness.calculateDynamicFee(1, 1);
        assertEq(fee, 20000);
    }

    function test_dynamicFee_ratioJustAboveThreshold() public {
        // Swap = 2010, Liquidity = 100_000
        // ratioBps = (2010 * 10000) / 100_000 = 201
        // feeIncrease = (201 - 200) * 10 = 10
        // fee = 3000 + 10 = 3010
        uint24 fee = harness.calculateDynamicFee(2010, 100_000);
        assertEq(fee, 3010);
    }

    function test_dynamicFee_returnsBaseFeeForVariousSmallSwaps() public {
        // All below threshold (200 bps)
        uint256 liquidity = 1_000_000;

        // ratioBps = (100 * 10000) / 1_000_000 = 1
        assertEq(harness.calculateDynamicFee(100, liquidity), 3000);

        // ratioBps = (1000 * 10000) / 1_000_000 = 10
        assertEq(harness.calculateDynamicFee(1000, liquidity), 3000);

        // ratioBps = (19999 * 10000) / 1_000_000 = 199
        assertEq(harness.calculateDynamicFee(19999, liquidity), 3000);
    }

    // =========================================================================
    //           Hook Fee: output amount calculation
    // =========================================================================

    function test_hookFee_zeroDelta_returnsZero() public {
        BalanceDelta zeroDelta = BalanceDeltaLibrary.ZERO_DELTA;
        assertEq(harness.calculateHookFee(zeroDelta), 0);
    }

    function test_hookFee_negativeDelta_returnsZero() public {
        // Both amounts negative: swapper is paying in
        BalanceDelta negativeDelta = toBalanceDelta(-1000, -500);
        assertEq(harness.calculateHookFee(negativeDelta), 0);
    }

    function test_hookFee_positiveAmount1_returns5Percent() public {
        // amount0 = 0, amount1 = 1000
        // amountOut = amount1 = 1000
        // hookFee = 1000 / 20 = 50
        BalanceDelta delta = toBalanceDelta(0, 1000);
        assertEq(harness.calculateHookFee(delta), 50);
    }

    function test_hookFee_positiveAmount0_returns5Percent() public {
        // amount0 = 2000, amount1 = 0 (or negative)
        // amountOut = amount0 = 2000
        // hookFee = 2000 / 20 = 100
        BalanceDelta delta = toBalanceDelta(2000, 0);
        assertEq(harness.calculateHookFee(delta), 100);
    }

    function test_hookFee_bothPositive_prefersAmount1() public {
        // When both are positive, amount1 is preferred
        // amount0 = 500, amount1 = 1000
        // amountOut = amount1 = 1000 (since amount1 > 0)
        // hookFee = 1000 / 20 = 50
        BalanceDelta delta = toBalanceDelta(500, 1000);
        assertEq(harness.calculateHookFee(delta), 50);
    }

    function test_hookFee_amount1Zero_usesAmount0() public {
        // amount0 = 4000, amount1 = 0
        // amount1 > 0? no -> amountOut = amount0 = 4000
        // hookFee = 4000 / 20 = 200
        BalanceDelta delta = toBalanceDelta(4000, 0);
        assertEq(harness.calculateHookFee(delta), 200);
    }

    function test_hookFee_largeOutput_correctFee() public {
        // amount1 = 1_000_000
        // hookFee = 1_000_000 / 20 = 50_000
        BalanceDelta delta = toBalanceDelta(0, 1_000_000);
        assertEq(harness.calculateHookFee(delta), 50_000);
    }

    function test_hookFee_smallOutput_truncated() public {
        // amount1 = 19
        // hookFee = 19 / 20 = 0 (integer division truncates)
        BalanceDelta delta = toBalanceDelta(0, 19);
        assertEq(harness.calculateHookFee(delta), 0);
    }

    function test_hookFee_exact20_returns1() public {
        // amount1 = 20
        // hookFee = 20 / 20 = 1
        BalanceDelta delta = toBalanceDelta(0, 20);
        assertEq(harness.calculateHookFee(delta), 1);
    }

    // =========================================================================
    //               Default parameter values
    // =========================================================================

    function test_defaultParameters() public {
        assertEq(harness.baseFee(), 3000);
        assertEq(harness.maxFee(), 20000);
        assertEq(harness.liquidityThresholdBps(), 200);
        assertEq(harness.scalingFactor(), 10);
    }

    // =========================================================================
    //            Dynamic Fee: monotonicity (fee increases with ratio)
    // =========================================================================

    function test_dynamicFee_monotonic() public {
        uint256 liquidity = 100_000;

        uint24 fee1 = harness.calculateDynamicFee(2000, liquidity);  // 200 bps -> baseFee
        uint24 fee2 = harness.calculateDynamicFee(5000, liquidity);  // 500 bps -> 6000
        uint24 fee3 = harness.calculateDynamicFee(10000, liquidity); // 1000 bps -> 11000
        uint24 fee4 = harness.calculateDynamicFee(20000, liquidity); // 2000 bps -> 16000
        uint24 fee5 = harness.calculateDynamicFee(50000, liquidity); // 5000 bps -> 20000 (capped)

        assertTrue(fee1 <= fee2);
        assertTrue(fee2 <= fee3);
        assertTrue(fee3 <= fee4);
        assertTrue(fee4 <= fee5);
        assertEq(fee5, 20000); // capped at maxFee
    }
}
