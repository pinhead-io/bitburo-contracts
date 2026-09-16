// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
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
 *      beloning voor de aanroeper. De enige bevoegdheid van de treasury is `retire`: een eenmalige,
 *      onomkeerbare uitschakelaar die het contract definitief stopt (zie daar). Die kan niets met fondsen.
 *
 *      Sandwich-bescherming: vóór én na elke swap wordt de spotkoers van de twee Uniswap-pools (EURC/USDC en
 *      USDC/cbBTC, via slot0) vergeleken met de Chainlink-koers. Wijkt de spot op een van beide momenten meer
 *      dan MAX_SPOT_DEVIATION_BPS af, dan revert de run. De check vooraf begrenst hoe ver een aanroeper de pool
 *      kan voorschuiven; de check achteraf dwingt af dat voorschuiving plus de eigen prijsimpact van de run
 *      samen binnen die 0,5% blijven, wat de winstruimte van een atomaire zelf-sandwich grotendeels sluit.
 *      Het maximale verlies per run ten opzichte van de Chainlink-koers is FEE_BPS + maxSlippageBps
 *      (0,85% tot 1,25%); de spot-check is daar geen extra bovengrens op. De EURC/USDC-pool is dun;
 *      runs boven ongeveer 8.000 EURC per keer reverten vaker zolang de route Uniswap v3 is, omdat de eigen
 *      prijsimpact dan zelf al richting de toegestane afwijking gaat.
 *
 *      Beschikbaarheid: de fee-transfer naar de treasury en de beloning worden met een niet-reverterende
 *      transfer gedaan. Faalt de treasury-transfer (bijvoorbeeld een Circle-blacklist), dan blijft de fee in
 *      het contract (FeeRetained) en kan `sweep` die later alsnog ophalen; de rebalance zelf loopt nooit stuk
 *      op de fee-ontvanger.
 */
