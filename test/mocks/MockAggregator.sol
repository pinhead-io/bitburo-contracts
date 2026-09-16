// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Chainlink-feed met instelbare answer/startedAt/updatedAt.
contract MockAggregator is IAggregatorV3 {
    uint8 private immutable _decimals;
    string private _description;
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;

    constructor(uint8 decimals_, string memory description_) {
        _decimals = decimals_;
        _description = description_;
    }

    function set(int256 answer_, uint256 startedAt_, uint256 updatedAt_) external {
        roundId++;
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, roundId);
    }
}
