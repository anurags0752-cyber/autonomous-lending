// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "../../src/OracleRouter.sol";

contract MockV3Aggregator is AggregatorV3Interface {

    uint8 public immutable decimals;
    int256 public latestAnswer;
    uint256 public latestTimestamp;
    uint80 public latestRound;

    constructor(uint8 _decimals, int256 _initialAnswer){
        decimals = _decimals;
        updateAnswer(_initialAnswer);
    }

    function updateAnswer(int256 _answer) public {
        latestAnswer = _answer;
        latestTimestamp = block.timestamp;
        latestRound++;
    }

    function latestRoundData() external view returns(uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound){  

        return (latestRound, latestAnswer, latestTimestamp, latestTimestamp, latestRound);

    }


}