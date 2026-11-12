// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "@solady/contracts/utils/FixedPointMathLib.sol";

contract InterestRateModel {
    // 1 RAY = 1e27. Used for precise interest accumulation per second.
    uint256 internal constant RAY = 1e27;

    uint256 public immutable OPTIMAL_USAGE_RATIO;
    uint256 public immutable BASE_BORROW_RATE;
    
    /// @dev Aave V3 refers to this as SLOPE_1. Mathematically, it is not a geometric slope, 
    /// but rather the maximum y-axis yield delta reached exactly at the OPTIMAL_USAGE_RATIO.
    uint256 public immutable MAX_BASE_YIELD;
    
    /// @dev Aave V3 refers to this as SLOPE_2. It represents the maximum y-axis penalty yield 
    /// added as utilization scales from the optimal ratio up to 100%.
    uint256 public immutable MAX_PENALTY_YIELD;

    /// @param _optimalUsageRatio Target utilization (e.g., 0.8 * 1e27 for 80%)
    /// @param _baseBorrowRate Base APR when utilization is 0
    /// @param _maxBaseYield APR delta reached at optimal usage (formerly slope 1)
    /// @param _maxPenaltyYield APR penalty delta reached at 100% usage (formerly slope 2)
    constructor(
        uint256 _optimalUsageRatio, 
        uint256 _baseBorrowRate, 
        uint256 _maxBaseYield, 
        uint256 _maxPenaltyYield
    ) {
        OPTIMAL_USAGE_RATIO = _optimalUsageRatio;
        BASE_BORROW_RATE = _baseBorrowRate;
        MAX_BASE_YIELD = _maxBaseYield;
        MAX_PENALTY_YIELD = _maxPenaltyYield;
    }

    /// @notice Calculates the current borrow rate in RAY (1e27)
    /// @param cash Total liquidity available in the pool
    /// @param borrows Total outstanding borrowed amount
    function calculateBorrowRate(uint256 cash, uint256 borrows) public view returns(uint256) {
        if (borrows == 0) return BASE_BORROW_RATE;

        uint256 totalLiquidity = cash + borrows;
        
        // utilization = (borrows * RAY) / totalLiquidity
        uint256 utilizationRate = FixedPointMathLib.mulDiv(borrows, RAY, totalLiquidity);

        if (utilizationRate <= OPTIMAL_USAGE_RATIO) {
            // rate = base + (utilization / optimal) * maxBaseYield
            uint256 extra = FixedPointMathLib.mulDiv(utilizationRate, MAX_BASE_YIELD, OPTIMAL_USAGE_RATIO);
            return BASE_BORROW_RATE + extra;
        } else {
            // rate = base + maxBaseYield + ((utilization - optimal) / (1 - optimal)) * maxPenaltyYield
            uint256 excessUtilization = utilizationRate - OPTIMAL_USAGE_RATIO;
            uint256 excessRatio = RAY - OPTIMAL_USAGE_RATIO;
            uint256 extra = FixedPointMathLib.mulDiv(excessUtilization, MAX_PENALTY_YIELD, excessRatio);
            
            return BASE_BORROW_RATE + MAX_BASE_YIELD + extra;
        }
    }
}