contract Rebalancer is ReentrancyGuardTransient {
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
    /// @notice Uniswap v3-pool EURC/USDC (0,05%), alleen gelezen voor de spot-vs-oracle-check. De constructor dwingt
    ///         af dat dit de POOL_FEE-pool van de factory van ROUTER is, dus de pool waar de swap doorheen gaat.
    IUniswapV3Pool public immutable POOL_EURC_USDC;
    /// @notice Uniswap v3-pool USDC/cbBTC (0,05%), alleen gelezen voor de spot-vs-oracle-check. Zelfde constructorcheck.
    IUniswapV3Pool public immutable POOL_USDC_CBBTC;
    bool private immutable _eurcIsToken0;
    bool private immutable _usdcIsToken0;

    uint24 public constant POOL_FEE = 500; // 0,05% op beide hops
    uint16 public constant FEE_BPS = 25;
    uint256 public constant KEEPER_REWARD_EURC = 50_000; // 0,05 EURC
    uint16 public constant MAX_SLIPPAGE_BPS = 100;
    /// @notice Ondergrens voor `maxSlippageBps`: MAX_SPOT_DEVIATION_BPS + 2 × 5 bps poolfee. `amountOutMinimum`
    ///         wordt van de oracle afgeleid, terwijl de swap tegen de pool-spot loopt; die mag 0,5% afwijken en
    ///         kost 0,1% aan poolfees. Onder 60 bps zou een run die de spot-check haalt structureel op
    ///         "Too little received" kunnen reverten.
    uint16 public constant MIN_SLIPPAGE_BPS = 60;
    uint16 public constant MAX_SPOT_DEVIATION_BPS = 50;
    /// @notice Ondergrens voor `minTradeEurc` (20 EURC). Bij FEE_BPS = 25 is de fee van de kleinste run dan
    ///         precies KEEPER_REWARD_EURC, zodat elke run de volledige keeperbeloning dekt en een dust-owner
    ///         de wekkers niet gratis bezig kan houden. Dat geldt voor kopen én verkopen: bij een koop is de
    ///         fee-grondslag het bruto inputbedrag, bij een verkoop max(ontvangen, verwachte opbrengst), waarbij
    ///         de verwachte opbrengst dezelfde oraclewaarde is waarop de ondergrens is gecontroleerd (audit L-B). Bovendien is `expectedOut` bij een koop dan ≥ ~25.000
    ///         sats bij 80.000 EURC/cbBTC, waardoor de afronding in `amountOutMinimum` onder 1 bp blijft.
    uint64 public constant MIN_TRADE_FLOOR = 20e6;
    /// @notice Ondergrens voor `maxCorrectionBps` (0,1% per run): sluit configuraties uit die elk interval een
    ///         verwaarloosbare correctie doen en daarmee eeuwig due blijven.
    uint16 public constant MIN_CORRECTION_BPS = 10;
    uint16 public constant MIN_TARGET_BPS = 500;
    uint16 public constant MAX_TARGET_BPS = 9500;
    uint32 public constant MIN_INTERVAL = 1 hours;
    uint256 public constant GRACE_PERIOD = 1 hours;
    /// @notice Beide feeds moeten dit aantal decimalen hebben; de omrekening in `_quote` deelt ze op elkaar.
    uint8 public constant FEED_DECIMALS = 8;
    uint256 public constant MAX_AGE_CBBTC = 1200 + 300; // heartbeat 20 min + marge
    /// @notice EURC/USD-feed 0x9867…01e0 op Base: heartbeat 1 uur, deviatie 0,1%; zelfde 25% marge als cbBTC.
    uint256 public constant MAX_AGE_EURC = 3600 + 900;
    uint256 public constant BPS = 10_000;
    uint256 private constant WAD = 1e18;
    uint256 private constant EURC_UNIT = 1e6;
    uint256 private constant CBBTC_UNIT = 1e8;
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant Q128 = 1 << 128;

    // ─── Per gebruiker ──────────────────────────────────────────────────────────────────────────────────────

    struct Params {
        bool active;
        uint16 targetBps; // cbBTC-aandeel, 500–9500, veelvoud van 100
        uint16 bandBps; // > 0
        uint16 maxCorrectionBps; // MIN_CORRECTION_BPS–10000, aandeel van de totale waarde per run
        uint64 minTradeEurc; // EURC-basiseenheden, >= MIN_TRADE_FLOOR
        uint32 interval; // minimale tijd tussen runs, >= MIN_INTERVAL
        uint16 maxSlippageBps; // MIN_SLIPPAGE_BPS–MAX_SLIPPAGE_BPS
    }

    mapping(address owner => Params) public params;
    mapping(address owner => uint64) public lastExecutedAt;
    address[] private _owners;
    mapping(address owner => bool) private _isRegistered;
    /// @notice True zodra de treasury `retire` heeft aangeroepen. Onomkeerbaar: daarna doet `execute` niets meer,
    ///         geven `isDue`/`dueOwners` niets terug en kan `setParams` alleen nog een mandaat intrekken
    ///         (`active = false`). `sweep` blijft werken.
    bool public retired;

    // ─── Events en errors ───────────────────────────────────────────────────────────────────────────────────

    event ParamsUpdated(address indexed owner, Params params);
    /// @notice Het contract is definitief buiten gebruik gesteld door de treasury.
    event Retired();
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
    /// @notice De fee-transfer naar de treasury faalde; `amount` EURC blijft in het contract en is sweep-baar.
    event FeeRetained(uint256 amount);

    error InvalidParams();
    error Inactive();
    error NotDue();
    error SequencerDown();
    error StaleFeed(address feed);
    error InvalidFeedAnswer(address feed);
    error NothingToDo();
    error ZeroAddress();
    error NotAContract(address account);
    error UnexpectedPoolTokens(address pool);
    /// @notice De pool heeft niet de fee-tier POOL_FEE waar de swap doorheen gaat.
    error UnexpectedPoolFee(address pool);
    /// @notice De pool is niet de POOL_FEE-pool van de factory van de router, dus niet de pool van de swap.
    error PoolNotFromRouterFactory(address pool);
    error SpotDeviatesFromOracle(uint256 spot, uint256 oracle);
    error UnexpectedFeedDecimals(address feed);
    error NoOutput();
    /// @notice Het contract is buiten gebruik gesteld; alleen `setParams` met `active = false` en `sweep` kunnen nog.
    error ContractRetired();
    error AlreadyRetired();
    error NotTreasury(address caller);

    // ─── Constructor ────────────────────────────────────────────────────────────────────────────────────────

    struct Deployment {
        address eurc;
        address cbbtc;
        address usdc;
        address router;
        address feedCbbtcUsd;
        address feedEurcUsd;
        address sequencerFeed;
        address poolEurcUsdc;
        address poolUsdcCbbtc;
        address treasury;
    }

    constructor(Deployment memory d) {
        if (d.treasury == address(0)) revert ZeroAddress();
        _requireContract(d.eurc);
        _requireContract(d.cbbtc);
        _requireContract(d.usdc);
        _requireContract(d.router);
        _requireContract(d.feedCbbtcUsd);
        _requireContract(d.feedEurcUsd);
        _requireContract(d.sequencerFeed);
        _requireContract(d.poolEurcUsdc);
        _requireContract(d.poolUsdcCbbtc);

        EURC = IERC20(d.eurc);
        CBBTC = IERC20(d.cbbtc);
        USDC = d.usdc;
        ROUTER = IV3SwapRouter(d.router);
        FEED_CBBTC_USD = IAggregatorV3(d.feedCbbtcUsd);
        FEED_EURC_USD = IAggregatorV3(d.feedEurcUsd);
        SEQUENCER_FEED = IAggregatorV3(d.sequencerFeed);
        POOL_EURC_USDC = IUniswapV3Pool(d.poolEurcUsdc);
        POOL_USDC_CBBTC = IUniswapV3Pool(d.poolUsdcCbbtc);
        TREASURY = d.treasury;

        _eurcIsToken0 = _poolOrder(POOL_EURC_USDC, d.eurc, d.usdc);
        _usdcIsToken0 = _poolOrder(POOL_USDC_CBBTC, d.usdc, d.cbbtc);
        // De spotcheck moet de pools bewaken waar de swap werkelijk doorheen gaat (audit lead 1): de POOL_FEE-pools
        // van dezelfde factory als de router.
        address factory = ROUTER.factory();
        _requireContract(factory);
        _requireSwapPool(IUniswapV3Factory(factory), POOL_EURC_USDC, d.eurc, d.usdc);
        _requireSwapPool(IUniswapV3Factory(factory), POOL_USDC_CBBTC, d.usdc, d.cbbtc);

        // `_quote` deelt de twee feeds op elkaar; dat klopt alleen als beide dezelfde decimalen hebben.
        if (FEED_CBBTC_USD.decimals() != FEED_DECIMALS) revert UnexpectedFeedDecimals(d.feedCbbtcUsd);
        if (FEED_EURC_USD.decimals() != FEED_DECIMALS) revert UnexpectedFeedDecimals(d.feedEurcUsd);
    }

    function _requireContract(address account) private view {
        if (account == address(0)) revert ZeroAddress();
        if (account.code.length == 0) revert NotAContract(account);
    }

    /// @return aIsToken0 True als `a` token0 van de pool is; revert als de pool niet precies {a, b} bevat.
    function _poolOrder(IUniswapV3Pool pool, address a, address b) private view returns (bool aIsToken0) {
        address token0 = pool.token0();
        address token1 = pool.token1();
        if (token0 == a && token1 == b) return true;
        if (token0 == b && token1 == a) return false;
        revert UnexpectedPoolTokens(address(pool));
    }

    /// @dev Revert als `pool` niet de POOL_FEE-pool van {a, b} uit `factory` is.
    function _requireSwapPool(IUniswapV3Factory factory, IUniswapV3Pool pool, address a, address b) private view {
        if (pool.fee() != POOL_FEE) revert UnexpectedPoolFee(address(pool));
        if (factory.getPool(a, b, POOL_FEE) != address(pool)) revert PoolNotFromRouterFactory(address(pool));
    }

    // ─── Gebruiker ──────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Zet of wijzigt de eigen instellingen. Alleen msg.sender kan zijn eigen instellingen wijzigen.
    /// @dev Economische ondergrenzen: `minTradeEurc >= MIN_TRADE_FLOOR` en `maxCorrectionBps >= MIN_CORRECTION_BPS`.
    ///      Na `retire` is alleen `active = false` nog toegestaan (mandaat intrekken); een actief mandaat zetten
    ///      revert dan met `ContractRetired`.
    function setParams(Params calldata p) external {
        if (retired && p.active) revert ContractRetired();
        if (
            p.targetBps < MIN_TARGET_BPS || p.targetBps > MAX_TARGET_BPS || p.targetBps % 100 != 0 || p.bandBps == 0
                || p.bandBps >= BPS || p.maxCorrectionBps < MIN_CORRECTION_BPS || p.maxCorrectionBps > BPS
                || p.minTradeEurc < MIN_TRADE_FLOOR || p.interval < MIN_INTERVAL || p.maxSlippageBps < MIN_SLIPPAGE_BPS
                || p.maxSlippageBps > MAX_SLIPPAGE_BPS
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

    /// @notice Pagina uit de lijst van adressen die ooit instellingen hebben gezet (ook inactieve). Revert nooit,
    ///         ook niet bij `limit = type(uint256).max`.
    function owners(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 total = _owners.length;
        if (offset >= total) {
            return new address[](0);
        }
        // Niet `offset + limit`: dat overflowt bij een grote `limit` (audit L-A).
        uint256 end = limit > total - offset ? total : offset + limit;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _owners[i];
        }
    }

    function ownerCount() external view returns (uint256) {
        return _owners.length;
    }

    /// @notice Zou `execute(owner, …)` nu iets doen? `eurcDelta` > 0 = kopen voor dat bedrag, < 0 = verkopen.
    ///         Het bedrag is wat `execute` nu werkelijk zou handelen, dus al begrensd op saldo en allowance: bij
    ///         kopen het EURC-inputbedrag, bij verkopen de cbBTC-input tegen de oraclekoers (audit L-C).
    /// @dev Revert nooit: een storing in de feeds of sequencer, of een te grote spot-afwijking, geeft (false, 0).
    ///      Na `retire` altijd (false, 0).
    function isDue(address owner) external view returns (bool due, int256 eurcDelta) {
        Params memory p = params[owner];
        if (retired || !p.active || block.timestamp < uint256(lastExecutedAt[owner]) + p.interval) {
            return (false, 0);
        }
        (bool ok, uint256 price) = _tryQuote();
        if (!ok) {
            return (false, 0);
        }
        return _dueAt(owner, p, price);
    }

    /// @notice Pagina uit de owner-lijst, gefilterd op wie nu due is (zelfde regels als `isDue`). Revert nooit.
    /// @dev Een owner die structureel revert (blacklist, te krappe slippage) blijft in de lijst staan; het
    ///      contract onthoudt mislukte pogingen niet. De wekkers simuleren daarom eerst en houden zelf een
    ///      cool-down per owner bij. Na `retire` altijd een lege lijst.
    function dueOwners(uint256 offset, uint256 limit) external view returns (address[] memory due) {
        uint256 total = _owners.length;
        if (retired || offset >= total) {
            return new address[](0);
        }
        (bool ok, uint256 price) = _tryQuote();
        if (!ok) {
            return new address[](0);
        }
        // Niet `offset + limit`: dat overflowt bij een grote `limit` (audit L-A).
        uint256 end = limit > total - offset ? total : offset + limit;
        address[] memory candidates = new address[](end - offset);
        uint256 n;
        for (uint256 i = offset; i < end; i++) {
            address owner = _owners[i];
            Params memory p = params[owner];
            if (!p.active || block.timestamp < uint256(lastExecutedAt[owner]) + p.interval) {
                continue;
            }
            (bool isDueNow,) = _dueAt(owner, p, price);
            if (isDueNow) {
                candidates[n++] = owner;
            }
        }
        due = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            due[i] = candidates[i];
        }
    }

    function _dueAt(address owner, Params memory p, uint256 price) internal view returns (bool due, int256 eurcDelta) {
        (bool isBuy, uint256 amountIn,,,) = _plan(owner, p, price);
        if (amountIn == 0) {
            return (false, 0);
        }
        // Van `amountIn`, niet van de correctie vóór begrenzing: anders meldt isDue een grotere run dan execute doet.
        uint256 eurcAmount = isBuy ? amountIn : Math.mulDiv(amountIn, price, CBBTC_UNIT);
        eurcDelta = isBuy ? int256(eurcAmount) : -int256(eurcAmount);
        return (true, eurcDelta);
    }

    // ─── Uitvoeren ──────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Voert één rebalance-stap uit voor `owner`. Iedereen mag dit aanroepen.
    /// @param rewardTo Ontvanger van de beloning uit de fee; address(0) = hele fee naar de treasury.
    /// @dev Revert met `ContractRetired` zodra de treasury `retire` heeft aangeroepen.
    function execute(address owner, address rewardTo) external nonReentrant {
        if (retired) revert ContractRetired();
        Params memory p = params[owner];
        if (!p.active) revert Inactive();
        if (block.timestamp < uint256(lastExecutedAt[owner]) + p.interval) revert NotDue();
        // Een beloning aan het contract zelf zou blijven hangen; dan liever de hele fee naar de treasury.
        if (rewardTo == address(this)) rewardTo = address(0);

        uint256 price = _quoteChecked();
        (bool isBuy, uint256 amountIn,, uint256 total, uint256 fractionBps) = _plan(owner, p, price);
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
    }

    /// @notice Stuurt het volledige saldo van `token` in dit contract naar de treasury. Iedereen mag dit
    ///         aanroepen; het contract hoort buiten een transactie geen saldo te hebben, behalve fee die door een
    ///         mislukte treasury-transfer is achtergebleven (`FeeRetained`).
    function sweep(IERC20 token) external nonReentrant {
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) token.safeTransfer(TREASURY, balance);
    }

    /// @notice Stelt het contract eenmalig en onomkeerbaar buiten gebruik. Alleen de treasury mag dit.
    /// @dev Dit is de enige bevoegdheid van de treasury en de enige vlag die het gedrag van het contract kan
    ///      veranderen; er is geen weg terug en geen tegenhanger (`unretire`). Na `retire`:
    ///      - `execute` revert met `ContractRetired`, dus er wordt nooit meer een swap of fee geboekt;
    ///      - `isDue` geeft (false, 0) en `dueOwners` een lege lijst, zodat wekkers vanzelf stoppen;
    ///      - `setParams` accepteert alleen nog `active = false`, zodat gebruikers hun mandaat kunnen intrekken;
    ///      - `sweep` blijft werken om achtergebleven fee naar de treasury te halen.
    ///
    ///      Non-custodial blijft dit: het contract houdt nooit gebruikersfondsen. Het mandaat is een ERC-20-
    ///      allowance die in de tokencontracten bij de gebruiker staat; `retire` verandert daar niets aan en kan
    ///      er niets mee. Het enige pad dat die allowance ooit gebruikte (`execute`) is na `retire` dicht, dus de
    ///      treasury kan met deze knop geen fondsen verplaatsen, alleen het contract stilzetten. De gebruiker
    ///      houdt zelf de controle: `approve(0)` op EURC/cbBTC en/of `setParams` met `active = false`.
    function retire() external {
        if (msg.sender != TREASURY) revert NotTreasury(msg.sender);
        if (retired) revert AlreadyRetired();
        retired = true;
        emit Retired();
    }

    // ─── Intern: koers ──────────────────────────────────────────────────────────────────────────────────────

    /// @return price EURC-basiseenheden (6 dec) per 1 cbBTC.
    function _quote() internal view returns (uint256 price) {
        (, int256 seqAnswer, uint256 seqStartedAt,,) = SEQUENCER_FEED.latestRoundData();
        // startedAt == 0 is een niet-geïnitialiseerde ronde van de uptime-feed en telt als "onbekend", niet als up.
        if (seqAnswer != 0 || seqStartedAt == 0 || block.timestamp - seqStartedAt < GRACE_PERIOD) {
            revert SequencerDown();
        }

        uint256 cbbtcUsd = _readFeed(FEED_CBBTC_USD, MAX_AGE_CBBTC);
        uint256 eurcUsd = _readFeed(FEED_EURC_USD, MAX_AGE_EURC);
        price = Math.mulDiv(cbbtcUsd, EURC_UNIT, eurcUsd);
        if (price == 0) revert InvalidFeedAnswer(address(FEED_CBBTC_USD));
    }

    /// @dev Oracle-koers, geweigerd als de pool-spot er meer dan MAX_SPOT_DEVIATION_BPS van afwijkt.
    function _quoteChecked() internal view returns (uint256 price) {
        price = _quote();
        _requireSpotNear(price);
    }

    /// @dev Revert als de huidige pool-spot meer dan MAX_SPOT_DEVIATION_BPS van `price` afwijkt. Wordt vóór de
    ///      swap (via `_quoteChecked`) én na de swap aangeroepen, zodat voorschuiving en eigen prijsimpact samen
    ///      binnen de tolerantie moeten blijven.
    function _requireSpotNear(uint256 price) internal view {
        uint256 spotPrice = _spot();
        uint256 diff = spotPrice > price ? spotPrice - price : price - spotPrice;
        if (diff * BPS > price * MAX_SPOT_DEVIATION_BPS) revert SpotDeviatesFromOracle(spotPrice, price);
    }

    /// @return price EURC-basiseenheden (6 dec) per 1 cbBTC volgens de huidige spot van beide pools (midprijs,
    ///               zonder poolfees).
    function _spot() internal view returns (uint256 price) {
        uint256 usdcPerBtc = _spotOut(POOL_USDC_CBBTC, !_usdcIsToken0, CBBTC_UNIT);
        price = _spotOut(POOL_EURC_USDC, !_eurcIsToken0, usdcPerBtc);
    }

    /// @dev Hoeveel basiseenheden van het andere token `amountIn` basiseenheden waard zijn op de spot van
    ///      `pool`. `inIsToken0` zegt of het inputtoken token0 is. Rekent via ratioX128 = sqrtPriceX96² / 2^64
    ///      (past in uint256 voor elke uint160 sqrtPriceX96), zoals Uniswaps OracleLibrary.getQuoteAtTick bij
    ///      grote koersen. Niet via ratioX96 = sqrtPriceX96² / 2^96: die is 0 voor sqrtPriceX96 < 2^48 en de
    ///      deling erdoor gaf dan een Panic (audit lead 10). ratioX128 is ≥ 1 voor elke sqrtPriceX96 ≥ 2^32, dus
    ///      voor elke geldige Uniswap-koers (MIN_SQRT_RATIO = 4295128739 > 2^32).
    function _spotOut(IUniswapV3Pool pool, bool inIsToken0, uint256 amountIn) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, Q64);
        return inIsToken0 ? Math.mulDiv(amountIn, ratioX128, Q128) : Math.mulDiv(amountIn, Q128, ratioX128);
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
        try this.quoteChecked() returns (uint256 p) {
            return (true, p);
        } catch {
            return (false, 0);
        }
    }

    /// @notice Actuele koers volgens de feeds (EURC-basiseenheden per cbBTC). Revert bij storing.
    function quote() external view returns (uint256) {
        return _quote();
    }

    /// @notice Actuele koers volgens de feeds, met álle checks van `execute`: revert ook als de pool-spot te
    ///         ver van de feeds afwijkt.
    function quoteChecked() external view returns (uint256) {
        return _quoteChecked();
    }

    /// @notice Spotkoers van de twee Uniswap-pools (EURC-basiseenheden per cbBTC, midprijs zonder fees).
    function spot() external view returns (uint256) {
        return _spot();
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
            // Naar boven afgerond: anders is de teruggerekende waarde van een correctie die exact op de
            // minTrade-vloer zit tot bijna 1 sat te klein en zou een kleine wallet nooit kunnen verkopen.
            uint256 wantBtc = Math.mulDiv(correctionEurc, CBBTC_UNIT, price, Math.Rounding.Ceil);
            amountIn = Math.min(wantBtc, Math.min(btcBal, CBBTC.allowance(owner, address(this))));
            if (Math.mulDiv(amountIn, price, CBBTC_UNIT) < p.minTradeEurc) amountIn = 0;
        }
    }

    // ─── Intern: swaps ──────────────────────────────────────────────────────────────────────────────────────

    /// @dev Koop: fee over het bruto bedrag, rest de pool in, output rechtstreeks naar de owner. Revert met
    ///      `NoOutput` als de router 0 cbBTC oplevert, en met `SpotDeviatesFromOracle` als de spot na de swap te
    ///      ver van de oracle ligt.
    function _buy(address owner, Params memory p, uint256 amountIn, uint256 price, address rewardTo)
        internal
        returns (uint256 fee, uint256 reward, uint256 amountOut)
    {
        EURC.safeTransferFrom(owner, address(this), amountIn);
        (fee, reward) = _takeFee(amountIn, amountIn, rewardTo);
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
        if (amountOut == 0) revert NoOutput();
        _requireSpotNear(price);
    }

    /// @dev Verkoop: output naar het contract, fee over max(ontvangen, expectedOut), rest naar de owner. De fee is
    ///      begrensd op het ontvangen bedrag. Over `expectedOut` en niet alleen over `received`, zodat de fee van
    ///      een run op de MIN_TRADE_FLOOR na poolfees en slippage niet onder KEEPER_REWARD_EURC zakt (audit L-B).
    ///      Revert met `SpotDeviatesFromOracle` als de spot na de swap te ver van de oracle ligt.
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
        _requireSpotNear(price);

        (fee, reward) = _takeFee(Math.max(received, expectedOut), received, rewardTo);
        amountOut = received - fee;
        EURC.safeTransfer(owner, amountOut);
    }

    /// @dev Fee in EURC: FEE_BPS over `feeBase`, begrensd op `maxFee` (het EURC-bedrag waar de fee uit komt).
    ///      Bij een koop zijn beide het bruto inputbedrag; bij een verkoop is `feeBase` max(ontvangen,
    ///      expectedOut) en `maxFee` het ontvangen bedrag. Beloning eruit naar rewardTo, rest naar de treasury.
    ///      Beide transfers zijn niet-reverterend (`trySafeTransfer`), zodat de run nooit stukloopt op de ontvanger van de fee:
    ///      - faalt de beloning (bijv. geblacklist rewardTo), dan is `reward` 0 en gaat de hele fee naar de
    ///        treasury;
    ///      - faalt de treasury-transfer, dan blijft dat deel in het contract (`FeeRetained`) en haalt `sweep`
    ///        het later op.
    ///      De fee wordt in beide gevallen volledig bij de owner ingehouden; `reward + treasury + retained == fee`.
    function _takeFee(uint256 feeBase, uint256 maxFee, address rewardTo)
        internal
        returns (uint256 fee, uint256 reward)
    {
        fee = Math.min(Math.mulDiv(feeBase, FEE_BPS, BPS), maxFee);
        if (rewardTo != address(0)) {
            reward = Math.min(KEEPER_REWARD_EURC, fee);
            if (reward > 0 && !EURC.trySafeTransfer(rewardTo, reward)) reward = 0;
        }
        uint256 toTreasury = fee - reward;
        if (toTreasury > 0 && !EURC.trySafeTransfer(TREASURY, toTreasury)) emit FeeRetained(toTreasury);
    }
}
