// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool, IUniswapV2Router02} from "../../src/LendingPool.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {OracleRouter} from "../../src/OracleRouter.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {ERC20} from "@solady/contracts/tokens/ERC20.sol";
import {MockUniswapV2Router} from "../mocks/MockUniswapV2Router.sol";

// Simple Mock ERC20 for testing
contract MockERC20 is ERC20 {
    string _name;
    string _symbol;
    uint8 _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }
    function name() public view override returns (string memory) { return _name; }
    function symbol() public view override returns (string memory) { return _symbol; }
    function decimals() public view override returns (uint8) { return _decimals; }
    function mint(address to, uint256 amount) public { _mint(to, amount); }
}

contract LendingPoolTest is Test {
    LendingPool public pool;
    InterestRateModel public rateModel;
    OracleRouter public oracleRouter;
    
    MockERC20 public weth;
    MockERC20 public usdc;
    
    MockV3Aggregator public wethFeed;
    MockV3Aggregator public usdcFeed;
    MockUniswapV2Router public mockRouter;

    address public alice = address(0x1);
    address public bob = address(0x2);

    function setUp() public {
        // 1. Deploy Tokens (WETH = 18 decimals, USDC = 6 decimals)
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // 2. Deploy Oracles ($3000 ETH, $1 USDC - 8 decimals standard for Chainlink)
        wethFeed = new MockV3Aggregator(8, 3000e8);
        usdcFeed = new MockV3Aggregator(8, 1e8);

        oracleRouter = new OracleRouter();
        oracleRouter.setFeed(address(weth), address(wethFeed), 86400); // 1 day heartbeat
        oracleRouter.setFeed(address(usdc), address(usdcFeed), 86400);

        // 3. Deploy Interest Rate Model & Mock AMM Router
        rateModel = new InterestRateModel(0.8e27, 0, 0.04e27, 0.75e27);
        mockRouter = new MockUniswapV2Router();
        usdc.mint(address(mockRouter), 5000e6);

        // 4. Deploy Pool (80% Liquidation Threshold, 5% Liquidation Bonus)
        pool = new LendingPool(
            address(weth),
            address(usdc),
            address(rateModel),
            address(oracleRouter),
            0.8e18,
            IUniswapV2Router02(address(mockRouter)),
            1.05e18
        );

        // Fund Alice and Bob
        weth.mint(alice, 10e18);
        usdc.mint(bob, 10000e6); // Bob provides initial USDC liquidity
    }

    function test_DepositAndBorrow_InterestAccrual() public {
        // 1. Bob deposits 10,000 USDC liquidity
        vm.startPrank(bob);
        usdc.approve(address(pool), 10000e6);
        pool.depositLiquidity(10000e6);
        vm.stopPrank();

        // 2. Alice deposits 2 WETH as collateral
        vm.startPrank(alice);
        weth.approve(address(pool), 2e18);
        pool.depositCollateral(2e18);

        // Oracles: 2 WETH = $6,000. 
        // Max borrow at 80% LT = $4,800.
        // Alice borrows 1,000 USDC.
        pool.borrow(1000e6);
        vm.stopPrank();

        // Check Alice's initial debt
        uint256 initialDebtShares = pool.debtShares(alice);
        // Because the index starts at 1 RAY, 1 share = 1 USDC initially
        assertEq(initialDebtShares, 1000e6); 

        // 3. Time Warp! Fast forward 1 year (31,536,000 seconds)
        vm.warp(block.timestamp + 31536000);

        // 4. Force state update to compound the interest
        pool.updateState();

        // 5. Verify the math
        uint256 currentBorrowIndex = pool.borrowIndex();
        
        // Index must be > 1e27 because interest accrued
        assertGt(currentBorrowIndex, 1e27); 

        uint256 aliceActualDebt = pool.debtShares(alice) * currentBorrowIndex / 1e27;
        
        // Alice must owe MORE than her initial 1,000 USDC
        assertGt(aliceActualDebt, 1000e6);
        
        // // Logging the actual debt to the console so you can see the math working
        // console1.log("Alice original borrow: ", 1000e6);
        // console1.log("Alice debt after 1 year: ", aliceActualDebt);
    }

    function test_Liquidation() public {
        // 1. Bob provides liquidity
        vm.startPrank(bob);
        usdc.approve(address(pool), 10000e6);
        pool.depositLiquidity(10000e6);
        vm.stopPrank();

        // 3. Alice deposits collateral and borrows
        vm.startPrank(alice);
        weth.approve(address(pool), 2e18);
        pool.depositCollateral(2e18); // 2 WETH = $6000
        
        // Max borrow is 80% of $6000 = $4800. Alice borrows $4000. HF = 1.2
        pool.borrow(4000e6);
        vm.stopPrank();

        uint256 aliceHFBefore = pool.calculateHealthFactor(alice);
        assertGt(aliceHFBefore, 1e18); // Alice is safe

        // 4. CRASH THE MARKET
        // WETH drops from $3,000 to $1,500. 
        // 2 WETH is now $3000. 80% threshold = $2400 max borrow.
        // Alice owes $4000. She is vastly undercollateralized.
        wethFeed.updateAnswer(1500e8);

        uint256 aliceHFAfter = pool.calculateHealthFactor(alice);
        assertLt(aliceHFAfter, 1e18); // Alice is in danger!

        // 5. Bot (Charlie) triggers liquidation
        address charlie = address(0x3);
        vm.startPrank(charlie);
        
        // Charlie liquidates 1000 USDC of Alice's debt
        pool.liquidate(alice, 1000e6);
        vm.stopPrank();

        // 6. Verify Results
        // Charlie should have received a WETH reward (the dust left over from the AMM swap)
        uint256 charlieWethBalance = weth.balanceOf(charlie);
        assertGt(charlieWethBalance, 0); 
        // console.log("Charlie (Liquidator) WETH Profit: ", charlieWethBalance);

        // Alice's debt should be reduced
        uint256 aliceDebtNow = pool.debtShares(alice);
        assertEq(aliceDebtNow, 3000e6); // 4000 - 1000
    }
}