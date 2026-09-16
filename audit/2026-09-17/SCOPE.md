# Rebalancer: scope for the external audit

Prepared 17 September 2026. Companion file: [`FINDINGS-STATUS.md`](FINDINGS-STATUS.md) lists every finding from the internal reviews and its status.

Internal reports referenced below are in Dutch: `audit/2026-09-15/RAPPORT.md` (+ `details/`), `audit/2026-09-16/ai-audit.md`, the description of PR #18, and the `README.md`. Code comments (NatSpec) in `src/` are also in Dutch. Everything a reviewer needs to reason about the contract is summarised here in English; where a number comes from a measurement that is not reproducible from this repository, this is stated.

---

## 1. What is in scope

### 1.1 Audit version

| | |
|---|---|
| Repository | `pinheadio/bitburo-contracts` |
| Branch | `fix/contract-twap-and-lows` (PR #18) |
| **Commit of the audited code** | **`579f7632ac48880611d58f1bc72e8ccd8ef178e6`** (`579f763`) |
| Note | The commit that adds this `audit/2026-09-17/` folder changes documentation only. `src/`, `script/`, `test/` and `keeper/` are byte-identical to `579f763`. |

### 1.2 Files and size

nSLOC method: counted with a small script (no `cloc` installed): block comments `/* … */` removed, then `//` line comments removed, then every remaining non-blank line counted. NatSpec (`///`, `/** */`) is therefore excluded. Blank lines excluded. Lines that contain only a brace count as code.

| File | Lines | nSLOC | In scope |
|---|---|---|---|
| `src/Rebalancer.sol` | 1,025 | 607 | **yes, primary** |
| `src/libraries/TickMath.sol` | 99 | 44 | yes (only `getSqrtPriceAtTick`, copied from Uniswap v4-core `46c6834`, MIT) |
| `src/interfaces/IUniswapV3Pool.sol` | 60 | 37 | yes (self-written minimal interface) |
| `src/interfaces/IV3SwapRouter.sol` | 21 | 11 | yes |
| `src/interfaces/IAggregatorV3.sol` | 12 | 9 | yes |
| `src/interfaces/IUniswapV3Factory.sol` | 10 | 4 | yes |
| **Total `src/`** | **1,227** | **712** | |
| `script/Deploy.s.sol` | 57 | 35 | yes (constructor arguments; addresses verified in §1.5) |
| `keeper/keeper.ts` | 996 | 756 | optional: reference keeper, not deployed on-chain |
| `keeper/selection.ts` | 723 | 378 | optional: pure logic used by `keeper.ts` |

Runtime bytecode of `Rebalancer`: 17,551 bytes (`forge build --sizes`, margin 7,025 to the 24,576 limit).

### 1.3 Compiler and settings (`foundry.toml`)

| Setting | Value |
|---|---|
| solc | `0.8.37` (pragma pinned in every `src/` file) |
| `via_ir` | `true` |
| optimizer | `true`, `optimizer_runs = 1000` |
| `evm_version` | `cancun` |
| OpenZeppelin Contracts | `v5.6.1`, submodule commit `5fd1781b1454fd1ef8e722282f86f9293cacf256` (`foundry.lock`). Used: `IERC20`, `IERC20Metadata`, `SafeERC20` (incl. `trySafeTransfer`), `ReentrancyGuardTransient`, `Math` |
| forge-std | `1.16.2` (vendored in `lib/forge-std`, tests only) |
| Foundry used for this package | `forge 1.5.1-stable` (`b0a9dd9`) |

### 1.4 Chain

Base mainnet, chain id 8453 (`script/Deploy.s.sol:35` refuses any other chain). Block time 2 s; blocks are built in 200 ms Flashblocks ordered by priority fee (docs.base.org, "Block building", read 16 Sept 2026).

### 1.5 External dependencies, verified on-chain

All values read with `cast call` (read-only) against `https://mainnet.base.org` at **block 51,406,458** (timestamp 1789602263), 17 Sept 2026.

| Role | Address | Verified on-chain |
|---|---|---|
| EURC (token, 6 dec) | `0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42` | `symbol()` "EURC", `decimals()` 6 |
| cbBTC (token, 8 dec) | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | "cbBTC", 8 |
| USDC (intermediate hop, 6 dec) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | "USDC", 6 |
| Uniswap SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` | code size 24,497; `factory()` = factory below |
| Uniswap v3 factory | `0x33128a8fC17869897dcE68Ed026d694621f6FDfD` | `feeAmountTickSpacing(500)` = 10 |
| Pool EURC/USDC 0.05% | `0x7279c08A36333e12c3Fc81747963264c100D66fB` | token0 EURC, token1 USDC, fee 500, tickSpacing 10, `getPool(EURC,USDC,500)` = this pool; `slot0`: observationCardinality 200, `feeProtocol` 68 |
| Pool USDC/cbBTC 0.05% | `0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef` | token0 USDC, token1 cbBTC, fee 500, tickSpacing 10, `getPool(USDC,cbBTC,500)` = this pool; observationCardinality 2000, `feeProtocol` 68 |
| Chainlink cbBTC/USD | `0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D` | "cbBTC / USD", 8 dec, aggregator `0x51cE3091Cf646587E02Cad83b580992f8723e718`; last update 346 s before the block |
| Chainlink EURC/USD (Standard proxy) | `0x9867186e52d2F1C2c565CDA6E747101Fa56501e0` | "EURC / USD", 8 dec, aggregator `0x042fc0bA0684eDE99b751b0931B6D1F590758994`; last update 1,628 s before the block |
| (not used) EURC/USD SVR proxy | `0x8a55b7aB579321Eb1adb54Bc770308EA0378E287` | same aggregator `0x042f…8994` |
| Chainlink L2 Sequencer Uptime | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` | "L2 Sequencer Uptime Status Feed", answer 0 (up), startedAt 1782491507 |
| Treasury (constructor arg) | `0xD6a4f92C9c2c35B4816deC5147231226Fb7598a9` | `deploy-mainnet.sh:23`; **code size 0 (EOA)**; equals `TREASURY()` of the live contract |
| Keeper only: Chainlink ETH/USD | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` | "ETH / USD", 8 dec (used by `keeper.ts` for the tip cap) |

`feeProtocol` 68 = 0x44: 1/4 of the LP fee goes to Uniswap on both tokens of both pools. This matters for §3.3.

The constructor re-checks most of this at deploy time (`src/Rebalancer.sol:283-326`): non-zero and contract code for every address, pool tokens, pool fee 500, tickSpacing 10, pool == `factory.getPool(a, b, 500)` of `ROUTER.factory()`, feed decimals 8, token decimals 6/8/6.

### 1.6 Out of scope

- **The live contract `0xE577D68948883FDF8e2694e38dF656D2D9CA2104`** (deployed from commit `f8a6d49`, block 51,341,661). It predates `retire()` (verified: `retired()` reverts at block 51,406,458) and still contains the removed Chainlink CRE surface (`onReport`). It has one registered owner (`ownerCount()` = 1). The audit is for the next deployment from the audited commit.
- The Bitburo Laravel app (`pinheadio/bitburo`), including its keeper command `bitburo:run-keeper`, and the Privy wallet/policy integration.
- Uniswap v3, Chainlink and the token contracts themselves (trusted, see §2.3).
- `test/`, `test/mocks/`, `audit/`, `deploy-mainnet.sh` (useful context, not audit targets).

---

## 2. System overview and trust model

### 2.1 What the contract does

A user (owner) gives the `Rebalancer` an ERC-20 allowance on EURC and cbBTC and calls `setParams` with a target cbBTC share, a band, a per-round cap, a minimum trade, an interval and a slippage limit. Funds stay in the owner's wallet. When the owner's cbBTC share drifts outside the band, anyone may call `execute(owner, rewardTo)`. The contract then pulls the input token from the owner, swaps EURC ⇄ cbBTC via SwapRouter02 over the fixed path EURC →(0.05%)→ USDC →(0.05%)→ cbBTC, sends the output to the owner, and takes a fee of 25 bps in EURC. Of that fee, up to 0.05 EURC goes to `rewardTo` and the rest to the treasury. The contract never holds a balance between transactions.

The sizing rule mirrors the app's `AutoTradeStrategy::rebalanceAmount` (`src/Rebalancer.sol:22-25`, `_plan` at `:864-942`). Large corrections are split into chunks ("rounds", §4.4) because each run is limited by pool liquidity (§4.3).

### 2.2 Roles

| Actor | Can | Cannot |
|---|---|---|
| **Owner** (any address) | `setParams` for itself only (`:367-384`); revoke by `setParams(active=false)` and/or `approve(0)` | change anyone else's params |
| **Caller of `execute`** (anyone) | choose **when** (block, position in block, via priority fee), **which** due owner, **`rewardTo`**; manipulate pool state before the call (see §3.3 for what the block check leaves), donate tokens to the owner, call several owners in one block | choose amount, direction, route, pools, `amountOutMinimum`, fee or reward amount; run an owner who is not due |
| **Anyone** | `sweep(token)`: sends the contract's full balance of `token` to the treasury (`:564-567`) | send it anywhere else |
| **Treasury** | receive fees; `retire()` once (`:582-587`) | touch funds, params or allowances; undo `retire` |
| **Deployer** | nothing after deployment | — |

There is **no admin, no owner, no upgrade path, no pause**. All configuration is immutable or constant. The only mutable global flag is `retired`, settable once by `TREASURY`.

`retire()` effects: `execute` reverts `ContractRetired` (`:521`); `isDue` returns `(false, 0)` (`:416`); `dueOwners` returns `[]` (`:445`); `setParams` only accepts `active = false` (`:368`); `sweep` keeps working. The treasury is an EOA (§1.5), so compromise of that key allows a permanent shutdown (liveness) but no movement of user funds.

### 2.3 Trusted external components

Uniswap v3 core pools and factory, SwapRouter02, the three Chainlink feeds, Circle (EURC, USDC; both can blacklist/pause) and Coinbase (cbBTC). Uniswap governance can change `feeProtocol`; this changes one bound in §3.3 and is explicitly considered there.

### 2.4 Off-chain keepers

Two keepers call `execute`: the Bitburo app keeper (out of scope; runs hourly, sends via a sponsored Privy transaction) and the open script in `keeper/` (optional scope; anyone can run it with an own key). The contract does not depend on either for safety, only for liveness.

---

## 3. Core invariants and security requirements

Test files: `test/Rebalancer.t.sol` (unit, fuzz, invariants, mocks), `test/BlockWindow.t.sol` (unit, block window, sizing, rounds), `test/AuditMath.t.sol` (fuzz/PoC for arithmetic), fork suites `test/BlockWindowFork.t.sol`, `test/BlockWindowReviewFork.t.sol`, `test/OracleSandwich.t.sol`, `test/OracleLagSandwich.t.sol`, `test/RebalancerFork.t.sol`, `test/PocFork.t.sol`.

### 3.1 Fee and accounting

- Fee = 25 bps of the EURC leg. Buy: of the gross EURC input. Sell: of `max(received, expectedOut)` capped at `received` (`_takeFee` `:1013-1024`, `_sell` `:999`). `reward = min(0.05 EURC, fee)`; `reward + toTreasury + retained == fee`. Failed transfers never revert the run: a failed reward goes to the treasury, a failed treasury transfer stays in the contract (`FeeRetained`) and is sweepable.
- Every run is at least `MIN_TRADE_FLOOR` = 20 EURC, so the fee always covers the full keeper reward, for buys and sells (`:131-138`).
- The contract holds no balance after any call.
- Tests: `test_execute_buy_exactAmounts`, `test_execute_sell_exactAmounts`, `test_execute_sellFeeFloorUsesExpectedOut`, `test_takeFee_cappedAtMaxFee`, `test_execute_rewardCappedByFee`, `test_execute_rewardToSelfGoesToTreasury`, `test_execute_rewardFallsBackToTreasuryWhenRewardToBlacklisted`, `test_execute_continuesWhenTreasuryBlacklistedAndSweepRecoversFee`, `testFuzz_audit_corridorFeeResidue`, `testFuzz_planBoundedAndAccountingClosed`; invariants `invariant_contractNeverHoldsBalance`, `invariant_treasuryMonotonic`, `invariant_ownerBalancesOnlyMoveThroughExecute`.

### 3.2 Loss bound per run

- Worst-case loss of a run versus the Chainlink price is `FEE_BPS + maxSlippageBps` (0.85 % – 1.25 %), because `amountOutMinimum` is derived from the oracle and `maxSlippageBps` (`:957-958`, `:983-984`), and the pool spot must be within `MAX_SPOT_DEVIATION_BPS` = 50 bps of the oracle before and after the swap (`:532`, `:970`, `:997`).
- `MIN_SLIPPAGE_BPS` = 60 = 50 bps spot tolerance + 2 × 5 bps pool fee, so a run that passes the spot check does not structurally fail on "Too little received" (`:125-129`).
- Tests: `testFuzz_poc_lossPerRunBoundedByFeePlusSlippage`, `test_fork_lossPerRunBoundedUnderSpotPush`, `test_execute_revertsOnSlippageBuy`, `test_execute_revertsOnSlippageSell`, `test_execute_minSlippageCoversSpotDeviationPlusPoolFees`, `test_execute_revertsWhenSpotDeviatesAfterSwap`.

### 3.3 Self-sandwich bounds (the caller sandwiching the run it triggers)

Requirement, as accepted by the project owner, expressed as the attacker's **extra** profit versus the same setup without the push, in bps of the run:

| Attacker | Bound | Tests |
|---|---|---|
| No LP position | **≤ 0** | `test_fork_attackGrid_buy`, `test_fork_attackGrid_sell`, `test_fork_twoOwnersSameBlockAfterOnePush`, `test_scenario_pushWithoutLp_noProfit`, `test_scenario_twoOwnersOneBlock_pushOnly`, `test_poc_selfSandwich_10k_slippage100`, `test_poc_selfSandwich_10k_slippage60`, `test_poc_selfSandwich_1k_slippage100`, `OracleLagSandwichTest` (`test_poc_noLag_*`, `test_poc_lag30_*`, cbBTC/USD feed 0.3 % stale-high) |
| Large LP share, **current** Uniswap protocol fee (`feeProtocol` 68) | **< 0.5 bp** | `test_fork_lpAttackerProfitAtCurrentProtocolFee`, `test_scenario_lpPriorBlock_currentProtocolFee_belowHalfBp`, `test_scenario_lpNearCapacity_currentProtocolFee_belowHalfBp`, `test_scenario_jitOutOfRange_currentProtocolFee` |
| Large LP share, protocol fee **0** (forced in the fork) | **< 2 bp** (~1 tick per pushed pool) | `test_scenario_lpPriorBlock_protocolFeeOff_belowTwoBp_pushEurcPool`, `test_scenario_lpPriorBlock_protocolFeeOff_belowTwoBp_pushBothPools`, `test_scenario_lpNearCapacity_protocolFeeOff_belowTwoBp`, `test_scenario_jitOutOfRange_protocolFeeOff`, `test_scenario_twoOwnersOneBlock_lpPriorBlock_pushBothPools_protocolFeeOff` |
| Push, then JIT liquidity in range, same block | **refused** (`PoolTouchedThisBlock`) | `test_review_pushThenJit_refused`, `test_review_pushThenJit_fiveOwnersRefused`, `test_scenario_twoOwnersOneBlock_jitRefused` |

Measured maxima (from the README tables; they move with pool state per block): current protocol fee +0.18 bp (block 51,402,700, 95 % LP share, 10,000 EURC buy); around window capacity −1.66 to −2.70 bp. Protocol fee 0: up to +1.95 bp (block 51,390,800, 99.9 % share in both pools, run just below capacity).

**Why these bounds hold (derivation to review).**

1. *Block check* (`_window` `:681-701`, `:684`). A run proceeds only if neither pool wrote an oracle observation in the current block: `observations[slot0.observationIndex].blockTimestamp != block.timestamp`. In Uniswap v3-core (`d8b1c635`) exactly two actions write an observation: a swap that changes the tick (`UniswapV3Pool.sol:732-748`) and a mint/burn with non-zero liquidity whose range contains the current tick (`_modifyPosition`, `:327`, `:336-348`); at most one write per block (`Oracle.sol:90`). Swaps within the tick, out-of-range mint/burn, zero burns, `collect` and `flash` write nothing. Confirmed per action on a fork: `test_observationSemantics_perAction`. Consequence: in the block of the run, tick and in-range liquidity are still those at block start, so `slot0.tick` is the block-start tick.
2. *Tick granularity.* A push that does not change the tick is invisible. With tick base 1.0001, one tick ≈ 1 bp of price, so a victim can trade up to ~1 tick worse **per pushed pool** (two pools: ~2 bp).
3. *Push cost.* The push crosses the attacker's own and others' liquidity and pays the 5 bps pool fee on the way in and out. An attacker without an LP position loses those fees and gains at most the in-tick move → no profit. An attacker holding share φ of active liquidity (minted in an earlier block; minting in the run's block is refused) gets back φ × (1 − protocol share) of the fee on his own push. With `feeProtocol` 68 the protocol keeps 1/4 even at φ → 1, which keeps the extra profit measured below 0.5 bp. With protocol fee 0 and φ → 1 the push is almost free, and the bound becomes the tick granularity: ~1 tick per pool, < 2 bp in total. Profit is relatively highest for runs just below window capacity, where the push is small relative to the run's own impact; `test_scenario_lpNearCapacity_*` covers that region.
4. *Window* (`:694-700`). In addition, before and after the swap each pool's sqrtPrice must stay within `MAX_BLOCK_MOVE_BPS` = 6 bps of the block-start tick, including the run's own impact (`_requireWithinWindow` at `:555-556`). Because only the tick (not the exact in-tick price) is known, the lower bound is computed from P(t+1)·√(1 − 6 bp) and the upper bound from P(t)·√(1 + 6 bp); all rounding (TickMath, `Math.sqrt`, `mulDiv`) narrows the window. This costs honest runs up to 1 bp of room and never gives an attacker room. 6 bps < 2 × pool fee, so each pushed unit loses money for a non-LP. Tests: `testFuzz_window_conservativeAndTight`, `test_window_extremeTicksDoNotOverflow`, `testFuzz_window_observationThisBlockMeansTouched`, `test_execute_pushWithinTickAllowed_pushOverTickRefused`, `test_execute_revertsBlockMoveExceededAfterSwap`.

### 3.4 Rounds (chunked corrections)

- A round opens only when liquidity (not balance or allowance) bounded the run and the estimated drift after the run is still outside the band (`:938-941`).
- Round budget = `max(total × maxCorrectionBps, minTradeEurc)` fixed at the first run; all chunks together never exceed it, also after a donation to the owner.
- A chunk only runs in the round's direction, only after `CHUNK_INTERVAL` (10 min), and only while `remainingEurc > 0` (`_timing` `:505-511`, `_plan` `:893-896`). A direction change never starts a chunk.
- `setParams` deletes the round (`:378`). After `interval` a fresh round replaces a stale one.
- Every chunk is ≥ `MIN_TRADE_FLOOR`; a chunk may be below the owner's `minTradeEurc` (`:856-859`).
- Tests: invariants `invariant_roundBudgetNeverExceeded`, `invariant_chunkKeepsRoundDirection`; unit `test_chunk_nextOnlyAfterChunkInterval`, `test_chunk_runsUntilWithinBand`, `test_chunk_budgetCapsRound`, `test_chunk_tailBelowMinTradeEndsRound`, `test_chunk_allowanceBoundRunOpensNoRound`, `test_chunk_directionChangeNeverStartsChunk`, `test_setParams_abortsRound`, `test_chunk_belowFloorWaitsAndKeepsRound`, `test_chunk_smallerThanUserMinTradeButAboveFloor`, `test_chunk_donationDoesNotGrowRoundBudget`, `test_chunk_freshRoundAfterIntervalReplacesStaleRound`, `test_chunk_roundEndsWhenRunReachesBand`, `test_plan_buyBoundedByLiquidityOpensRound`, `test_plan_sellBoundedByLiquidityOpensRound`; fork `test_fork_honestCorrectionInChunks_buy`, `test_fork_honestCorrectionInChunks_sell`.

### 3.5 `MIN_BAND_BPS` = 125

`bandBps` must be ≥ `FEE_BPS + MAX_SLIPPAGE_BPS` = 125 (`:155-160`, check `:371`). A run only happens when the deviation exceeds what a run can cost, so a permissionless caller cannot make a wallet churn on small price moves without improving its allocation, and a full correction finishes in one run (the residual from fee + slippage stays inside the band). Tests: `test_setParams_minBandBps`, `test_poc_sellOvershootTailRuns`, `testFuzz_audit_noPingPongConstantPrice`, `testFuzz_setParamsValidation`.

### 3.6 Views are isomorphic to `execute`

`isDue(owner)` and `dueOwners(offset, limit)` return exactly the owners and amounts that `execute` would trade now: same `_timing`, `_windows`, `_plan` (`:414-433`, `:443-481`, `_dueAt` `:483-500`). `eurcDelta` is derived from the bounded `amountIn` (`:497`). `dueOwners` caches the direction-dependent run cap per page (`RunCaps`, `:710-740`); `isDue` and `execute` pass an empty cache. Tests: `testFuzz_dueOwners_matchesIsDuePerOwner`, `test_dueOwners_filtersAndPaginatesLikeIsDue`, `test_isDue_deltaIsAllowanceBoundedAmount`, `test_isDue_deltaMatchesExecutedAmountWhenAllowanceBinds`, `testFuzz_isDue_matchesCorrectionAtAnyPrice`, `test_review_liquidityCliff_isDueAgreesWithExecute`, `test_fork_dueOwnersGasPerPage`, `test_poolTouchedThisBlock_revertsAndNotDue`.

### 3.7 Views never revert

`isDue`, `dueOwners` and `owners` must never revert for real pools and feeds: feed, sequencer or spot failures go through `try this.quoteChecked()` (`_tryQuote` `:814-820`) and return "not due"; large `limit` values do not overflow (`:396`, `:457`); extreme ticks give an empty window instead of a TickMath revert (`:690-693`); `_convert` uses `ratioX128` so it never divides by zero (`:639-642`). Tests: `test_isDue_falseOnFeedFailureNeverReverts`, `test_dueOwners_emptyOnFeedFailureNeverReverts`, `test_owners_andDueOwners_maxLimitNeverOverflows`, `test_spot_extremeSqrtPriceNeverPanicsInViews`, `test_spot_smallSqrtPriceDoesNotDivideByZero`, `test_window_extremeTicksDoNotOverflow`, `test_retire_isDueFalseAndDueOwnersEmpty`.

### 3.8 Other requirements

- Only the owner changes its params; inactive params are still validated: `test_setParams_*`, `testFuzz_setParamsValidation`.
- `execute` fails only for known reasons (no unexpected router slippage): `invariant_executeFailsOnlyForKnownReasons`.
- `retire`: `test_retire_revertsForNonTreasury`, `test_retire_setsFlagAndEmits`, `test_retire_secondCallReverts`, `test_retire_executeReverts`, `test_retire_executeRevertsForEveryOwner`, `test_retire_setParamsCanOnlyDeactivate`, `test_retire_sweepStillWorks`, `invariant_noExecutedAfterRetire`.
- Oracle validation (answer > 0, staleness 1,500 s / 4,500 s, no future `updatedAt`, sequencer up + 1 h grace, `startedAt != 0`): `test_execute_revertsStaleFeedCbbtc`, `test_execute_revertsStaleFeedEurc`, `test_execute_revertsStaleFeedWhenUpdatedAtInFuture`, `test_execute_revertsInvalidFeedAnswer`, `test_execute_revertsSequencerDownAnswerOne`, `test_execute_revertsSequencerDownWhenStartedAtZero`, `test_execute_revertsSequencerDownWithinGrace`, `test_fork_feedsAreFreshAndMatchConstants`, `test_fork_feedCadenceWithinMaxAge`.
- Constructor checks: `test_constructor_rejectsZeroAddress`, `test_constructor_rejectsNonContracts`, `test_constructor_rejectsFeedWithWrongDecimals`, `test_constructor_rejectsTokenWithWrongDecimals`, `test_constructor_rejectsTokenWithoutDecimals`, `test_constructor_rejectsPoolWithWrongTokens`, `test_constructor_rejectsPoolWithWrongFee`, `test_constructor_rejectsPoolWithWrongTickSpacing`, `test_constructor_rejectsPoolNotFromRouterFactory`, `test_fork_constructorChecksTokenDecimals`.
- Gas: `execute` stays below 1,000,000 gas (`test_fork_buyAndSellGasCost`).

---

## 4. Design choices and rationale

### 4.1 Strict block check (`PoolTouchedThisBlock`)

The block-start-tick mechanism is Uniswap's own (`OracleLibrary.getBlockStartingTickAndLiquidity`, `OracleSlippage` in SwapRouter02) and is used in production by Synthetix (SIP-120) and Balmy, and was recommended as a fix by yAudit (Exit10 M-6). Those compare the current tick with the block-start tick **with a tolerance**. This contract uses the strict form: any observation in the current block refuses the run. Reasons:
- It is simpler: `slot0.tick` is the block-start tick, so no derivation from two observations and no cardinality ≥ 2 requirement (the earlier derivation, `BlockStartUnknown` and the constructor cardinality check were removed in `d4573e2`).
- It also refuses in-range JIT liquidity in the run's block, which the tolerance form did not: the PR #18 review measured push-then-JIT at up to +4.40 bp of the run (+7.11 bp with two owners), versus +0.80 bp / +0.45 bp after the change (protocol fee 0, block 51,390,800).
- Cost: availability (§5.5). The measured alternatives (the PR #18 tolerance window without the strict check, and `amountOutMinimum` against the block-start price) are summarised in the PR #18 description.

### 4.2 6 bps window

Below the round-trip pool fee (2 × 5 bps), so a pushed unit loses money for a non-LP. Research on the prototype (16 Sept 2026): with a cap of 8 bps a 30 % LP share was already marginally profitable, with 6 bps from ~50 %, with 4 bps from ~80 %; smaller caps make chunks smaller. 6 bps was chosen as the trade-off. With the strict block check the LP bound is now set by tick granularity (§3.3), not by this cap.

### 4.3 Run size from liquidity, with the cliff fix

`_maxInput` (`:774-798`) computes the input that would move each pool to the window edge (Uniswap amount0/amount1 formulas, no fee, which is conservative) and uses `SIZING_BPS` = 75 % of it. It sizes with the **smallest** liquidity up to the window edge: current in-range liquidity, and beyond the next initialisable tick in the swap direction `liquidity ∓ liquidityNet` (review L-1, `a9bf550`). Because the window spans fewer than 10 ticks per direction (down: ticks t … t−5 can be crossed, up: t+1 … t+5), at most one multiple of `TICK_SPACING` = 10 is crossed, so no `tickBitmap` walk is needed; an uninitialised tick has `liquidityNet` 0. Downward the boundary is `floor(tick / 10) × 10` even when the price sits exactly on it (the pool crosses it immediately); upward the next multiple above. A boundary exactly at the window edge counts. No liquidity beyond → no run. Honest chunk on block 51,390,800: 644.7 EURC buy (boundary 1420 with `liquidityNet` 1.03e12 in the window), 781.3 EURC sell. Out-of-range liquidity can lift a cliff but never makes a run larger than in-range liquidity allows (§5.2).

### 4.4 Rounds, chunks every 10 minutes, reward per chunk

A correction that does not fit the window is executed in chunks with `CHUNK_INTERVAL` = 10 minutes between them, within one round budget (§3.4). `lastExecutedAt` moves with every chunk. Each chunk is a normal run with fee and keeper reward, because every `execute` costs the caller the same gas. Measured on the fork: an 8,000 EURC correction completes as 12 buy chunks or 8 sell chunks with arbitrage in between, without a revert. A 100,000 EURC correction takes ~146 buy chunks (more than a day at 10–20 min per chunk).

### 4.5 Chainlink spot check of 50 bps

Kept as layer 3: it bounds multi-block pushes that the block check cannot see, and anchors `amountOutMinimum`. Smaller is not possible without honest reverts: cbBTC/USD has a 0.3 % deviation threshold and EURC/USD 0.1 %. Larger would weaken the loss bound. Historical data (720 hourly samples, 30 days to 16 Sept 2026): spot vs Chainlink median 5.3 bp, p99 31.6 bp, > 50 bp in 0.14 %.

### 4.6 No TWAP

A 30-minute TWAP variant was built and measured (L-3 research, 16 Sept 2026, not in this repo): +165,267 gas per `execute`, +999 bytes runtime, 1 of 53 sampled blocks deviated > 50 bp from Chainlink (vs 0 for spot), and it widens the accepted previous-block push (§5.3) from 25/50 bp to 80 bp. It does not stop the cheapest blocking attack (§5.1). All same-block review attacks were already closed by the block check.

### 4.7 No loss budget per period

A cumulative loss budget (Enzyme-style) was considered and rejected: the per-run bound (§3.2) and the round budget already bound exposure, and an exhausted budget would stall an immutable contract. Users who want a daily cap set `interval` to a day (the cap is per round, not per day; `test_poc_capIsPerRunNotPerDay`).

### 4.8 Permissionless `execute`

Almost all audited ALM vaults (Gamma, Arrakis, Charm v1, Kamino, Steer) restrict who can rebalance. In an immutable contract without admin a whitelisted keeper address could never be replaced if its key is lost or compromised, and the keeper could sandwich too. Charm Alpha Vaults v2 is the closest permissionless precedent (TWAP-deviation check with a tolerance). The project owner chose permissionless `execute` and accepts bounded residual risks instead.

---

## 5. Known and accepted risks

Each item was accepted by the project owner. "README" refers to `README.md` at the audit commit.

### 5.1 L-3: blocking runs

- **Mechanism.** Anyone who writes an observation in a pool every block (a `burn` of 1 liquidity from an in-range position: 92,630 gas; a swap crossing one tick: 97,056 gas) makes every run in that block revert with `PoolTouchedThisBlock`, and `isDue`/`dueOwners` report nothing. The attacker earns nothing. Test: `test_poolTouchedThisBlock_revertsAndNotDue`. Pushing the spot > 50 bp from Chainlink instead costs ~16 EURC per block against arbitrage (~29,000 EURC/hour; `test_poc_dosBySpotPush`).
- **Cost.** At base fee 0.005 gwei, tip 0 and 1 ETH = 2,101 EURC (block 51,400,175): ~0.001 EURC per block, **~1.8 EURC per hour**. No contract change raises that cost without leaving the touch at gas price (measured options: TWAP, relaxed block check, second route via Aerodrome).
- **Defence in the keepers.** Read `isDue` and simulate `execute` with block overrides for the next block (number + 1, timestamp + 2 s) after a probe that the node applies them; retry every block for the whole budget (`RETRY_SECONDS` 540 s); send from an own key with an explicit priority fee (0.05 gwei) that at least doubles after a blockade, ≥ 110 % of the blocker's tip, up to 3 gwei and capped by what a run yields (`TIP_BUDGET_ETH`); random 1–59 blocks before the next send. Base orders transactions by priority fee within each 200 ms Flashblock, so the attacker must outbid in every block, the keeper only per attempt. Estimated from measured gas at 3 gwei: attacker ~1,050 EURC/hour, keeper ~15 EURC/hour extra.
- **Criterion ("L-3 is solved when…").** Measured on a Base fork at current prices, against the keeper as run in production: (1) blocking all runs for an hour costs the attacker ≥ 1,000 EURC; (2) Bitburo pays ≤ 2 % of that extra (≤ 20 EURC/hour) and nothing without an attack; (3) blocking yields no sandwich profit above §3.3; (4) honest failure rate without an attacker does not increase; (5) every due owner runs within 5 minutes after the attack. The open `keeper/` script meets this by estimate, relying on Base's sequencer ordering, which cannot be verified for production.
- **The app keeper cannot set a priority fee.** It sends through a sponsored Privy transaction (the bundler picks the fee; Privy documents no setting) and runs hourly. It does not meet criteria 1 and 5; only the open script (or an own keeper wallet) does. The next-block reading for the app keeper is in `pinheadio/bitburo` PR #149 (open).
- Documented: README "Runs tegenhouden (audit L-3)", `src/Rebalancer.sol:83-88`, `keeper/keeper.ts` header.

### 5.2 JIT out of range can enlarge a chunk up to the in-range bound

Minting just outside the range in the swap direction writes no observation. Such liquidity can lift a liquidity cliff and make a chunk larger than without it, but never larger than the in-range liquidity at block start allows, and without profit. Measured extra profit: −0.30 bp (current protocol fee) and −7.51 bp (protocol fee 0) at block 51,390,800; −0.21 bp at 51,402,700. Tests assert per run that the run stays below the in-range bound (computed with `RebalancerInRangeSizing`) and the LP bounds of §3.3: `test_scenario_jitOutOfRange_currentProtocolFee`, `test_scenario_jitOutOfRange_protocolFeeOff`. A fix that excludes this and still handles the cliff would need visibility of in-block tick changes. Documented: README "JIT buiten de range", `src/Rebalancer.sol:59-60`.

### 5.3 Push at the end of the previous block

The block check does not see a push in block N−1 followed by `execute` in block N. It is not atomic (arbitrage can act in between, and in 20,000 measured blocks EURC/USDC never ended a block more than 6.0 bp from Aerodrome), and the spot check bounds it. A two-block measurement in the L-3 research (not in this repo; assumes **no** arbitrage between the blocks; 10,000 EURC correction) gave: largest accepted push 25 bp (buy) / 50 bp (sell); no LP ≤ −18.5 bp; LP 99 % at current protocol fee ≤ −40.8 bp; **LP 99 % at protocol fee 0: +41.5 bp** (sell, push 50 bp). The victim's loss versus Chainlink stayed ≤ 79.4 bp including the 25 bp fee, inside the §3.2 bound. Documented: `src/Rebalancer.sol:53-54`, README "Niet gedekt".

### 5.4 LP with a large share when protocol fee is 0

See §3.3: < 0.5 bp at the current `feeProtocol` 68; up to ~1 tick per pushed pool (< 2 bp, measured +1.95 bp) if Uniswap governance sets the protocol fee to 0 and one party holds ~99.9 % of active liquidity in both pools (100–1,000× current liquidity). Making the in-tick push harmless would cost honest runs up to ~1 bp. Documented: `src/Rebalancer.sol:45-52`, README "Restrisico: LP met een groot aandeel".

### 5.5 Failure rates without an attacker

- Block check: measured over 2,000 blocks around 51,390,800 (logs of both pools, 80-block sample checked against `observations`): 0 % of attempts fail when the transaction is at the top of the block, 4.3 % in the middle, 7–11 % at the bottom. A keeper that simulates first pays no gas and retries next block. An `eth_call` on the latest block sees any activity in that block as a touch (363 of 2,000 blocks had activity).
- Spot check after the swap (lead 4): the run's own impact moves the combined spot by up to ~12 bp, so an honest run can fail after the swap only if the spot was already > ~38 bp off in the run's direction. 720 hourly samples over 30 days: > 38 bp in 0.69 %, > 50 bp (not due at all) in 0.14 %, peak 181 bp during a fast BTC move on 19 Aug 2026 (longest streak > 50 bp ~60 s).
- Documented: `src/Rebalancer.sol:64-68`, `:77-81`, README "Uitval".

### 5.6 Leads 4–7 and 9 from the 16 Sept self-audit

- **Lead 4** (honest runs revert on the spot check): see §5.5.
- **Lead 5** (Chainlink `dex_state_price`): see §5.9.
- **Lead 6** (no absolute min/max on feed answers): deliberate. The aggregators enforce no meaningful bounds themselves (`minAnswer` 1, `maxAnswer` 2^176 − 1 on both aggregators, read 16 Sept 2026), and a fixed bound would permanently stall this immutable contract at a real extreme price. A wrong feed only leads to a trade if both pools sit at the same wrong price. `src/Rebalancer.sol:800-803`.
- **Lead 7** (front-running `setParams` / `approve(0)`): not atomic. On Base a higher tip within the same Flashblock goes first, so someone who sees the transaction early can place one `execute` on the old parameters. Bounded: at most one run (then `interval`, or `CHUNK_INTERVAL` within a round; `setParams` aborts the round), within the old mandate's loss bound, and the caller only gains the keeper reward. `mainnet.base.org` exposes no `txpool` methods. `src/Rebalancer.sol:361-363`.
- **Lead 9** (registration spam): `setParams` needs no balance or allowance and the registry never shrinks. Registering costs ~120,000 gas via a factory (≈ $0.0017 on 16 Sept 2026). A balance requirement is bypassable and would break "configure first, deposit later", so the contract does not change. `dueOwners` skips empty owners cheaply (~13k gas each). The open keeper pre-filters the registry off-chain on active + balance + allowance (≥ 20 EURC per address), has its own search time limit and a rotating start offset (final review F-2). `src/Rebalancer.sol:364-366`.

### 5.7 Treasury blacklisted by Circle

If `TREASURY` is blacklisted on EURC, runs continue: the treasury part of the fee stays in the contract (`FeeRetained`), and `sweep(EURC)` reverts until the blacklist is lifted, because `sweep` can only send to the treasury. A blacklisted `rewardTo` falls back to the treasury. A blacklisted **owner** cannot be run (`test_execute_revertsWhenOwnerBlacklisted`); keepers put such owners on a cool-down. The treasury is an EOA (§1.5) and cannot be changed. Tests: `test_execute_continuesWhenTreasuryBlacklisted`, `test_execute_continuesWhenTreasuryBlacklistedAndSweepRecoversFee`, `test_execute_sellRetainsWholeFeeWhenTreasuryBlacklisted`, `test_poc_blacklistedTreasuryNoLongerBricksExecute`, `test_execute_revertsWhenTokenPaused`.

### 5.8 EURC depeg

EURC is the numeraire. The EURC/USD feed tracks EURC's market price, not EUR fiat. If EURC depegs while BTC is stable, `price` (EURC per cbBTC) rises, the cbBTC share rises, and the next run sells cbBTC for the depegged EURC. Oracle and pool move together, so the spot check does not intervene. This is a design consequence, not a bug; users can revoke. Test: `test_isDue_eurcDepegTurnsHoldIntoSell`. Source: `audit/2026-09-15/details/oracle.md` ORC-7.

### 5.9 Oracle `dex_state_price` and SVR

Chainlink's Reference Data Directory labels both cbBTC/USD and EURC/USD on Base as `dex_state_price` (end-of-block DEX state, weighted by volume and liquidity, with outlier and time-lag filters). Which pools and weights are used is not published, so the pools that layer 3 guards may partly be inside the feed (partial circularity). Holding such a pool off-market over several blocks would move the feed along; the spot check then sees less than the real deviation and `amountOutMinimum` follows the tainted feed. The loss bound stays `FEE_BPS + maxSlippageBps` versus the feed, not necessarily versus the market. This needs a multi-block manipulation against arbitrage, while a run is limited to a few hundred EURC by the window, so no second price source was added. EURC/USD is an SVR feed: the contract reads the **Standard** proxy `0x9867…01e0`, not the SVR proxy `0x8a55…E287`, so the MEV-Share delay does not apply; both proxies point to aggregator `0x042f…8994` (verified §1.5). Residual: in a block where the SVR private route updates the round, the Standard proxy sees it one block later (bounded by the 0.1 % EURC threshold). `src/Rebalancer.sol:69-70`, `:105-107`; README "Herkomst van de feeds (audit lead 5)".

---

## 6. Specific questions for the auditors

1. **Strict block check without production precedent.** We found no protocol that refuses on *any* observation written in the current block; others use the block-start tick with a tolerance. Please verify: (a) the claim that, on these pools, only a tick-changing swap or an in-range mint/burn with non-zero liquidity writes an observation, at most once per block, and that `observations(slot0.observationIndex)` is always the latest write (including cardinality growth and ring-buffer wrap); (b) that without an observation in the block `slot0.tick` equals the block-start tick and in-range liquidity is unchanged; (c) any action that changes in-range state in the block without writing an observation; (d) whether the resulting availability and griefing trade-off (§5.1, §5.5) has a better alternative for an immutable contract.
2. **Derivation of the LP bound** (§3.3). Is "~1 tick per pushed pool, < 2 bp total at protocol fee 0; < 0.5 bp at `feeProtocol` 68" a correct upper bound, including multi-owner blocks, sells, and runs near window capacity? Is there an ordering (e.g. out-of-range positions, burns just outside the range, flash, collect) that beats it?
3. **Arithmetic of the cliff fix** (`_maxInput` `:774-798`, `_window` `:681-701`). The boundary selection for negative ticks and ticks exactly on a multiple of 10; the claim that the window crosses at most one initialisable tick per direction; the sign of `liquidityNet` per direction; overflow of `liquidity << 96` and the `uint96` clamp; rounding direction of `lower`/`upper` and of the amount formulas; and whether `SIZING_BPS` = 75 % is enough when liquidity changes at the one boundary.
4. **Round state machine** (`_timing` `:505-511`, `_plan` `:864-942`, `execute` `:539-544`, `setParams` `:378`). Can any sequence of runs, price moves, donations, allowance changes or `setParams` calls exceed a round budget, flip direction within a round, start a chunk without a round, or keep an owner due forever? Note the documented edge: a price move that brings the owner inside the band does not close the round on-chain.
5. **Per-page refactor of `dueOwners`** (`RunCaps`, `:710-740`, `:461`). The cache assumes `_maxRunEurc` depends only on direction, `price`, the two windows and pool state, none of which vary per owner or change inside a view call. Is that assumption sound, and does `dueOwners` still return exactly the `isDue` set (§3.6)?
6. Open question from lead 5 (also asked to Chainlink): which pools and weights feed cbBTC/USD and EURC/USD on Base, and how long must a pool stay displaced before the feed follows?

---

## 7. How to build and test

### 7.1 Setup

```bash
git clone https://github.com/pinheadio/bitburo-contracts && cd bitburo-contracts
git checkout 579f7632ac48880611d58f1bc72e8ccd8ef178e6
git submodule update --init lib/openzeppelin-contracts   # forge-std is vendored
~/.foundry/bin/forge build --sizes                        # "forge" on PATH may be another tool
```

Fork tests read `BASE_RPC_URL` (default `https://mainnet.base.org`, rate-limited) and `FORK_BLOCK` (default: latest block). Pin `FORK_BLOCK=51390800` for reproducible results; the RPC must serve historical state for that block (the run below used Foundry's local RPC cache for that block). `RUN_FORK=false` skips all fork suites.

### 7.2 Commands and actual results

All results below were produced on 17 Sept 2026 on commit `579f763`.

```bash
~/.foundry/bin/forge fmt --check
FORK_BLOCK=51390800 ~/.foundry/bin/forge test
FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=100 FORK_BLOCK=51390800 ~/.foundry/bin/forge test --match-test '^invariant_'
RUN_FORK=false ~/.foundry/bin/forge test
cd keeper && bun install && bun test && bunx tsc --noEmit
```

| Command | Result |
|---|---|
| `forge fmt --check` | exit 0 |
| `forge build --sizes` | `Rebalancer` runtime 17,551 B |
| `FORK_BLOCK=51390800 forge test` | `Ran 13 test suites in 3.16s (17.94s CPU time): 211 tests passed, 0 failed, 0 skipped (211 total tests)` |
| Invariants 1000 runs × depth 100 | `Ran 2 test suites in 34.37s (68.25s CPU time): 14 tests passed, 0 failed, 0 skipped (14 total tests)`; each invariant `runs: 1000, calls: 100000` |
| `RUN_FORK=false forge test` | `Ran 13 test suites in 2.32s (6.53s CPU time): 163 tests passed, 0 failed, 8 skipped (171 total tests)` |
| `bun test` (keeper, bun 1.3.5) | `76 pass, 0 fail, 508 expect() calls`, 2 files |
| `bunx tsc --noEmit` | exit 0 |

Per suite on `FORK_BLOCK=51390800`:

| Suite | Passed |
|---|---|
| `test/Rebalancer.t.sol:RebalancerTest` | 104 |
| `test/Rebalancer.t.sol:RebalancerInvariantTest` | 7 |
| `test/Rebalancer.t.sol:RebalancerInvariantTestNoRetire` | 7 |
| `test/BlockWindow.t.sol:BlockWindowTest` | 34 |
| `test/AuditMath.t.sol:AuditMathTest` | 11 |
| `test/BlockWindowReviewFork.t.sol:BlockWindowReviewForkTest` | 16 |
| `test/RebalancerFork.t.sol:RebalancerForkTest` | 10 |
| `test/OracleSandwich.t.sol:OracleSandwichTest` | 7 |
| `test/OracleLagSandwich.t.sol:OracleLagSandwichTest` | 6 |
| `test/BlockWindowFork.t.sol:BlockWindowAttackForkTest` | 3 |
| `test/BlockWindowFork.t.sol:BlockWindowChunksForkTest` | 2 |
| `test/BlockWindowFork.t.sol:BlockWindowLpForkTest` | 2 |
| `test/PocFork.t.sol:PocFork` | 2 |
| **Total** | **211** |

The 14 invariants are the same 7 in two handler setups: `RebalancerInvariantTest` (handler may call `retire`, 1 in 8) and `RebalancerInvariantTestNoRetire` (so rounds and chunks are reached in deep runs).

Fork measurements shift with pool state per block. `FORK_BLOCK=51390800` is the reference block for this package. According to the PR #18 description, the full suite also passed on `FORK_BLOCK=51406203` (211 passed, 17 Sept 2026); that run was not repeated for this package.

Pitfall under `via_ir`: Solidity caches `block.timestamp` inside a test function; after `vm.warp` tests use `vm.getBlockTimestamp()`.
