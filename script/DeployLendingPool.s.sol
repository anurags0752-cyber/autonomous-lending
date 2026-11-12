// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LendingPool, IUniswapV2Router02} from "../src/LendingPool.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {OracleRouter} from "../src/OracleRouter.sol";

contract DeployLendingPool is Script {
    // Default Risk & Rate Parameters
    uint256 public constant OPTIMAL_USAGE_RATIO = 0.8e27; // 80% optimal utilization
    uint256 public constant BASE_BORROW_RATE = 0.02e27; // 2% base APR
    uint256 public constant MAX_BASE_YIELD = 0.04e27; // +4% APR at kink
    uint256 public constant MAX_PENALTY_YIELD = 0.75e27; // +75% APR at 100% utilization

    uint256 public constant LIQUIDATION_THRESHOLD = 0.8e18; // 80% LTV liquidation threshold
    uint256 public constant LIQUIDATION_BONUS = 1.05e18; // 5% liquidator bonus
    uint32 public constant DEFAULT_HEARTBEAT = 86400; // 24 hours

    function run()
        external
        returns (LendingPool pool, InterestRateModel rateModel, OracleRouter oracleRouter)
    {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address collateralAsset = vm.envAddress("WETH_ADDRESS");
        address borrowAsset = vm.envAddress("USDC_ADDRESS");
        address wethUsdFeed = vm.envAddress("WETH_USD_FEED");
        address usdcUsdFeed = vm.envAddress("USDC_USD_FEED");
        address uniswapRouter = vm.envAddress("UNISWAP_V2_ROUTER");
        uint32 heartbeat = uint32(vm.envOr("ORACLE_HEARTBEAT", uint256(DEFAULT_HEARTBEAT)));

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Kinked Interest Rate Model
        rateModel = new InterestRateModel(
            OPTIMAL_USAGE_RATIO,
            BASE_BORROW_RATE,
            MAX_BASE_YIELD,
            MAX_PENALTY_YIELD
        );

        // 2. Deploy Oracle Router & Register Chainlink Price Feeds
        oracleRouter = new OracleRouter();
        oracleRouter.setFeed(collateralAsset, wethUsdFeed, heartbeat);
        oracleRouter.setFeed(borrowAsset, usdcUsdFeed, heartbeat);

        // 3. Deploy Core LendingPool
        pool = new LendingPool(
            collateralAsset,
            borrowAsset,
            address(rateModel),
            address(oracleRouter),
            LIQUIDATION_THRESHOLD,
            IUniswapV2Router02(uniswapRouter),
            LIQUIDATION_BONUS
        );

        vm.stopBroadcast();

        console.log("InterestRateModel deployed at:", address(rateModel));
        console.log("OracleRouter deployed at:     ", address(oracleRouter));
        console.log("LendingPool deployed at:      ", address(pool));
    }
}
