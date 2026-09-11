// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IReceiver} from "./interfaces/IReceiver.sol";
import {IV3SwapRouter} from "./interfaces/IV3SwapRouter.sol";

/**
 * @title Rebalancer
 * @notice Eén onveranderbaar contract dat, met een ERC-20-mandaat (allowance) van de gebruiker, diens wallet
 *         rebalancet tussen EURC en cbBTC naar een door de gebruiker gekozen verdeling. Het geld blijft in de
 *         wallet van de gebruiker; het contract houdt buiten een transactie nooit saldo.
 *
 * @dev De rekenregel is één op één AutoTradeStrategy::rebalanceAmount uit de Bitburo-app:
 *      fraction = position / total; drift = fraction - target; |drift| <= band -> niets;
 *      correction = |drift| * total; cap = max(total * maxCorrection, minTrade); correction = min(correction, cap);
 *      correction < minTrade -> niets. Drift < 0 -> kopen (EURC -> cbBTC), anders verkopen.
 *
 *      Geen admin, geen upgrade, geen pauzeknop. `execute` is permissionless; de aanroeper kan alleen kiezen
 *      wanneer, nooit wat of hoeveel. De fee is vast en gaat altijd in EURC naar de treasury, met een vaste
 *      beloning voor de aanroeper.
 */
