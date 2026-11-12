// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "@solady/contracts/utils/FixedPointMathLib.sol";
import {InterestRateModel} from "./InterestRateModel.sol";
import {OracleRouter} from "./OracleRouter.sol";
import {ReentrancyGuard} from "@solady/contracts/utils/ReentrancyGuard.sol";

interface IERC20 {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool); 
}

interface IUniswapV2Router02 {
    /// @notice Swaps tokens up to amountInMax for exactly amountOut
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract LendingPool is ReentrancyGuard {

    error LendingPool__AtleastBorrowSomething();

    event DepositCollateral(address indexed user, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 amount);
    event DepositLiquidity(address indexed user, uint256 amount, uint256 sharesMinted);
    event WithdrawLiquidity(address indexed user, uint256 sharesBurned, uint256 amountReturned);
    event Borrow(address indexed user, uint256 amount, uint256 debtSharesMinted);
    event Repay(address indexed user, uint256 amountRepaid, uint256 debtSharesBurned);
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        uint256 debtCovered,
        uint256 collateralSeized,
        uint256 liquidatorReward
    );

    uint256 constant internal RAY = 1e27;
    uint256 constant internal WAD = 1e18;
    uint256 constant internal SECONDS_PER_YEAR = 31536000;

    IERC20 public immutable collateralAsset;
    IERC20 public immutable borrowAsset;

    InterestRateModel public immutable rateModel;
    OracleRouter public immutable oracle;
    IUniswapV2Router02 public immutable uniswapRouter;

    uint256 public immutable liquidationThreshold;

    uint256 public totalDebtShares;
    uint256 public borrowIndex = RAY;
    uint256 public lastUpdateTimestamp;
    uint256 public immutable liquidationBonus; 
    uint256 public totalLiquidityShares;

    mapping(address => uint256) public liquidityShares;
    mapping(address => uint256) public collateralBalance;
    mapping(address => uint256) public debtShares;

    constructor(address _collateralAsset, address _borrowAsset, address _rateModel, address _oracle, uint256 _liquidationThreshold, IUniswapV2Router02 _uniswapRouter, uint256 _liquidationBonus){
        collateralAsset = IERC20(_collateralAsset);
        borrowAsset = IERC20(_borrowAsset);
        rateModel = InterestRateModel(_rateModel);
        oracle = OracleRouter(_oracle);
        liquidationThreshold = _liquidationThreshold;

        lastUpdateTimestamp = block.timestamp;
        uniswapRouter = _uniswapRouter;
        liquidationBonus = _liquidationBonus;
    }

    /// @notice Must be called before ANY state-modifying action (deposit, borrow, repay, withdraw)
    function updateState() public {
        uint256 deltaTime = block.timestamp - lastUpdateTimestamp;
        if(deltaTime == 0) return;

        lastUpdateTimestamp = block.timestamp;
        if(totalDebtShares == 0) return;

        uint256 totalActualDebt = FixedPointMathLib.mulDiv(totalDebtShares, borrowIndex, RAY);
        uint256 availableCash = borrowAsset.balanceOf(address(this));

        // Get annualized rate in RAY
        uint256 borrowRate = rateModel.calculateBorrowRate(availableCash, totalActualDebt);

        // Linear approximation of interest accumulated over deltaTime
        // interestFactor = (rate * time) / YEAR
        uint256 interestFactor = FixedPointMathLib.mulDiv(borrowRate, deltaTime, SECONDS_PER_YEAR);

        // newIndex = oldIndex + (oldIndex * interestFactor / RAY)
        borrowIndex += FixedPointMathLib.mulDiv(borrowIndex, interestFactor, RAY);

    }

    /// @notice Returns the Health Factor scaled to 1e18. < 1e18 means liquidatable.
    function calculateHealthFactor(address user) public view returns (uint256){

        uint256 userShares = debtShares[user];
        if (userShares == 0) return type(uint256).max;

        uint256 userCollateral = collateralBalance[user];
        if (userCollateral == 0) return 0; // Debt with no collateral = instant liquidation

        // 1. Calculate actual debt in borrowAsset tokens
        uint256 userActualDebt = FixedPointMathLib.mulDiv(userShares, borrowIndex, RAY);
       
        // 2. Fetch prices (normalized to 1e18 by the Router)
        uint256 colPrice = oracle.getPrice(address(collateralAsset));
        uint256 debtPrice = oracle.getPrice(address(borrowAsset));

        // 3. Normalize asset amounts to 18 decimals to calculate standard USD value
        uint256 colDecimals = collateralAsset.decimals();
        uint256 debtDecimals = borrowAsset.decimals();

        // USD Value = (Normalized Amount * Price) / 1e18
        uint256 colValInUsd = FixedPointMathLib.mulDiv(userCollateral* (10 ** (18-colDecimals)), colPrice, WAD);

        uint256 debtValueInUsd = FixedPointMathLib.mulDiv(userActualDebt * (10 ** (18- debtDecimals)),debtPrice,WAD);

        // 4. HF = (Collateral Value * Liquidation Threshold) / Debt Value
        // If colValue=1000, threshold=0.8, debtValue=800 -> HF = 1.0 (1e18)

        return FixedPointMathLib.mulDiv(colValInUsd, liquidationThreshold, debtValueInUsd);
    }

