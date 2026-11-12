// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../../src/LendingPool.sol";

contract MockUniswapV2Router {
    // swapTokensForExactTokens(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        IERC20 weth = IERC20(path[0]);
        IERC20 usdc = IERC20(path[1]);

        // In a real scenario, this is based on the AMM curve. 
        // For our mock, we will just say it cost 80% of the max amount in.
        uint256 amountIn = (amountInMax * 80) / 100;

        // Take WETH from the pool
        weth.transferFrom(msg.sender, address(this), amountIn);
        
        // Give USDC to the pool
        usdc.transfer(to, amountOut);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
        return amounts;
    }
}