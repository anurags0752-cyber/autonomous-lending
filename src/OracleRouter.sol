// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

contract OracleRouter {
    error OracleRouter__FeedDataNotSet();

    event FeedSet(address indexed asset, address indexed feed, uint32 heartbeat);

    struct FeedData {
        address feed;
        uint32 heartbeat;
    }

    mapping(address asset => FeedData dataOfAsset) public feeds;
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    /// @notice Configures a feed with its specific staleness heartbeat
    function setFeed(address asset, address feed, uint32 heartbeat) external {
        require(msg.sender == owner, "OracleRouter: Unauthorized");
        feeds[asset] = FeedData({feed: feed, heartbeat: heartbeat});
        emit FeedSet(asset, feed, heartbeat);
    }

    /// @notice Returns asset price scaled to 1e18 regardless of native feed decimals
    function getPrice(address asset) external view returns(uint256){
        FeedData memory data = feeds[asset];
        if(data.feed == address(0)){
            revert OracleRouter__FeedDataNotSet();
        }
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = AggregatorV3Interface(data.feed).latestRoundData();

        require(answer > 0, "oracleData: invalid price");
        require(block.timestamp - updatedAt <= data.heartbeat, "oracleRouter: stalePrice");
        require(answeredInRound >= roundId, "OracleRouter: staleRound");
        
        uint8 feedDecimals = AggregatorV3Interface(data.feed).decimals();
        
        if(feedDecimals <18){
            return uint256(answer)*(10**(18-feedDecimals));
        } else if(feedDecimals > 18){
            return uint256(answer) / (10**(feedDecimals-18));
        }

        return uint256(answer);
    }


}