// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";

contract InterestRateModelTest  is Test {
    
    InterestRateModel public rateModel;

    uint256 OPTIMAL_USAGE_RATIO = 0.8e27;    // 80%
    uint256 BASE_BORROW_RATE = 0.02e27;         
    uint256 MAX_BASE_YIELD = 0.04e27;       // 4%
    uint256 MAX_PENALTY_YIELD = 0.75e27;    // 75%

    function setUp() public {
        rateModel = new InterestRateModel(OPTIMAL_USAGE_RATIO, BASE_BORROW_RATE, MAX_BASE_YIELD, MAX_PENALTY_YIELD);
    }

    /// @notice When borrows = 0, utilization is 0%. Rate must be exactly BASE_BORROW_RATE.
    function test_borrowRate_zeroUtilization() public view {

        uint256 borrowRate = rateModel.calculateBorrowRate(1e18, 0);
        assertEq(borrowRate, BASE_BORROW_RATE);
    }

    /// @notice When borrows = 80percent. Rate must be exactly BASE_BORROW_RATE + MAX_BASE_YIELD.
    function test_borrowRate_optimalUtilization() public view {
        
        uint256 cash = 2e18;
        uint borrow = 8e18;
        uint256 borrowRate = rateModel.calculateBorrowRate(cash, borrow);
        uint256 expentedRate = BASE_BORROW_RATE+MAX_BASE_YIELD;
        assertEq(borrowRate, expentedRate);
    }

    /// @notice When cash = 0 (100% utilization), rate must hit the absolute ceiling.
    function test_borrowRate_maxRate() public view {

        uint256 cash = 0;
        uint256 borrow = 1e18;
        uint256 borrowRate = rateModel.calculateBorrowRate(cash, borrow);
        uint256 expentedRate =  BASE_BORROW_RATE + MAX_BASE_YIELD + MAX_PENALTY_YIELD;
        assertEq(borrowRate, expentedRate);
    }

    // --- Midpoint Interpolation Tests ---

    /// @notice Halfway to optimal (40% utilization). Rate should be BASE + 50% of MAX_BASE_YIELD.
    function test_borrowRate_MidSlope1() public view {

        uint256 cash = 6e18;
        uint256 borrow = 4e18;
        uint256 expectedRate = BASE_BORROW_RATE + (MAX_BASE_YIELD/2);
        uint256 borrowRate = rateModel.calculateBorrowRate(cash, borrow);
        assertEq(borrowRate, expectedRate);

    }

    /// @notice Halfway between optimal and max (90% utilization).
    /// Rate should be BASE + MAX_BASE_YIELD + 50% of MAX_PENALTY_YIELD.
    function test_borrowRate_MidSlope2() public view{

        uint256 cash = 1e18;
        uint256 borrow = 9e18;
        uint256 expectedRate = BASE_BORROW_RATE + MAX_BASE_YIELD + (MAX_PENALTY_YIELD/2);
        uint256 borrowRate = rateModel.calculateBorrowRate(cash, borrow);
        assertEq(borrowRate, expectedRate);

    }

    // --- Edge Case: Cash = 0 and Borrows = 0 ---
    function test_BorrowRate_ZeroLiquidityAndZeroBorrows() public view {
        uint256 cash = 0;
        uint256 borrow = 0;
        uint256 expectedRate = BASE_BORROW_RATE;
        uint256 borrowRate = rateModel.calculateBorrowRate(cash, borrow);
        assertEq(borrowRate, expectedRate);
    }

    function testFuzz_RateMonotonicallyIncreases(uint128 cash, uint128 borrowA, uint128 borrowB) public view{
        vm.assume(cash>0);
        vm.assume(borrowA <= borrowB);
        // Avoid overflow in totalLiquidity = cash + borrows
        vm.assume(uint256(cash) + uint256(borrowB) <= type(uint128).max);

        uint256 rateA = rateModel.calculateBorrowRate(cash, borrowA);
        uint256 rateB = rateModel.calculateBorrowRate(cash, borrowB);
        assertGe(rateB, rateA);
    }

}