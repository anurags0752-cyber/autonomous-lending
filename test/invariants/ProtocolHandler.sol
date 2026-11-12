// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {MockERC20} from "../unit/LendingPool.t.sol"; // Reusing your mock from unit tests

contract ProtocolHandler is Test {
    LendingPool public pool;
    MockERC20 public weth;
    MockERC20 public usdc;
    
    // Ghost Variables to track expected state
    uint256 public ghost_totalWethDeposited;
    uint256 public ghost_totalUsdcDeposited;

    constructor(LendingPool _pool, MockERC20 _weth, MockERC20 _usdc) {
        pool = _pool;
        weth = _weth;
        usdc = _usdc;
    }

    // --- Fuzzer Actions ---

    function depositCollateral(uint256 amount) public {
        // Bound the fuzz amount to something reasonable (between 1 wei and 1000 WETH)
        amount = bound(amount, 1, 1000e18);
        
        // Mint the WETH to the handler so it has funds to deposit
        weth.mint(address(this), amount);
        weth.approve(address(pool), amount);
        
        pool.depositCollateral(amount);
        ghost_totalWethDeposited += amount;
    }

    function depositLiquidity(uint256 amount) public {
        // Bound between 1 USDC and 1,000,000 USDC
        amount = bound(amount, 1, 1_000_000e6);
        
        usdc.mint(address(this), amount);
        usdc.approve(address(pool), amount);
        
        pool.depositLiquidity(amount);
        ghost_totalUsdcDeposited += amount;
    }

    function borrow(uint256 amount) public {
        // Can't borrow if there is no liquidity
        uint256 poolCash = usdc.balanceOf(address(pool));
        if (poolCash == 0) return;

        // Bound borrow amount to not exceed the pool's cash
        amount = bound(amount, 1, poolCash);

        // Try to borrow. We wrap in a try/catch because the fuzzer might try to 
        // borrow more than its Health Factor allows. If it reverts due to HF, that's fine.
        try pool.borrow(amount) {
            // Success
        } catch {
            // Reverted (likely undercollateralized), ignore and continue fuzzing
        }
    }

    function repay(uint256 amount) public {
        pool.updateState();
        uint256 userShares = pool.debtShares(address(this));
        if (userShares == 0) return;

        uint256 userActualDebt = (userShares * pool.borrowIndex()) / 1e27;
        if (userActualDebt == 0) return;

        amount = bound(amount, 1, userActualDebt);

        // Ensure handler has enough USDC (including accrued interest) to repay
        usdc.mint(address(this), amount);
        usdc.approve(address(pool), amount);

        pool.repay(amount);
    }

    function withdrawCollateral(uint256 amount) public {
        uint256 deposited = pool.collateralBalance(address(this));
        if (deposited == 0) return;

        amount = bound(amount, 1, deposited);

        // May revert if withdrawing drops Health Factor below 1e18
        try pool.withdrawCollateral(amount) {
            ghost_totalWethDeposited -= amount;
        } catch {
            // Reverted due to Health Factor check
        }
    }

    function withdrawLiquidity(uint256 shares) public {
        uint256 userShares = pool.liquidityShares(address(this));
        if (userShares == 0) return;

        shares = bound(shares, 1, userShares);

        // May revert if pool cash is currently utilized by active borrows
        try pool.withdrawLiquidity(shares) {
            // Success
        } catch {
            // Reverted due to insufficient free cash in pool
        }
    }
    
    function warpTime(uint256 jump) public {
        // Fast forward time between 1 hour and 30 days
        jump = bound(jump, 3600, 30 days);
        vm.warp(block.timestamp + jump);
    }
}