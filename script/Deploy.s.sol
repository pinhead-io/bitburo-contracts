// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {Rebalancer} from "../src/Rebalancer.sol";

/**
 * @notice Deployment of Rebalancer on Base mainnet (chain id 8453).
 * @dev All addresses were verified on-chain on 11 September 2026 (EURC/USD feed again on 15 September
 *      2026). The constructor enforces that both price feeds have 8 decimals. Deploy only after approval from
 *      Arjan:
 *
 *   BASE_RPC_URL=… TREASURY=0x… \
 *   ~/.foundry/bin/forge script script/Deploy.s.sol --rpc-url base --broadcast --verify --private-key $DEPLOYER_PRIVATE_KEY
 *
 * Without --broadcast this is a dry run.
 */
contract DeployRebalancer is Script {
    address constant EURC = 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SWAP_ROUTER_02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant FEED_CBBTC_USD = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
    /// @dev EURC/USD (DualAggregator, heartbeat 3600 s, deviation 0.1%) from Chainlink's reference directory for
    ///      Base. Verified via cast on 15 September 2026: description() "EURC / USD", decimals() 8,
    ///      latestRoundData() round 1,443 s old. The previous feed 0xDAe398…8250 has a heartbeat of
    ///      24 hours (audit M-2; still in the directory on 17 September 2026); the contract requires MAX_AGE_EURC =
    ///      4500 s, so that feed would immediately give StaleFeed.
    address constant FEED_EURC_USD = 0x9867186e52d2F1C2c565CDA6E747101Fa56501e0;
    address constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    /// @dev Uniswap v3 0.05% pools, only read for the spot-vs-oracle check.
    address constant POOL_EURC_USDC = 0x7279c08A36333e12c3Fc81747963264c100D66fB;
    address constant POOL_USDC_CBBTC = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;

    function run() external returns (Rebalancer rebalancer) {
        require(block.chainid == 8453, "Base mainnet only");
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