contract Rebalancer is IReceiver, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ─── Vaste parameters ───────────────────────────────────────────────────────────────────────────────────

    IERC20 public immutable EURC; // 6 decimalen
    IERC20 public immutable CBBTC; // 8 decimalen
    address public immutable USDC; // alleen als tussenhop in het Uniswap-pad
    IV3SwapRouter public immutable ROUTER; // Uniswap SwapRouter02
    IAggregatorV3 public immutable FEED_CBBTC_USD; // 8 decimalen
    IAggregatorV3 public immutable FEED_EURC_USD; // 8 decimalen
    IAggregatorV3 public immutable SEQUENCER_FEED; // L2 Sequencer Uptime, answer 0 = up
    address public immutable TREASURY;
    /// @notice KeystoneForwarder van Chainlink CRE op deze chain.
    address public immutable FORWARDER;
    /// @notice Adres van de CRE-workflow-eigenaar (de sleutel die de Bitburo-workflow uitrolt).
    address public immutable WORKFLOW_OWNER;

    uint24 public constant POOL_FEE = 500; // 0,05% op beide hops
    uint16 public constant FEE_BPS = 25;
    uint256 public constant KEEPER_REWARD_EURC = 50_000; // 0,05 EURC
    uint16 public constant MAX_SLIPPAGE_BPS = 300;
    uint16 public constant MIN_TARGET_BPS = 500;
    uint16 public constant MAX_TARGET_BPS = 9500;
    uint32 public constant MIN_INTERVAL = 1 hours;
    uint256 public constant GRACE_PERIOD = 1 hours;
    uint256 public constant MAX_AGE_CBBTC = 1200 + 300; // heartbeat 20 min + marge
    uint256 public constant MAX_AGE_EURC = 86_400 + 3600; // heartbeat 24 u + marge
    uint256 public constant BPS = 10_000;
    uint256 private constant WAD = 1e18;
    uint256 private constant EURC_UNIT = 1e6;
    uint256 private constant CBBTC_UNIT = 1e8;

    // ─── Per gebruiker ──────────────────────────────────────────────────────────────────────────────────────

    struct Params {
        bool active;
        uint16 targetBps; // cbBTC-aandeel, 500–9500, veelvoud van 100
        uint16 bandBps; // > 0
        uint16 maxCorrectionBps; // 1–10000, aandeel van de totale waarde per run
        uint64 minTradeEurc; // EURC-basiseenheden
        uint32 interval; // minimale tijd tussen runs, >= MIN_INTERVAL
        uint16 maxSlippageBps; // 1–MAX_SLIPPAGE_BPS
    }

    mapping(address owner => Params) public params;
    mapping(address owner => uint64) public lastExecutedAt;
    address[] private _owners;
    mapping(address owner => bool) private _isRegistered;

    // ─── Events en errors ───────────────────────────────────────────────────────────────────────────────────

    event ParamsUpdated(address indexed owner, Params params);
    event Executed(
        address indexed owner,
        bool isBuy,
        uint256 amountIn,
        uint256 fee,
        uint256 reward,
        address rewardTo,
        uint256 amountOut,
        uint256 priceEurcPerBtc,
        uint256 totalValueEurc,
        uint256 fractionBps
    );
    event ReportSkipped(address indexed owner, bytes reason);

    error InvalidParams();
    error Inactive();
    error NotDue();
    error SequencerDown();
    error StaleFeed(address feed);
    error InvalidFeedAnswer(address feed);
    error NothingToDo();
    error UnauthorizedForwarder(address caller);
    error UnauthorizedWorkflowOwner(address owner);
    error ZeroAddress();

    // ─── Constructor ────────────────────────────────────────────────────────────────────────────────────────

    struct Deployment {
        address eurc;
        address cbbtc;
        address usdc;
        address router;
        address feedCbbtcUsd;
        address feedEurcUsd;
        address sequencerFeed;
        address treasury;
        address forwarder;
        address workflowOwner;
    }

    constructor(Deployment memory d) {
        if (
            d.eurc == address(0) || d.cbbtc == address(0) || d.usdc == address(0) || d.router == address(0)
                || d.feedCbbtcUsd == address(0) || d.feedEurcUsd == address(0) || d.sequencerFeed == address(0)
                || d.treasury == address(0) || d.forwarder == address(0) || d.workflowOwner == address(0)
        ) {
            revert ZeroAddress();
        }
        EURC = IERC20(d.eurc);
        CBBTC = IERC20(d.cbbtc);
        USDC = d.usdc;
        ROUTER = IV3SwapRouter(d.router);
        FEED_CBBTC_USD = IAggregatorV3(d.feedCbbtcUsd);
        FEED_EURC_USD = IAggregatorV3(d.feedEurcUsd);
        SEQUENCER_FEED = IAggregatorV3(d.sequencerFeed);
        TREASURY = d.treasury;
        FORWARDER = d.forwarder;
        WORKFLOW_OWNER = d.workflowOwner;
    }

    // ─── Gebruiker ──────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Zet of wijzigt de eigen instellingen. Alleen msg.sender kan zijn eigen instellingen wijzigen.
    function setParams(Params calldata p) external {
        if (
            p.targetBps < MIN_TARGET_BPS || p.targetBps > MAX_TARGET_BPS || p.targetBps % 100 != 0 || p.bandBps == 0
                || p.bandBps >= BPS || p.maxCorrectionBps == 0 || p.maxCorrectionBps > BPS || p.minTradeEurc == 0
                || p.interval < MIN_INTERVAL || p.maxSlippageBps == 0 || p.maxSlippageBps > MAX_SLIPPAGE_BPS
        ) {
            revert InvalidParams();
        }
        params[msg.sender] = p;
        if (!_isRegistered[msg.sender]) {
            _isRegistered[msg.sender] = true;
            _owners.push(msg.sender);
        }
        emit ParamsUpdated(msg.sender, p);
    }

    // ─── Lezen ──────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Pagina uit de lijst van adressen die ooit instellingen hebben gezet (ook inactieve).
    function owners(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 total = _owners.length;
        if (offset >= total) {
            return new address[](0);
        }
        uint256 end = Math.min(offset + limit, total);
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _owners[i];
        }
    }

    function ownerCount() external view returns (uint256) {
        return _owners.length;
    }

    /// @notice Zou `execute(owner, …)` nu iets doen? `eurcDelta` > 0 = kopen voor dat bedrag, < 0 = verkopen.
    /// @dev Revert nooit: een storing in de feeds of sequencer geeft (false, 0).
    function isDue(address owner) external view returns (bool due, int256 eurcDelta) {
        Params memory p = params[owner];
        if (!p.active || block.timestamp < uint256(lastExecutedAt[owner]) + p.interval) {
            return (false, 0);
        }
        (bool ok, uint256 price) = _tryQuote();
        if (!ok) {
            return (false, 0);
        }
        (bool isBuy, uint256 amountIn, uint256 correctionEurc,,) = _plan(owner, p, price);
        if (amountIn == 0) {
            return (false, 0);
        }
        eurcDelta = isBuy ? int256(correctionEurc) : -int256(correctionEurc);
        return (true, eurcDelta);
    }

    // ─── Uitvoeren ──────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Voert één rebalance-stap uit voor `owner`. Iedereen mag dit aanroepen.
    /// @param rewardTo Ontvanger van de beloning uit de fee; address(0) = hele fee naar de treasury.
    function execute(address owner, address rewardTo) external nonReentrant {
        Params memory p = params[owner];
        if (!p.active) revert Inactive();
        if (block.timestamp < uint256(lastExecutedAt[owner]) + p.interval) revert NotDue();

        uint256 price = _quote();
        (bool isBuy, uint256 amountIn, uint256 correctionEurc, uint256 total, uint256 fractionBps) =
            _plan(owner, p, price);
        if (amountIn == 0) revert NothingToDo();

        // Vanaf hier wordt de run geboekt, ook al zou de swap nog reverten (dan revert alles).
        lastExecutedAt[owner] = uint64(block.timestamp);

        uint256 fee;
        uint256 reward;
        uint256 amountOut;
        if (isBuy) {
            (fee, reward, amountOut) = _buy(owner, p, amountIn, price, rewardTo);
        } else {
            (fee, reward, amountOut) = _sell(owner, p, amountIn, price, rewardTo);
        }

        emit Executed(owner, isBuy, amountIn, fee, reward, rewardTo, amountOut, price, total, fractionBps);
        correctionEurc; // alleen voor isDue relevant
    }

    /// @notice Ingang voor Chainlink CRE: `report` = abi.encode(address[] owners). Per owner try/catch.
    function onReport(bytes calldata metadata, bytes calldata report) external override {
        if (msg.sender != FORWARDER) revert UnauthorizedForwarder(msg.sender);
        (,, address workflowOwner) = _decodeMetadata(metadata);
        if (workflowOwner != WORKFLOW_OWNER) revert UnauthorizedWorkflowOwner(workflowOwner);

        address[] memory list = abi.decode(report, (address[]));
        for (uint256 i = 0; i < list.length; i++) {
            try this.execute(list[i], TREASURY) {}
            catch (bytes memory reason) {
                emit ReportSkipped(list[i], reason);
            }
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ─── Intern: koers ──────────────────────────────────────────────────────────────────────────────────────

    /// @return price EURC-basiseenheden (6 dec) per 1 cbBTC.
    function _quote() internal view returns (uint256 price) {
        (, int256 seqAnswer, uint256 seqStartedAt,,) = SEQUENCER_FEED.latestRoundData();
        if (seqAnswer != 0 || block.timestamp - seqStartedAt < GRACE_PERIOD) revert SequencerDown();

        uint256 cbbtcUsd = _readFeed(FEED_CBBTC_USD, MAX_AGE_CBBTC);
        uint256 eurcUsd = _readFeed(FEED_EURC_USD, MAX_AGE_EURC);
        price = Math.mulDiv(cbbtcUsd, EURC_UNIT, eurcUsd);
    }

    function _readFeed(IAggregatorV3 feed, uint256 maxAge) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidFeedAnswer(address(feed));
        // Een updatedAt in de toekomst is net zo onbruikbaar als een te oude; beide geven StaleFeed, geen Panic.
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) revert StaleFeed(address(feed));
        // answer > 0 is hierboven afgedwongen, dus de cast kan niet afkappen.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(answer);
    }

    function _tryQuote() internal view returns (bool ok, uint256 price) {
        try this.quote() returns (uint256 p) {
            return (true, p);
        } catch {
            return (false, 0);
        }
    }

    /// @notice Actuele koers volgens de feeds, met dezelfde checks als `execute`. Revert bij storing.
    function quote() external view returns (uint256) {
        return _quote();
    }

    // ─── Intern: rekenregel ─────────────────────────────────────────────────────────────────────────────────

    /**
     * @return isBuy          Richting.
     * @return amountIn       Input-bedrag in het input-token (EURC bij kopen, cbBTC bij verkopen), al begrensd
     *                        op saldo en allowance. 0 = niets doen.
     * @return correctionEurc De gewenste correctie in EURC vóór begrenzing op saldo/allowance.
     * @return total          Totale waarde in EURC.
     * @return fractionBps    Huidig cbBTC-aandeel in bps.
     */
    function _plan(address owner, Params memory p, uint256 price)
        internal
        view
        returns (bool isBuy, uint256 amountIn, uint256 correctionEurc, uint256 total, uint256 fractionBps)
    {
        uint256 cash = EURC.balanceOf(owner);
        uint256 btcBal = CBBTC.balanceOf(owner);
        uint256 position = Math.mulDiv(btcBal, price, CBBTC_UNIT);
        total = cash + position;
        if (total == 0) {
            return (false, 0, 0, 0, 0);
        }

        uint256 fractionWad = Math.mulDiv(position, WAD, total);
        uint256 targetWad = uint256(p.targetBps) * WAD / BPS;
        uint256 bandWad = uint256(p.bandBps) * WAD / BPS;
        fractionBps = fractionWad * BPS / WAD;

        isBuy = fractionWad < targetWad;
        uint256 driftWad = isBuy ? targetWad - fractionWad : fractionWad - targetWad;
        if (driftWad <= bandWad) {
            return (isBuy, 0, 0, total, fractionBps);
        }

        correctionEurc = Math.mulDiv(driftWad, total, WAD);
        uint256 cap = Math.mulDiv(total, p.maxCorrectionBps, BPS);
        if (cap < p.minTradeEurc) cap = p.minTradeEurc;
        if (correctionEurc > cap) correctionEurc = cap;
        if (correctionEurc < p.minTradeEurc) {
            return (isBuy, 0, correctionEurc, total, fractionBps);
        }

        // De begrenzing op het saldo is defensief: correction <= |drift| * total <= saldo van het input-token,
        // dus in de praktijk begrenst alleen de allowance. Blijft staan als vangnet bij latere wijzigingen.
        if (isBuy) {
            amountIn = Math.min(correctionEurc, Math.min(cash, EURC.allowance(owner, address(this))));
            if (amountIn < p.minTradeEurc) amountIn = 0;
        } else {
            uint256 wantBtc = Math.mulDiv(correctionEurc, CBBTC_UNIT, price);
            amountIn = Math.min(wantBtc, Math.min(btcBal, CBBTC.allowance(owner, address(this))));
            if (Math.mulDiv(amountIn, price, CBBTC_UNIT) < p.minTradeEurc) amountIn = 0;
        }
    }

    // ─── Intern: swaps ──────────────────────────────────────────────────────────────────────────────────────

    function _buy(address owner, Params memory p, uint256 amountIn, uint256 price, address rewardTo)
        internal
        returns (uint256 fee, uint256 reward, uint256 amountOut)
    {
        EURC.safeTransferFrom(owner, address(this), amountIn);
        (fee, reward) = _takeFee(amountIn, rewardTo);
        uint256 swapIn = amountIn - fee;

        uint256 expectedOut = Math.mulDiv(swapIn, CBBTC_UNIT, price);
        uint256 minOut = Math.mulDiv(expectedOut, BPS - p.maxSlippageBps, BPS);

        EURC.forceApprove(address(ROUTER), swapIn);
        amountOut = ROUTER.exactInput(
            IV3SwapRouter.ExactInputParams({
                path: abi.encodePacked(address(EURC), POOL_FEE, USDC, POOL_FEE, address(CBBTC)),
                recipient: owner,
                amountIn: swapIn,
                amountOutMinimum: minOut
            })
        );
    }

    function _sell(address owner, Params memory p, uint256 amountIn, uint256 price, address rewardTo)
        internal
        returns (uint256 fee, uint256 reward, uint256 amountOut)
    {
        CBBTC.safeTransferFrom(owner, address(this), amountIn);

        uint256 expectedOut = Math.mulDiv(amountIn, price, CBBTC_UNIT);
        uint256 minOut = Math.mulDiv(expectedOut, BPS - p.maxSlippageBps, BPS);

        CBBTC.forceApprove(address(ROUTER), amountIn);
        uint256 eurcBefore = EURC.balanceOf(address(this));
        ROUTER.exactInput(
            IV3SwapRouter.ExactInputParams({
                path: abi.encodePacked(address(CBBTC), POOL_FEE, USDC, POOL_FEE, address(EURC)),
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        );
        uint256 received = EURC.balanceOf(address(this)) - eurcBefore;

        (fee, reward) = _takeFee(received, rewardTo);
        amountOut = received - fee;
        EURC.safeTransfer(owner, amountOut);
    }

    /// @dev Fee in EURC over `eurcAmount`; beloning eruit naar rewardTo, rest naar de treasury.
    function _takeFee(uint256 eurcAmount, address rewardTo) internal returns (uint256 fee, uint256 reward) {
        fee = Math.mulDiv(eurcAmount, FEE_BPS, BPS);
        if (rewardTo != address(0)) {
            reward = Math.min(KEEPER_REWARD_EURC, fee);
            if (reward > 0) EURC.safeTransfer(rewardTo, reward);
        }
        if (fee - reward > 0) EURC.safeTransfer(TREASURY, fee - reward);
    }

    // ─── Intern: CRE-metadata ───────────────────────────────────────────────────────────────────────────────

    /// @dev Layout: bytes32 workflowId | bytes10 workflowName | address workflowOwner | bytes2 reportId.
    function _decodeMetadata(bytes calldata metadata)
        internal
        pure
        returns (bytes32 workflowId, bytes10 workflowName, address workflowOwner)
    {
        workflowId = bytes32(metadata[0:32]);
        workflowName = bytes10(metadata[32:42]);
        workflowOwner = address(bytes20(metadata[42:62]));
    }
}
