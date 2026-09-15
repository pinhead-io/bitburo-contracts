// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Rebalancer} from "repo/src/Rebalancer.sol";

/// Meet execute-gas op de Base-fork bij oplopende koopbedragen (tick-crossings) t.o.v. EXECUTE_GAS = 700k.
contract CreForkGas is Test {
    IERC20 constant EURC = IERC20(0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42);
    IERC20 constant CBBTC = IERC20(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
    address constant POOL_EURC_USDC = 0x7279c08A36333e12c3Fc81747963264c100D66fB;
    address constant POOL_USDC_CBBTC = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;
    Rebalancer r = Rebalancer(0xED47d549345b0dBB5A9b44E57Ff3AB4E6Ed0e6e5); // live contract

    function setUp() public { vm.createSelectFork("https://mainnet.base.org"); }

    function _run(uint256 eurcAmount, bool buy) internal {
        uint256 snap = vm.snapshotState();
        address u = makeAddr(string(abi.encodePacked("u", eurcAmount, buy)));
        if (buy) { deal(address(EURC), u, eurcAmount); }
        else { deal(address(CBBTC), u, eurcAmount * 1e8 / r.quote()); }
        vm.startPrank(u);
        EURC.approve(address(r), type(uint256).max);
        CBBTC.approve(address(r), type(uint256).max);
        r.setParams(Rebalancer.Params({active: true, targetBps: buy ? 9500 : 500, bandBps: 100, maxCorrectionBps: 10000, minTradeEurc: 1e6, interval: 1 hours, maxSlippageBps: 100}));
        vm.stopPrank();
        (bool due, int256 delta) = r.isDue(u);
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) = address(r).call{gas: 700_000}(abi.encodeCall(r.execute, (u, address(0xBEEF))));
        uint256 used = g0 - gasleft();
        console.log(buy ? "BUY " : "SELL", "wallet EURC-waarde:", eurcAmount / 1e6);
        console.log("   due:", due);
        console.logInt(delta / 1e6);
        console.log("   ok:", ok, "gas used:", used);
        if (!ok) console.logBytes(ret);
        vm.revertToState(snap);
    }

    function test_gasByTradeSize() public {
        uint256[6] memory sizes = [uint256(500e6), 1_000e6, 2_500e6, 5_000e6, 10_000e6, 20_000e6];
        for (uint256 i = 0; i < sizes.length; i++) { _run(sizes[i], true); _run(sizes[i], false); }
        console.log("pool EURC/USDC: EURC", EURC.balanceOf(POOL_EURC_USDC) / 1e6, "USDC", IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).balanceOf(POOL_EURC_USDC) / 1e6);
    }
}
