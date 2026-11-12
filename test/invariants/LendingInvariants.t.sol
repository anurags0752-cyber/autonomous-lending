// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {OracleRouter} from "../../src/OracleRouter.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockERC20} from "../unit/LendingPool.t.sol";
import {ProtocolHandler} from "./ProtocolHandler.sol";
import {IUniswapV2Router02} from "../../src/LendingPool.sol";


contract LendingInvariantsTest is Test {
    LendingPool public pool;
    ProtocolHandler public handler;
    MockERC20 public weth;
    MockERC20 public usdc;

    function setUp() public {
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        MockV3Aggregator wethFeed = new MockV3Aggregator(8, 3000e8);
        MockV3Aggregator usdcFeed = new MockV3Aggregator(8, 1e8);

        OracleRouter oracleRouter = new OracleRouter();
        oracleRouter.setFeed(address(weth), address(wethFeed), type(uint32).max);
        oracleRouter.setFeed(address(usdc), address(usdcFeed), type(uint32).max);

        InterestRateModel rateModel = new InterestRateModel(0.8e27, 0, 0.04e27, 0.75e27);

        pool = new LendingPool(
            address(weth),
            address(usdc),
            address(rateModel),
            address(oracleRouter),
            0.8e18,
            IUniswapV2Router02(address(0x3)),
            1.05e18
        );

        // Initialize the handler
        handler = new ProtocolHandler(pool, weth, usdc);
        
        // Tell Foundry to only fuzz the handler contract, not the whole suite
        targetContract(address(handler));
    }

    // --- INVARIANTS ---

    /// @notice The pool's actual WETH balance must always be >= what the handler deposited.
    /// Ensures collateral is never lost or leaked.
    function invariant_CollateralIsSecure() public view {
        uint256 actualWethBalance = weth.balanceOf(address(pool));
        assertGe(actualWethBalance, handler.ghost_totalWethDeposited());
    }

    /// @notice The protocol must always remain solvent.
    /// Total Assets (Cash + Debt) must ALWAYS be >= Total Depositor Shares
    function invariant_ProtocolSolvency() public {
        // We must update state to get the latest accrued interest
        pool.updateState();

        uint256 poolCash = usdc.balanceOf(address(pool));
        
        // Convert debt shares to actual debt using the global index
        uint256 currentBorrowIndex = pool.borrowIndex();
        uint256 totalActualDebt = (pool.totalDebtShares() * currentBorrowIndex) / 1e27;
        
        uint256 totalAssets = poolCash + totalActualDebt;
        
        // Convert liquidity shares to actual expected value
        // Since we aren't taking a protocol fee in this iteration, 
        // 1 Share should equal exactly the proportion of Total Assets.
        // Therefore, Total Assets must perfectly cover Total Liquidity Shares.
        assertGe(totalAssets, pool.totalLiquidityShares());
    }
}