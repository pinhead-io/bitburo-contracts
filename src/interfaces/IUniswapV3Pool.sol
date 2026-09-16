// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Leesaanroepen op een Uniswap v3-pool die de Rebalancer doet, en niets meer. Zelf geschreven voor dit
///         contract (review I-3): alleen de functienamen en de ABI-typen liggen vast, want die bepalen de selector en
///         de decodering. Documentatie van de betekenis: docs.uniswap.org/contracts/v3/reference/core/UniswapV3Pool.
interface IUniswapV3Pool {
    /// @dev Adres van het token met het kleinste adres van het paar.
    function token0() external view returns (address);

    /// @dev Adres van het andere token.
    function token1() external view returns (address);

    /// @dev Swapfee in miljoensten (500 = 0,05%).
    function fee() external view returns (uint24);

    /// @dev Afstand tussen ticks die liquiditeit kunnen dragen (10 bij fee 500).
    function tickSpacing() external view returns (int24);

    /// @dev Huidige stand. `sqrtPriceX96` is √(token1 per token0, in basiseenheden) × 2^96; `observationIndex` wijst
    ///      naar de laatst geschreven oracle-observatie. De overige velden leest de Rebalancer niet.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 cardinality,
            uint16 cardinalityNext,
            uint8 protocolFee,
            bool unlocked
        );

    /// @dev Liquiditeit die op de huidige koers actief is.
    function liquidity() external view returns (uint128);

    /// @dev Gegevens van één tick. De Rebalancer gebruikt alleen `netLiquidity`: wat erbij komt als de koers de tick
    ///      van onder naar boven passeert (en eraf gaat in de andere richting); 0 als de tick niet in gebruik is.
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 grossLiquidity,
            int128 netLiquidity,
            uint256 outsideFeeGrowth0,
            uint256 outsideFeeGrowth1,
            int56 outsideTickCumulative,
            uint160 outsideSecondsPerLiquidity,
            uint32 outsideSeconds,
            bool inUse
        );

    /// @dev Oracle-observatie op `index`. De Rebalancer gebruikt alleen `timestamp`: het blok waarin de pool die
    ///      observatie schreef (hooguit één per blok).
    function observations(uint256 index)
        external
        view
        returns (uint32 timestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulative, bool filled);
}
