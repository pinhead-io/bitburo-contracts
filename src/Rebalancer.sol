// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IV3SwapRouter} from "./interfaces/IV3SwapRouter.sol";
import {TickMath} from "./libraries/TickMath.sol";

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
 *      Sandwich-bescherming (audit M-1, L-3), in drie lagen:
 *      1. Blokcheck en blokvenster per pool. Een run gebeurt alleen als geen van beide pools in dit blok al een
 *         oracle-observatie schreef (`observations[slot0.observationIndex].blockTimestamp == block.timestamp`,
 *         anders `PoolTouchedThisBlock`). Volgens Uniswap v3-core (commit d8b1c635) schrijven precies deze acties
 *         een observatie:
 *         - een swap die de tick verandert (UniswapV3Pool.sol:732-748);
 *         - een mint of burn met liquiditeit > 0 van een positie waarvan de range de huidige tick bevat
 *           (`_modifyPosition`, :327 en :336-348).
 *         Hooguit één per blok (Oracle.sol:90). Een swap binnen de tick, een mint of burn buiten de range, een
 *         burn van 0, `collect` en `flash` schrijven niets. Is er in dit blok geen observatie, dan staan tick en
 *         in-range liquiditeit nog zoals aan het begin van het blok: een aanvaller kan in dit blok hooguit binnen
 *         de begintick duwen (≤ 1 tick ≈ 1 bp per pool) en geen JIT-liquiditeit in de range zetten. Vóór én na de
 *         swap moet de koers bovendien binnen MAX_BLOCK_MOVE_BPS van die begintick liggen, inclusief de eigen
 *         swap. Restrisico: een LP met een groot aandeel die in een eerder blok minde, krijgt een deel van de
 *         poolfee terug. Bij de huidige protocolfee levert dat met een push binnen de tick gemeten tot +0,18 bp
 *         van de run op (blok 51.402.700, aandeel 95%; de uitkomst schuift per blok met de poolstand), begrensd
 *         < 0,5 bp in de fork-tests; zet Uniswap de protocolfee op 0, dan gemeten tot ~0,9 bp, begrensd < 1 bp.
 *         Niet gezien wordt duwen aan het eind van het vorige blok (review I-4; niet atomair, laag 3 en arbitrage
 *         begrenzen het).
 *         Meerdere `execute`'s in hetzelfde blok delen hetzelfde venster, maar alleen zolang geen run de tick
 *         verandert; daarna is de pool in dit blok aangeraakt.
 *      2. Runomvang uit de liquiditeit. `_plan` begrenst de run zo dat de geschatte eindkoers op SIZING_BPS van
 *         de resterende ruimte tot de vensterrand blijft, gerekend met de kleinste liquiditeit tot die rand (ook
 *         voorbij een tickgrens in het venster, review L-1). Liquiditeit buiten de range maakt een run nooit groter dan
 *         de in-range liquiditeit toelaat (wel kan ze een klif opheffen die de run eerst kleiner maakte).
 *         Past de correctie daar niet in, dan gaat hij in delen (zie `rounds`).
 *      3. Spot tegen Chainlink. Vóór én na elke swap moet de spot van beide pools binnen
 *         MAX_SPOT_DEVIATION_BPS van de Chainlink-koers liggen, en `amountOutMinimum` volgt uit Chainlink en
 *         `maxSlippageBps`. Dat begrenst duwen over meerdere blokken, wat het blokvenster niet ziet. Het
 *         maximale verlies per run ten opzichte van de Chainlink-koers blijft FEE_BPS + maxSlippageBps
 *         (0,85% tot 1,25%). Omdat de eigen swap de gecombineerde spot hooguit ~12 bp verschuift (6 bp per pool),
 *         kan een eerlijke run alleen na de swap op de spotcheck vastlopen als de spot vooraf al meer dan ~38 bp in
 *         de runrichting afweek (audit lead 4; gemeten in 0,69% van de uurmetingen over 30 dagen, zie README).
 *         Beide feeds zijn volgens Chainlink `dex_state_price`; welke pools erin zitten is niet gepubliceerd, dus
 *         de bewaakte pools kunnen deels in de feed zitten (audit lead 5, zie README).
 *
 *      Delen: een run die door de liquiditeit is begrensd, opent een ronde. Het volgende deel in dezelfde
 *      richting mag al na CHUNK_INTERVAL in plaats van na `interval`, tot de afwijking binnen de band is of het
 *      budget van de ronde (maxCorrectionBps van de waarde bij de eerste run) op is. Elk deel is een gewone run
 *      met fee en keeperbeloning.
 *
 *      Uitval: een run revert vóór de swap met `PoolTouchedThisBlock` als een pool in dit blok al een observatie
 *      schreef (door anderen of door een eerdere run), en met `BlockMoveExceeded` als er te weinig ruimte of
 *      liquiditeit is of de run de vensterrand haalt. Beide zijn tijdelijk: in een volgend blok opnieuw proberen.
 *      Gemeten op Base (2.000 blokken rond blok 51.390.800) valt door de blokcheck 0% van de pogingen uit als de
 *      transactie bovenaan het blok staat, 4,3% halverwege en 7 tot 11% onderaan.
 *
 *      Runs tegenhouden (audit L-3): wie een pool elk blok aanraakt (een burn van 1 liquiditeit in de range kost
 *      ~92.630 gas, gemeten ~1,8 EURC per uur), houdt alle runs in die blokken tegen, zonder er iets aan te
 *      verdienen. Geen contractwijziging maakt dat duurder zonder de aanraking voor gas te laten staan; het antwoord
 *      zit in de wekkers: lezen met blok-overrides voor het volgende blok, het hele retry-budget blijven proberen,
 *      en versturen met een priority fee die na een blokkade oploopt, zodat de aanvaller die tip elk blok moet
 *      betalen (zie README en keeper/keeper.ts).
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
    /// @dev Op Base de Standard proxy `0x9867…01e0` van de SVR-feed EURC/USD, niet de SVR-proxy `0x8a55…E287`: zo
    ///      geldt de vertraging voor de MEV-Share-veiling niet (audit lead 5).
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
    /// @notice tickSpacing van de POOL_FEE-pools (UniswapV3Factory: feeAmountTickSpacing[500] = 10, niet te wijzigen).
    ///         De constructor dwingt het af; `_maxInput` rekent erop.
    int24 public constant TICK_SPACING = 10;
    uint16 public constant FEE_BPS = 25;
    uint256 public constant KEEPER_REWARD_EURC = 50_000; // 0,05 EURC
    uint16 public constant MAX_SLIPPAGE_BPS = 100;
    /// @notice Ondergrens voor `maxSlippageBps`: MAX_SPOT_DEVIATION_BPS + 2 × 5 bps poolfee. `amountOutMinimum`
    ///         wordt van de oracle afgeleid, terwijl de swap tegen de pool-spot loopt; die mag 0,5% afwijken en
    ///         kost 0,1% aan poolfees. Onder 60 bps zou een run die de spot-check haalt structureel op
    ///         "Too little received" kunnen reverten.
    uint16 public constant MIN_SLIPPAGE_BPS = 60;
    uint16 public constant MAX_SPOT_DEVIATION_BPS = 50;
    /// @notice Ondergrens voor `minTradeEurc` (20 EURC) en voor elke run, ook elk deel van een ronde. Bij
    ///         FEE_BPS = 25 is de fee van de kleinste run dan precies KEEPER_REWARD_EURC, zodat elke run de
    ///         volledige keeperbeloning dekt en een dust-owner de wekkers niet gratis bezig kan houden. Dat geldt
    ///         voor kopen én verkopen: bij een koop is de fee-grondslag het bruto inputbedrag, bij een verkoop
    ///         max(ontvangen, verwachte opbrengst), waarbij de verwachte opbrengst dezelfde oraclewaarde is waarop
    ///         de ondergrens is gecontroleerd (audit L-B). Bovendien is `expectedOut` bij een koop dan ≥ ~25.000
    ///         sats bij 80.000 EURC/cbBTC, waardoor de afronding in `amountOutMinimum` onder 1 bp blijft.
    uint64 public constant MIN_TRADE_FLOOR = 20e6;
    /// @notice Hoever de koers van elke pool binnen één blok van de koers aan het begin van dat blok mag
    ///         afliggen, inclusief de eigen swap (audit M-1). Onder de poolfee heen en terug (2 × 5 bp), zodat
    ///         een zelf-sandwich per geduwde eenheid verlies maakt. De begintick is afgerond; het venster wordt
    ///         vanaf de ongunstigste rand van die tick gerekend, zodat de afronding (≤ 1 tick ≈ 1 bp) alleen
    ///         eerlijke runs ruimte kost en nooit een aanvaller ruimte geeft.
    ///         Moet ruim onder TICK_SPACING ticks blijven (1 tick ≈ 1 bp): `_maxInput` gaat ervan uit dat er tussen de
    ///         koers en de vensterrand hooguit één initialiseerbare tickgrens ligt.
    uint16 public constant MAX_BLOCK_MOVE_BPS = 6;
    /// @notice Welk deel van de resterende ruimte tot de vensterrand een run volgens de schatting bij constante
    ///         liquiditeit mag gebruiken. De marge vangt liquiditeit die over een tickgrens dunner wordt.
    uint16 public constant SIZING_BPS = 7500;
    /// @notice Minimale tijd tussen twee delen van één ronde.
    uint32 public constant CHUNK_INTERVAL = 10 minutes;
    /// @notice Ondergrens voor `maxCorrectionBps` (0,1% per run): sluit configuraties uit die elk interval een
    ///         verwaarloosbare correctie doen en daarmee eeuwig due blijven.
    uint16 public constant MIN_CORRECTION_BPS = 10;
    /// @notice Ondergrens voor `bandBps` (1,25%): FEE_BPS + MAX_SLIPPAGE_BPS, het meeste wat een run kost. Een run
    ///         gebeurt dus pas bij een afwijking die groter is dan dat verlies. Zo kan een permissionless aanroeper een
    ///         wallet niet herhaaldelijk laten handelen op kleine koersbewegingen zonder dat de verhouding echt
    ///         verbetert, en is een volledige correctie in één run klaar: de restafwijking door fee en slippage
    ///         (≤ 1,25% van het runbedrag) valt binnen de band (rekenaudit 2026-09-15, I-01).
    uint16 public constant MIN_BAND_BPS = 125;
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
    /// @dev Decimalen waar EURC_UNIT, CBBTC_UNIT, MIN_TRADE_FLOOR en KEEPER_REWARD_EURC op rekenen; USDC als tussenhop
    ///      met 6. De constructor dwingt ze af (review I-4).
    uint8 private constant EURC_DECIMALS = 6;
    uint8 private constant CBBTC_DECIMALS = 8;
    uint8 private constant USDC_DECIMALS = 6;
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant Q128 = 1 << 128;

    // ─── Per gebruiker ──────────────────────────────────────────────────────────────────────────────────────

    struct Params {
        bool active;
        uint16 targetBps; // cbBTC-aandeel, 500–9500, veelvoud van 100
        uint16 bandBps; // MIN_BAND_BPS–9999
        uint16 maxCorrectionBps; // MIN_CORRECTION_BPS–10000, aandeel van de totale waarde per run
        uint64 minTradeEurc; // EURC-basiseenheden, >= MIN_TRADE_FLOOR
        uint32 interval; // minimale tijd tussen runs, >= MIN_INTERVAL
        uint16 maxSlippageBps; // MIN_SLIPPAGE_BPS–MAX_SLIPPAGE_BPS
    }

    /// @notice Een lopende rebalance-ronde: de vorige run was door de liquiditeit begrensd en de correctie is nog
    ///         niet klaar. `remainingEurc` is wat er van het budget van de ronde over is; 0 = geen ronde.
    struct Round {
        bool isBuy;
        uint128 remainingEurc;
    }

    mapping(address owner => Params) public params;
    /// @notice Tijdstip van de laatste run, ook van een deel. Een nieuwe ronde kan pas `interval` daarna.
    mapping(address owner => uint64) public lastExecutedAt;
    /// @notice Lopende ronde per owner. Een deel mag CHUNK_INTERVAL na de vorige run, alleen in `isBuy`-richting
    ///         en tot `remainingEurc`. `setParams` breekt de ronde af.
    mapping(address owner => Round) public rounds;
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
    /// @notice De pool heeft niet de tickSpacing TICK_SPACING waar de runomvang op rekent.
    error UnexpectedTickSpacing(address pool);
    /// @notice De pool is niet de POOL_FEE-pool van de factory van de router, dus niet de pool van de swap.
    error PoolNotFromRouterFactory(address pool);
    error SpotDeviatesFromOracle(uint256 spot, uint256 oracle);
    /// @notice De koers van `pool` ligt na de swap verder dan MAX_BLOCK_MOVE_BPS van de koers aan het begin van dit
    ///         blok, of er is te weinig ruimte of liquiditeit voor een run van MIN_TRADE_FLOOR. Tijdelijk: in een
    ///         volgend blok opnieuw proberen.
    error BlockMoveExceeded(address pool);
    /// @notice `pool` schreef in dit blok al een oracle-observatie (tickwissel door een swap, of een mint of burn in
    ///         de range), vóór deze run. Tijdelijk: in een volgend blok opnieuw proberen.
    error PoolTouchedThisBlock(address pool);
    error UnexpectedFeedDecimals(address feed);
    /// @notice `token` heeft niet de decimalen waar het contract op rekent (EURC 6, cbBTC 8, USDC 6).
    error UnexpectedTokenDecimals(address token);
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

        // De eenheden en ondergrenzen hierboven zijn vaste getallen in basiseenheden; een token met andere decimalen
        // (bijvoorbeeld verwisselde adressen) zou elke run met een factor 100 of meer verkeerd rekenen (review I-4).
        // USDC zit in het swappad; de omrekening via de pool hangt niet van zijn decimalen af, maar een ander token
        // op die plek is een deployfout.
        _requireDecimals(d.eurc, EURC_DECIMALS);
        _requireDecimals(d.cbbtc, CBBTC_DECIMALS);
        _requireDecimals(d.usdc, USDC_DECIMALS);
    }

    function _requireDecimals(address token, uint8 expected) private view {
        if (IERC20Metadata(token).decimals() != expected) revert UnexpectedTokenDecimals(token);
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
        if (pool.tickSpacing() != TICK_SPACING) revert UnexpectedTickSpacing(address(pool));
        if (factory.getPool(a, b, POOL_FEE) != address(pool)) revert PoolNotFromRouterFactory(address(pool));
    }

    // ─── Gebruiker ──────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Zet of wijzigt de eigen instellingen. Alleen msg.sender kan zijn eigen instellingen wijzigen.
    /// @dev Economische ondergrenzen: `minTradeEurc >= MIN_TRADE_FLOOR`, `maxCorrectionBps >= MIN_CORRECTION_BPS` en
    ///      `bandBps >= MIN_BAND_BPS`.
    ///      Na `retire` is alleen `active = false` nog toegestaan (mandaat intrekken); een actief mandaat zetten
    ///      revert dan met `ContractRetired`. Breekt een lopende ronde af: de volgende run is weer een nieuwe
    ///      ronde, `interval` na de laatste run.
    ///      Niet atomair (audit lead 7): wie deze transactie (of een `approve(0)`) ziet voordat ze in een Flashblock
    ///      zit, kan er met een hogere priority fee één `execute` op de oude instellingen vóór zetten, binnen de
    ///      gewone grenzen van een run. Daarna geldt `interval`; wie zeker geen run meer wil, stuurt eerst `approve(0)`.
    ///      Registreren vraagt geen saldo of allowance en het register krimpt nooit (audit lead 9). Een saldo-eis
    ///      is te omzeilen en zou "eerst instellen, dan storten" onmogelijk maken; wekkers filteren het register
    ///      daarom zelf off-chain op saldo en allowance.
    function setParams(Params calldata p) external {
        if (retired && p.active) revert ContractRetired();
        if (
            p.targetBps < MIN_TARGET_BPS || p.targetBps > MAX_TARGET_BPS || p.targetBps % 100 != 0
                || p.bandBps < MIN_BAND_BPS || p.bandBps >= BPS || p.maxCorrectionBps < MIN_CORRECTION_BPS
                || p.maxCorrectionBps > BPS || p.minTradeEurc < MIN_TRADE_FLOOR || p.interval < MIN_INTERVAL
                || p.maxSlippageBps < MIN_SLIPPAGE_BPS || p.maxSlippageBps > MAX_SLIPPAGE_BPS
        ) {
            revert InvalidParams();
        }
        params[msg.sender] = p;
        delete rounds[msg.sender];
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
    ///         Tijdens een ronde is dit het volgende deel, dus hooguit wat nu in het blokvenster past.
    /// @dev Revert nooit: een storing in de feeds of sequencer, een te grote spot-afwijking, een pool die in dit blok
    ///      al een observatie schreef, of te weinig ruimte in het blokvenster geeft (false, 0). Na `retire` altijd
    ///      (false, 0).
    function isDue(address owner) external view returns (bool due, int256 eurcDelta) {
        Params memory p = params[owner];
        if (retired || !p.active) {
            return (false, 0);
        }
        (bool timeDue, bool chunk) = _timing(owner, p);
        if (!timeDue) {
            return (false, 0);
        }
        (bool ok, uint256 price) = _tryQuote();
        if (!ok) {
            return (false, 0);
        }
        (address touched, Window memory w1, Window memory w2) = _windows();
        if (touched != address(0)) {
            return (false, 0);
        }
        RunCaps memory caps;
        return _dueAt(owner, p, price, chunk, w1, w2, caps);
    }

    /// @notice Pagina uit de owner-lijst, gefilterd op wie nu due is (zelfde regels als `isDue`). Revert nooit.
    /// @dev Een owner die structureel revert (blacklist, te krappe slippage) blijft in de lijst staan; het
    ///      contract onthoudt mislukte pogingen niet. De wekkers simuleren daarom eerst en houden zelf een
    ///      cool-down per owner bij. Na `retire` altijd een lege lijst. Alle owners in de lijst delen hetzelfde
    ///      blokvenster: na één run in dit blok is er voor de rest meestal geen ruimte meer (een run die de tick
    ///      verandert, raakt de pool aan). Heeft een pool in dit blok al een observatie, dan is de lijst leeg.
    ///      Koers, blokvensters en de runomvang per richting worden één keer per pagina gelezen (review I-2); een
    ///      pagina van 50 due owners kost gemeten ~1,24 mln gas.
    function dueOwners(uint256 offset, uint256 limit) external view returns (address[] memory due) {
        uint256 total = _owners.length;
        if (retired || offset >= total) {
            return new address[](0);
        }
        (bool ok, uint256 price) = _tryQuote();
        if (!ok) {
            return new address[](0);
        }
        (address touched, Window memory w1, Window memory w2) = _windows();
        if (touched != address(0)) {
            return new address[](0);
        }
        // Niet `offset + limit`: dat overflowt bij een grote `limit` (audit L-A).
        uint256 end = limit > total - offset ? total : offset + limit;
        address[] memory candidates = new address[](end - offset);
        uint256 n;
        // Eén cache voor de hele pagina: de runomvang per richting hangt niet van de owner af (review I-2).
        RunCaps memory caps;
        for (uint256 i = offset; i < end; i++) {
            address owner = _owners[i];
            Params memory p = params[owner];
            if (!p.active) {
                continue;
            }
            (bool timeDue, bool chunk) = _timing(owner, p);
            if (!timeDue) {
                continue;
            }
            (bool isDueNow,) = _dueAt(owner, p, price, chunk, w1, w2, caps);
            if (isDueNow) {
                candidates[n++] = owner;
            }
        }
        due = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            due[i] = candidates[i];
        }
    }

    function _dueAt(
        address owner,
        Params memory p,
        uint256 price,
        bool chunk,
        Window memory w1,
        Window memory w2,
        RunCaps memory caps
    ) internal view returns (bool due, int256 eurcDelta) {
        Plan memory pl = _plan(owner, p, price, chunk, w1, w2, caps);
        if (pl.amountIn == 0) {
            return (false, 0);
        }
        // Van `amountIn`, niet van de correctie vóór begrenzing: anders meldt isDue een grotere run dan execute doet.
        uint256 eurcAmount = pl.isBuy ? pl.amountIn : Math.mulDiv(pl.amountIn, price, CBBTC_UNIT);
        eurcDelta = pl.isBuy ? int256(eurcAmount) : -int256(eurcAmount);
        return (true, eurcDelta);
    }

    /// @return timeDue Laat de klok nu een run toe?
    /// @return chunk   True als dat alleen als deel van de lopende ronde mag (CHUNK_INTERVAL na de vorige run);
    ///                 false als `interval` verstreken is en dit een nieuwe ronde is. Een nieuwe ronde gaat voor.
    function _timing(address owner, Params memory p) internal view returns (bool timeDue, bool chunk) {
        uint256 last = lastExecutedAt[owner];
        if (block.timestamp >= last + p.interval) {
            return (true, false);
        }
        return (rounds[owner].remainingEurc > 0 && block.timestamp >= last + CHUNK_INTERVAL, true);
    }

    // ─── Uitvoeren ──────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Voert één rebalance-stap uit voor `owner`. Iedereen mag dit aanroepen.
    /// @param rewardTo Ontvanger van de beloning uit de fee; address(0) = hele fee naar de treasury.
    /// @dev Revert met `ContractRetired` zodra de treasury `retire` heeft aangeroepen, vóór de swap met
    ///      `PoolTouchedThisBlock` als een pool in dit blok al een observatie schreef, met `BlockMoveExceeded` als er
    ///      te weinig ruimte of liquiditeit is of de koers na de swap buiten het venster ligt.
    function execute(address owner, address rewardTo) external nonReentrant {
        if (retired) revert ContractRetired();
        Params memory p = params[owner];
        if (!p.active) revert Inactive();
        (bool timeDue, bool chunk) = _timing(owner, p);
        if (!timeDue) revert NotDue();
        // Een beloning aan het contract zelf zou blijven hangen; dan liever de hele fee naar de treasury.
        if (rewardTo == address(this)) rewardTo = address(0);

        // Eerst de blokcheck: een push in dit blok die ook de spot-check zou raken, meldt zich zo als tijdelijk.
        (address touched, Window memory w1, Window memory w2) = _windows();
        if (touched != address(0)) revert PoolTouchedThisBlock(touched);
        uint256 price = _quoteChecked();
        RunCaps memory caps;
        Plan memory pl = _plan(owner, p, price, chunk, w1, w2, caps);
        if (pl.blockedBy != address(0)) revert BlockMoveExceeded(pl.blockedBy);
        if (pl.amountIn == 0) revert NothingToDo();

        // Vanaf hier wordt de run geboekt, ook al zou de swap nog reverten (dan revert alles).
        lastExecutedAt[owner] = uint64(block.timestamp);
        if (pl.roundLeftEurc > 0) {
            rounds[owner] = Round({isBuy: pl.isBuy, remainingEurc: uint128(pl.roundLeftEurc)});
        } else {
            delete rounds[owner];
        }

        uint256 fee;
        uint256 reward;
        uint256 amountOut;
        if (pl.isBuy) {
            (fee, reward, amountOut) = _buy(owner, p, pl.amountIn, price, rewardTo);
        } else {
            (fee, reward, amountOut) = _sell(owner, p, pl.amountIn, price, rewardTo);
        }
        // Blokvenster ná de swap: push vooraf plus de eigen impact samen binnen MAX_BLOCK_MOVE_BPS.
        _requireWithinWindow(POOL_EURC_USDC, w1);
        _requireWithinWindow(POOL_USDC_CBBTC, w2);

        emit Executed(owner, pl.isBuy, pl.amountIn, fee, reward, rewardTo, amountOut, price, pl.total, pl.fractionBps);
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
        return _convert(sqrtPriceX96, inIsToken0, amountIn);
    }

    /// @dev Zie `_spotOut`, met een gegeven sqrtPriceX96.
    function _convert(uint160 sqrtPriceX96, bool inIsToken0, uint256 amountIn) internal pure returns (uint256) {
        uint256 ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, Q64);
        return inIsToken0 ? Math.mulDiv(amountIn, ratioX128, Q128) : Math.mulDiv(amountIn, Q128, ratioX128);
    }

    // ─── Intern: blokvenster ────────────────────────────────────────────────────────────────────────────────

    /// @dev De toegestane sqrtPriceX96 van een pool in dit blok, plus de stand waarmee de run wordt afgemeten.
    struct Window {
        uint160 lower;
        uint160 upper;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        int24 tick;
    }

    /// @return touched address(0), of de eerste pool die in dit blok al een observatie schreef.
    function _windows() internal view returns (address touched, Window memory w1, Window memory w2) {
        bool t;
        (t, w1) = _window(POOL_EURC_USDC);
        if (t) return (address(POOL_EURC_USDC), w1, w2);
        (t, w2) = _window(POOL_USDC_CBBTC);
        if (t) return (address(POOL_USDC_CBBTC), w1, w2);
    }

    /// @dev Blokcheck en venster [lower, upper] voor sqrtPriceX96 van `pool` in dit blok. Revert niet.
    ///
    ///      Blokcheck. `touched = true` als de pool in dit blok al een observatie schreef; het venster is dan leeg en
    ///      wordt niet gebruikt. Welke acties schrijven staat bovenaan het contract. Oracle.write zet
    ///      `observationIndex` op de nieuwe observatie (ook bij cardinality 1, dan overschrijft hij index 0), dus
    ///      `observations(observationIndex)` is altijd de laatste.
    ///
    ///      Begintick. Zonder observatie in dit blok is de tick sinds het blokbegin niet veranderd (elke tickwissel
    ///      schrijft, en de eerste schrijfactie van een blok gaat altijd door): begintick = slot0.tick. Een afleiding
    ///      uit twee observaties is daardoor niet nodig. Dat blijft zo tot na de swap: het venster wordt vóór de swap
    ///      berekend en na de swap tegen de nieuwe koers gehouden.
    ///
    ///      Afronding. De werkelijke beginkoers ligt ergens in [P(t), P(t+1)] (sqrtPriceX96 bij tick t en t+1), want
    ///      een swap binnen de tick verschuift de koers zonder observatie. De ondergrens wordt vanaf P(t+1) gerekend en
    ///      de bovengrens vanaf P(t), zodat de toegestane beweging vanaf de werkelijke beginkoers in beide richtingen
    ///      hooguit MAX_BLOCK_MOVE_BPS is. De afronding van TickMath, de wortel en mulDiv gaat steeds naar een smaller
    ///      venster.
    function _window(IUniswapV3Pool pool) internal view returns (bool touched, Window memory w) {
        (uint160 sqrtPriceX96, int24 tick, uint16 index,,,,) = pool.slot0();
        (uint32 lastTimestamp,,,) = pool.observations(index);
        if (lastTimestamp == uint32(block.timestamp)) return (true, w);
        w.sqrtPriceX96 = sqrtPriceX96;
        w.liquidity = pool.liquidity();
        w.tick = tick;
        // Een echte pool heeft altijd MIN_TICK <= tick < MAX_TICK (de swap weigert MIN/MAX_SQRT_RATIO als limiet).
        // Anders een leeg venster: geen run (BlockMoveExceeded), en geen revert in TickMath.
        if (tick < TickMath.MIN_TICK || tick >= TickMath.MAX_TICK) {
            w.lower = type(uint160).max;
            return (false, w);
        }
        uint256 down =
            Math.sqrt(Math.mulDiv(BPS - MAX_BLOCK_MOVE_BPS, Q96 * Q96, BPS, Math.Rounding.Ceil), Math.Rounding.Ceil);
        uint256 up = Math.sqrt(Math.mulDiv(BPS + MAX_BLOCK_MOVE_BPS, Q96 * Q96, BPS));
        // TickMath rondt naar boven af; voor de bovengrens daarom 1 eraf, zodat P(t) nooit te hoog is. Vlak onder
        // MAX_TICK past P(t) × √(1 + 6 bp) niet meer in uint160; dan geldt de grootste sqrtPriceX96 als grens.
        w.lower = uint160(Math.mulDiv(TickMath.getSqrtPriceAtTick(tick + 1), down, Q96, Math.Rounding.Ceil));
        w.upper = uint160(Math.min(Math.mulDiv(TickMath.getSqrtPriceAtTick(tick) - 1, up, Q96), type(uint160).max));
    }

    /// @dev Revert met `BlockMoveExceeded` als de huidige koers van `pool` buiten het venster ligt.
    function _requireWithinWindow(IUniswapV3Pool pool, Window memory w) internal view {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        if (sqrtPriceX96 < w.lower || sqrtPriceX96 > w.upper) revert BlockMoveExceeded(address(pool));
    }

    /// @dev Uitkomst van `_maxRunEurc` per richting, onthouden binnen één aanroep. Leeg = nog niet berekend.
    struct RunCaps {
        bool buyKnown;
        bool sellKnown;
        uint256 buyEurc;
        uint256 sellEurc;
        address buyBinding;
        address sellBinding;
    }

    /// @dev `_maxRunEurc` met `caps` als cache (review I-2). De uitkomst hangt alleen af van de richting, `price`, de
    ///      vensters en de pool- en tickstaat van dit blok, en niets daarvan hangt van de owner af of verandert binnen
    ///      een view-aanroep. `dueOwners` deelt één cache over de pagina en leest zo per richting hooguit één keer de
    ///      ticks; `isDue` en `execute` geven een lege cache mee en rekenen precies als zonder cache.
    function _maxRunCached(bool isBuy, uint256 price, Window memory w1, Window memory w2, RunCaps memory caps)
        internal
        view
        returns (uint256 eurc, address binding)
    {
        if (isBuy) {
            if (!caps.buyKnown) {
                (caps.buyEurc, caps.buyBinding) = _maxRunEurc(true, price, w1, w2);
                caps.buyKnown = true;
            }
            return (caps.buyEurc, caps.buyBinding);
        }
        if (!caps.sellKnown) {
            (caps.sellEurc, caps.sellBinding) = _maxRunEurc(false, price, w1, w2);
            caps.sellKnown = true;
        }
        return (caps.sellEurc, caps.sellBinding);
    }

    /// @return eurc    Grootste run in EURC waarvan de geschatte eindkoers in beide pools binnen SIZING_BPS van de
    ///                 resterende ruimte tot de vensterrand blijft. 0 als een pool nu al buiten zijn venster ligt of
    ///                 voorbij de tickgrens in het venster geen liquiditeit heeft.
    /// @return binding De pool die de grens bepaalt.
    function _maxRunEurc(bool isBuy, uint256 price, Window memory w1, Window memory w2)
        internal
        view
        returns (uint256 eurc, address binding)
    {
        // Hop EURC/USDC: bij kopen gaat EURC erin, bij verkopen USDC. Beide omgerekend naar EURC via deze pool.
        uint256 in1 = _maxInput(POOL_EURC_USDC, w1, isBuy == _eurcIsToken0);
        uint256 eurc1 = isBuy ? in1 : _convert(w1.sqrtPriceX96, !_eurcIsToken0, in1);
        // Hop USDC/cbBTC: bij kopen gaat USDC erin (omgerekend via EURC/USDC), bij verkopen cbBTC (via de oracle).
        uint256 in2 = _maxInput(POOL_USDC_CBBTC, w2, isBuy == _usdcIsToken0);
        uint256 eurc2 = isBuy ? _convert(w1.sqrtPriceX96, !_eurcIsToken0, in2) : Math.mulDiv(in2, price, CBBTC_UNIT);
        return eurc1 <= eurc2 ? (eurc1, address(POOL_EURC_USDC)) : (eurc2, address(POOL_USDC_CBBTC));
    }

    /// @dev Inputhoeveelheid die de koers SIZING_BPS van de weg naar de vensterrand in de swaprichting brengt
    ///      (Uniswap-formules voor amount0/amount1 tussen twee sqrtPrices, zonder poolfee: de fee verschuift de koers
    ///      niet, dus dit is aan de voorzichtige kant). Een pool buiten zijn venster geeft 0. Begrensd op 2^96
    ///      basiseenheden, zodat de omrekening naar EURC nooit overloopt.
    ///
    ///      Liquiditeit (review L-1). Gerekend wordt met de kleinste liquiditeit tot de vensterrand: de in-range
    ///      liquiditeit nu, en voorbij de eerstvolgende initialiseerbare tickgrens in de swaprichting de liquiditeit
    ///      na het kruisen (± `liquidityNet` van die tick). Omlaag is dat floor(tick / TICK_SPACING) × TICK_SPACING,
    ///      ook als de koers er precies op staat (UniswapV3Pool.swap kruist die tick dan meteen); omhoog de grens
    ///      daarboven. Met begintick t (1 tick ≈ 1 bp) kan een swap binnen het venster omlaag hooguit de grenzen t tot
    ///      en met t − 5 kruisen en omhoog t + 1 tot en met t + 5. Dat zijn per richting minder dan TICK_SPACING
    ///      opeenvolgende ticks, dus hooguit één veelvoud van TICK_SPACING, en een `tickBitmap`-lookup is niet nodig:
    ///      een niet-geïnitialiseerde tick heeft `liquidityNet` 0. Liquiditeit voorbij de grens die groter is, maakt de run
    ///      nooit groter; is ze 0, dan geen run. Een grens precies op de vensterrand telt mee (voorzichtig).
    function _maxInput(IUniswapV3Pool pool, Window memory w, bool zeroForOne) internal view returns (uint256 amount) {
        if (w.sqrtPriceX96 < w.lower || w.sqrtPriceX96 > w.upper) return 0;
        uint256 liquidity = w.liquidity;
        int24 boundary = w.tick / TICK_SPACING;
        if (w.tick < 0 && w.tick % TICK_SPACING != 0) boundary--;
        boundary = boundary * TICK_SPACING + (zeroForOne ? int24(0) : TICK_SPACING);
        if (boundary >= TickMath.MIN_TICK && boundary <= TickMath.MAX_TICK) {
            uint160 atBoundary = TickMath.getSqrtPriceAtTick(boundary);
            if (zeroForOne ? atBoundary >= w.lower : atBoundary <= w.upper) {
                (, int128 net,,,,,,) = pool.ticks(boundary);
                // Omlaag kruisen trekt `liquidityNet` af, omhoog telt het op (UniswapV3Pool.swap).
                int256 beyond = zeroForOne ? int256(liquidity) - net : int256(liquidity) + net;
                if (beyond <= 0) return 0;
                liquidity = Math.min(liquidity, uint256(beyond));
            }
        }
        if (zeroForOne) {
            // token0 erin: koers omlaag naar `lower`. amount0 = L × 2^96 × (√P − √lower) / (√P × √lower).
            amount = Math.mulDiv(liquidity << 96, w.sqrtPriceX96 - w.lower, w.sqrtPriceX96) / w.lower;
        } else {
            // token1 erin: koers omhoog naar `upper`. amount1 = L × (√upper − √P) / 2^96.
            amount = Math.mulDiv(liquidity, w.upper - w.sqrtPriceX96, Q96);
        }
        amount = Math.min(amount, type(uint96).max) * SIZING_BPS / BPS;
    }

    /// @dev Geen absolute min/max op `answer` (audit lead 6): de aggregators handhaven er zelf geen zinvolle (minAnswer 1,
    ///      maxAnswer 2^176 − 1), en een vaste grens zou dit onveranderbare contract bij een echte extreme koers
    ///      blijvend stilleggen. De koers wordt vóór en na elke swap tegen beide pools gehouden (`_requireSpotNear`);
    ///      een foute feed levert alleen een trade op als de pools op dezelfde foute koers staan.
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

    /// @dev Uitkomst van `_plan`.
    struct Plan {
        bool isBuy; // richting
        uint256 amountIn; // in het input-token, al begrensd op saldo, allowance en blokvenster; 0 = niets doen
        uint256 total; // totale waarde in EURC
        uint256 fractionBps; // huidig cbBTC-aandeel in bps
        uint256 roundLeftEurc; // > 0: de ronde loopt door met dit budget (run was door de liquiditeit begrensd)
        address blockedBy; // != 0: er is een correctie, maar die past nu niet in het blokvenster van deze pool
    }

    /**
     * @dev Rekenregel per run.
     *      1. Correctie zoals in de app: |drift| × total, alleen buiten de band.
     *      2. Budget: bij een nieuwe ronde max(total × maxCorrectionBps, minTradeEurc); bij een deel wat er van de
     *         ronde over is. Een deel in de andere richting dan de ronde gebeurt niet (geen ping-pong).
     *      3. correctie = min(correctie, budget); onder minTradeEurc -> niets (ook: de ronde is klaar).
     *      4. run = min(correctie, `_maxRunEurc`). Onder MIN_TRADE_FLOOR -> `blockedBy`: de correctie wacht op
     *         ruimte in een volgend blok; een lopende ronde blijft staan tot er weer ruimte is of `interval` na de
     *         laatste run verstrijkt, waarna een nieuwe ronde begint. Een deel tussen MIN_TRADE_FLOOR en
     *         minTradeEurc mag wel: minTradeEurc geldt voor de correctie, de vloer voor elke run.
     *      5. Begrenzen op saldo en allowance. Moet dat de run onder min(run, minTradeEurc) brengen -> niets.
     *      6. Was de liquiditeit de grens (run < correctie) en niet saldo of allowance, dan loopt de ronde door met
     *         budget − verhandelde waarde, mits dat restant nog minstens minTradeEurc is.
     */
    function _plan(
        address owner,
        Params memory p,
        uint256 price,
        bool chunk,
        Window memory w1,
        Window memory w2,
        RunCaps memory caps
    ) internal view returns (Plan memory pl) {
        uint256 cash = EURC.balanceOf(owner);
        uint256 btcBal = CBBTC.balanceOf(owner);
        uint256 position = Math.mulDiv(btcBal, price, CBBTC_UNIT);
        pl.total = cash + position;
        if (pl.total == 0) {
            return pl;
        }

        uint256 fractionWad = Math.mulDiv(position, WAD, pl.total);
        uint256 targetWad = uint256(p.targetBps) * WAD / BPS;
        uint256 bandWad = uint256(p.bandBps) * WAD / BPS;
        pl.fractionBps = fractionWad * BPS / WAD;

        pl.isBuy = fractionWad < targetWad;
        uint256 driftWad = pl.isBuy ? targetWad - fractionWad : fractionWad - targetWad;
        if (driftWad <= bandWad) {
            return pl;
        }

        uint256 budget;
        if (chunk) {
            Round memory rd = rounds[owner];
            if (rd.isBuy != pl.isBuy) return pl;
            budget = rd.remainingEurc;
        } else {
            budget = Math.max(Math.mulDiv(pl.total, p.maxCorrectionBps, BPS), p.minTradeEurc);
        }
        uint256 correction = Math.min(Math.mulDiv(driftWad, pl.total, WAD), budget);
        if (correction < p.minTradeEurc) {
            return pl;
        }

        (uint256 maxRun, address binding) = _maxRunCached(pl.isBuy, price, w1, w2, caps);
        uint256 run = Math.min(correction, maxRun);
        if (run < MIN_TRADE_FLOOR) {
            pl.blockedBy = binding;
            return pl;
        }

        // De begrenzing op het saldo is defensief: run <= |drift| * total <= saldo van het input-token, dus in de
        // praktijk begrenst alleen de allowance. Blijft staan als vangnet bij latere wijzigingen.
        uint256 value;
        uint256 spent;
        if (pl.isBuy) {
            pl.amountIn = Math.min(run, Math.min(cash, EURC.allowance(owner, address(this))));
            value = pl.amountIn;
            spent = value;
        } else {
            // Naar boven afgerond: anders is de teruggerekende waarde van een run die exact op de minTrade-vloer zit
            // tot bijna 1 sat te klein en zou een kleine wallet nooit kunnen verkopen.
            uint256 wantBtc = Math.mulDiv(run, CBBTC_UNIT, price, Math.Rounding.Ceil);
            pl.amountIn = Math.min(wantBtc, Math.min(btcBal, CBBTC.allowance(owner, address(this))));
            value = Math.mulDiv(pl.amountIn, price, CBBTC_UNIT);
            spent = Math.mulDiv(pl.amountIn, price, CBBTC_UNIT, Math.Rounding.Ceil);
        }
        if (value < Math.min(run, p.minTradeEurc)) {
            pl.amountIn = 0;
            return pl;
        }

        // Doorlopen alleen als de afwijking na deze run nog buiten de band ligt. Die schatting rekent zonder fee en
        // slippage en is daardoor optimistisch: met kosten ligt de owner na de run verder van het doel. Zegt de schatting
        // "buiten de band", dan is dat dus ook zo; zegt ze "binnen", dan eindigt de ronde en wacht een kleine rest
        // op het gewone interval.
        uint256 driftEurc = Math.mulDiv(driftWad, pl.total, WAD);
        if (run < correction && value >= run && driftEurc > value + Math.mulDiv(bandWad, pl.total, WAD)) {
            uint256 left = budget > spent ? budget - spent : 0;
            if (left >= p.minTradeEurc) pl.roundLeftEurc = Math.min(left, type(uint128).max);
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
