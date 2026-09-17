// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {Rebalancer} from "../src/Rebalancer.sol";

/**
 * @notice Deploy van Rebalancer op Base mainnet (chain id 8453).
 * @dev Alle adressen zijn on-chain geverifieerd op 11 september 2026 (EURC/USD-feed opnieuw op 15 september
 *      2026). De constructor dwingt af dat beide prijsfeeds 8 decimalen hebben. Uitrollen alleen na akkoord van
 *      Arjan:
 *
 *   BASE_RPC_URL=… TREASURY=0x… \
 *   ~/.foundry/bin/forge script script/Deploy.s.sol --rpc-url base --broadcast --verify --private-key $DEPLOYER_PRIVATE_KEY
 *
 * Zonder --broadcast is dit een droge run.
 */
contract DeployRebalancer is Script {
    address constant EURC = 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SWAP_ROUTER_02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant FEED_CBBTC_USD = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
    /// @dev EURC/USD (DualAggregator, heartbeat 3600 s, deviatie 0,1%) uit Chainlinks referentiedirectory voor
    ///      Base. Op 15 september 2026 via cast geverifieerd: description() "EURC / USD", decimals() 8,
    ///      latestRoundData() ronde van 1.443 s oud. De vorige feed 0xDAe398…8250 heeft een heartbeat van
    ///      24 uur (audit M-2; op 17 september 2026 nog in de directory); het contract eist MAX_AGE_EURC = 4500 s,
    ///      dus die feed zou direct StaleFeed geven.
    address constant FEED_EURC_USD = 0x9867186e52d2F1C2c565CDA6E747101Fa56501e0;
    address constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    /// @dev Uniswap v3 0,05%-pools, alleen gelezen voor de spot-vs-oracle-check.
    address constant POOL_EURC_USDC = 0x7279c08A36333e12c3Fc81747963264c100D66fB;
    address constant POOL_USDC_CBBTC = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;

    function run() external returns (Rebalancer rebalancer) {
        require(block.chainid == 8453, "alleen Base mainnet");
        address treasury = vm.envAddress("TREASURY");

        vm.startBroadcast();
        rebalancer = new Rebalancer(
            Rebalancer.Deployment({
                eurc: EURC,
                cbbtc: CBBTC,
                usdc: USDC,
                router: SWAP_ROUTER_02,
                feedCbbtcUsd: FEED_CBBTC_USD,
                feedEurcUsd: FEED_EURC_USD,
                sequencerFeed: SEQUENCER_FEED,
                poolEurcUsdc: POOL_EURC_USDC,
                poolUsdcCbbtc: POOL_USDC_CBBTC,
                treasury: treasury
            })
        );
        vm.stopBroadcast();

        console.log("Rebalancer:", address(rebalancer));
    }
}
