// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {Rebalancer} from "../src/Rebalancer.sol";

interface IRouterFactory {
    function factory() external view returns (address);
}

interface IFactoryPools {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IFeedDescription {
    function description() external view returns (string memory);
}

/**
 * @notice Deployment of Rebalancer on Base mainnet (chain id 8453).
 * @dev The addresses were verified on chain on 17 September 2026 (`cast call`, block ~51,431,600). The script checks
 *      what the constructor does not: that the router's factory has the USDC/cbBTC 0.05% pool the swaps go through,
 *      and that the feeds are the ones named here. Deploy only after approval from Arjan:
 *
 *   BASE_RPC_URL=… TREASURY=0x… \
 *   ~/.foundry/bin/forge script script/Deploy.s.sol --rpc-url base --broadcast --verify --account <keystore>
 *
 * Without --broadcast this is a dry run.
 */
contract DeployRebalancer is Script {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant SWAP_ROUTER_02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
    /// @dev cbBTC/USD: 8 decimals, heartbeat 20 minutes, deviation 0.3% (Chainlink reference directory for Base).
    address constant FEED_CBBTC_USD = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
    address constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    /// @dev Uniswap v3 USDC/cbBTC 0.05%: the pool `exactInputSingle` with fee 500 resolves to.
    address constant POOL_USDC_CBBTC = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;

    function run() external returns (Rebalancer rebalancer) {
        require(block.chainid == 8453, "Base mainnet only");
        address treasury = vm.envAddress("TREASURY");

        address factory = IRouterFactory(SWAP_ROUTER_02).factory();
        require(IFactoryPools(factory).getPool(USDC, CBBTC, 500) == POOL_USDC_CBBTC, "unexpected USDC/cbBTC pool");
        require(_same(IFeedDescription(FEED_CBBTC_USD).description(), "cbBTC / USD"), "unexpected price feed");
        require(
            _same(IFeedDescription(SEQUENCER_FEED).description(), "L2 Sequencer Uptime Status Feed"),
            "unexpected sequencer feed"
        );

        vm.startBroadcast();
        rebalancer = new Rebalancer(USDC, CBBTC, SWAP_ROUTER_02, FEED_CBBTC_USD, SEQUENCER_FEED, treasury);
        vm.stopBroadcast();

        console.log("Rebalancer:", address(rebalancer));
        console.log("Chainlink price, USDC base units per cbBTC:", rebalancer.quote());
    }

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
