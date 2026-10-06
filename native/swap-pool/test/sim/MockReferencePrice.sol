// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @title MockReferencePrice — TEST-ONLY, NOT A FEED, NOT AN ORACLE
/// @notice A deterministic, seeded random walk used as the exogenous
///         "outside market" price in the C0 pool simulation. It is never read
///         by SwapPool (ordinary swaps have no oracle dependency) and must
///         never be deployed, cited as a live market, or presented as a
///         DBLN/USD or any other real price (PLAN G8). It can be "withheld"
///         to model a reporter outage: reads then return the last published
///         value flagged stale, while the hidden true path keeps moving.
contract MockReferencePrice {
    uint256 public constant ONE = 1e18;

    bytes32 public immutable seed;
    uint256 public immutable stepBps; // per-step move, e.g. 100 = 1%

    uint256 public truePrice; // token1 per token0, 1e18 fixed point
    uint256 public publishedPrice;
    uint256 public step;
    uint256 public publishedStep;
    bool public withheld;

    constructor(bytes32 seed_, uint256 startPrice, uint256 stepBps_) {
        seed = seed_;
        stepBps = stepBps_;
        truePrice = startPrice;
        publishedPrice = startPrice;
    }

    /// @notice Advance the hidden path one step (+/- stepBps, seeded).
    function advance() external returns (uint256) {
        bool up = uint256(keccak256(abi.encode(seed, step))) & 1 == 1;
        truePrice = up ? truePrice * (10_000 + stepBps) / 10_000 : truePrice * (10_000 - stepBps) / 10_000;
        step++;
        if (!withheld) {
            publishedPrice = truePrice;
            publishedStep = step;
        }
        return truePrice;
    }

    function setWithheld(bool w) external {
        withheld = w;
        if (!w) {
            publishedPrice = truePrice;
            publishedStep = step;
        }
    }

    /// @return price last published value
    /// @return age steps since it was published
    /// @return stale true while reports are withheld
    function read() external view returns (uint256 price, uint256 age, bool stale) {
        return (publishedPrice, step - publishedStep, withheld);
    }
}