    // --- Core User Actions ---



    // --- 1. Collateral (WETH) ---

    function depositCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "LendingPool: Amount must be > 0");
        updateState();
        collateralBalance[msg.sender] += amount;
        bool success = collateralAsset.transferFrom(msg.sender, address(this), amount);
        require(success, "LendingPool: Transfer failed");
        emit DepositCollateral(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "LendingPool: Amount must be > 0");
        updateState();
        collateralBalance[msg.sender] -= amount; 
        require(calculateHealthFactor(msg.sender) >= WAD, "LendingPool: Undercollateralized");
        bool success = collateralAsset.transfer(msg.sender, amount);
        require(success, "LendingPool: Transfer failed");
        emit WithdrawCollateral(msg.sender, amount);
    }

    // --- 2. Liquidity (USDC) ---

    function depositLiquidity(uint256 amount) external nonReentrant {
        require(amount > 0, "LendingPool: Amount must be > 0");
        updateState();

        uint256 totalActualDebt = FixedPointMathLib.mulDiv(totalDebtShares, borrowIndex, RAY);
        uint256 availableCash = borrowAsset.balanceOf(address(this));
        uint256 totalExpectedAssets = availableCash + totalActualDebt;

        uint256 sharesToMint;
        if (totalLiquidityShares == 0 || totalExpectedAssets == 0) {
            sharesToMint = amount;
        } else {
            // shares = (amount * totalShares) / totalAssets
            sharesToMint = FixedPointMathLib.mulDiv(amount, totalLiquidityShares, totalExpectedAssets);
        }

        liquidityShares[msg.sender] += sharesToMint;
        totalLiquidityShares += sharesToMint;

        bool success = borrowAsset.transferFrom(msg.sender, address(this), amount);
        require(success, "LendingPool: Transfer failed");
        emit DepositLiquidity(msg.sender, amount, sharesToMint);
    }

    function withdrawLiquidity(uint256 shares) external nonReentrant {
        require(shares > 0, "LendingPool: Shares must be > 0");
        updateState();

        uint256 totalActualDebt = FixedPointMathLib.mulDiv(totalDebtShares, borrowIndex, RAY);
        uint256 availableCash = borrowAsset.balanceOf(address(this));
        uint256 totalExpectedAssets = availableCash + totalActualDebt;

        // amount = (shares * totalAssets) / totalShares
        uint256 amountToReturn = FixedPointMathLib.mulDiv(shares, totalExpectedAssets, totalLiquidityShares);

        require(availableCash >= amountToReturn, "LendingPool: Not enough cash in pool");

        liquidityShares[msg.sender] -= shares;
        totalLiquidityShares -= shares;

        bool success = borrowAsset.transfer(msg.sender, amountToReturn);
        require(success, "LendingPool: Transfer failed");
        emit WithdrawLiquidity(msg.sender, shares, amountToReturn);
    }


    /// @notice Borrows the borrowAsset against deposited collateral
    function borrow(uint256 borrowAmount) external nonReentrant {
        if(borrowAmount <=0){
            revert LendingPool__AtleastBorrowSomething();
        }

        updateState();
        // Calculate how many debt shares this borrow represents.
        // We use mulDivUp (rounding up) so the protocol never loses dust to truncation.
        // shares = (borrowAmount * RAY) / borrowIndex
        
        uint256 sharesMinted = FixedPointMathLib.mulDivUp(borrowAmount, RAY, borrowIndex);      
        debtShares[msg.sender] += sharesMinted;
        totalDebtShares += sharesMinted;

        require(calculateHealthFactor(msg.sender) >= WAD, "LendingPool: Undercollateralized");
        bool success = borrowAsset.transfer(msg.sender, borrowAmount);
        require(success, "LendingPool: Transfer failed");
        emit Borrow(msg.sender, borrowAmount, sharesMinted);
    }

    // This is a classic auditor check. In borrow(), you use mulDivUp to calculate shares. If rounding creates a 1-wei discrepancy, it rounds in favor of the protocol (the user owes 1 wei more). In repay(), you use mulDiv (which rounds down), ensuring the user cannot clear an extra share of debt due to a rounding error.

    /// @notice Repays outstanding debt
    function repay(uint256 repayAmount) external nonReentrant {
        require(repayAmount > 0, "LendingPool: Amount must be > 0");
        
        updateState();
        uint256 userShares = debtShares[msg.sender];
        require(userShares > 0, "LendingPool: No debt to repay");

        // Calculate actual current debt
        uint256 userActualDebt = FixedPointMathLib.mulDiv(userShares, borrowIndex, RAY);

        // If user tries to pay back more than they owe, cap it at their exact debt
        if (repayAmount > userActualDebt) {
            repayAmount = userActualDebt;
        }

        // Calculate shares to burn. We round down here so users don't burn extra shares for free.
        uint256 sharesToBurn = FixedPointMathLib.mulDiv(repayAmount, RAY, borrowIndex);

        // If paying off the entire exact debt, burn all shares to avoid dust left behind
        if (repayAmount == userActualDebt) {
            sharesToBurn = userShares;
        }

        debtShares[msg.sender] -= sharesToBurn;
        totalDebtShares -= sharesToBurn;

        bool success = borrowAsset.transferFrom(msg.sender, address(this), repayAmount);
        require(success, "LendingPool: Transfer failed");
        emit Repay(msg.sender, repayAmount, sharesToBurn);
    }

    /// @notice Liquidates an unhealthy position via Uniswap V2
    /// @param borrower The address of the undercollateralized user
    /// @param debtToCover The amount of borrowAsset to repay (must be > 0)
    function liquidate(address borrower, uint256 debtToCover) external nonReentrant {
        require(debtToCover > 0, "LendingPool: Amount must be > 0");
        
        // 1. Accrue global interest first so Health Factor reflects up-to-date debt
        updateState();

        // 2. Check: Is the user actually liquidatable?
        require(calculateHealthFactor(borrower) < WAD, "LendingPool: Borrower is solvent");

        uint256 collateralToSeize;
        {
            uint256 userShares = debtShares[borrower];
            uint256 userActualDebt = FixedPointMathLib.mulDiv(userShares, borrowIndex, RAY);

            // Cap the debt to cover so we don't over-liquidate
            if (debtToCover > userActualDebt) {
                debtToCover = userActualDebt;
            }

            // 3. Calculate Collateral to Seize
            uint256 colPrice = oracle.getPrice(address(collateralAsset));
            uint256 debtPrice = oracle.getPrice(address(borrowAsset));

            uint256 colDecimals = collateralAsset.decimals();
            uint256 debtDecimals = borrowAsset.decimals();

            // How much collateral is strictly equal to the debt value?
            // (debtAmount * debtPrice / 1e18) * (1e18 / colPrice) adjusted for decimals
            uint256 baseCollateralRequired = FixedPointMathLib.mulDiv(
                debtToCover * (10 ** (18 - debtDecimals)),
                debtPrice,
                colPrice
            ) / (10 ** (18 - colDecimals));

            // Apply the protocol liquidation penalty (e.g., base * 1.05)
            collateralToSeize = FixedPointMathLib.mulDiv(baseCollateralRequired, liquidationBonus, WAD);

            require(collateralBalance[borrower] >= collateralToSeize, "LendingPool: Not enough collateral to seize");

            // 4. Update Internal Accounting BEFORE external swap (Checks-Effects-Interactions)
            uint256 sharesToBurn = FixedPointMathLib.mulDiv(debtToCover, RAY, borrowIndex);
            if (debtToCover == userActualDebt) {
                sharesToBurn = userShares;
            }

            debtShares[borrower] -= sharesToBurn;
            totalDebtShares -= sharesToBurn;
            collateralBalance[borrower] -= collateralToSeize;
        }

        // 5. External AMM Interaction
        // Approve Uniswap to spend the seized collateral
        collateralAsset.approve(address(uniswapRouter), collateralToSeize);

        address[] memory path = new address[](2);
        path[0] = address(collateralAsset);
        path[1] = address(borrowAsset);

        // Swap seized collateral for EXACTLY the debtToCover.
        // If the swap requires more collateral than collateralToSeize (due to high slippage), it reverts.
        uint256[] memory amounts = uniswapRouter.swapTokensForExactTokens(
            debtToCover,
            collateralToSeize,
            path,
            address(this),
            block.timestamp
        );

        // 6. Caller Reward & Dust Handling
        // The AMM might not have needed all 'collateralToSeize' to buy the debt.
        uint256 collateralUsed = amounts[0];
        uint256 protocolProfit = collateralToSeize - collateralUsed;

        if (protocolProfit > 0) {
            // Reward the bot that found the liquidation to incentivize network health
            bool success = collateralAsset.transfer(msg.sender, protocolProfit);
            require(success, "LendingPool: Reward transfer failed");
        }

        emit Liquidate(msg.sender, borrower, debtToCover, collateralToSeize, protocolProfit);
    }

}