# Triage Slither 0.11.6 + Aderyn 0.6.8 — 2026-09-17

Scope: `src/` at commit `bab2ed3` (`development`), solc 0.8.37, `via_ir = true`, `evm_version = cancun`. Raw output: `slither.txt`/`slither.json` (39 findings) and `aderyn.md` (1 High, 4 Low). Line numbers refer to `bab2ed3`.

**Result: no real bugs.** All findings are intended behavior, style or false positive.

## Slither

| Detector (impact) | Count | Location | Verdict | Reason |
|---|---|---|---|---|
| arbitrary-send-erc20 (High) | 2 | `_buy` `src/Rebalancer.sol:960`, `_sell` `:988` | intended | `execute` is permissionless, but only pulls from an owner with `params.active` (`:530`) and their own allowance. Amount, direction and recipient follow from `_plan` and the owner's params; the output always goes to `owner` (`:971`, `:1008`). The caller only chooses the moment and `rewardTo` (≤ 0.05 EURC). |
| incorrect-equality (Medium) | 5 | `:500`, `:543`, `:884`, `:976` (`== 0` on amounts), `:691` (`lastTimestamp == uint32(block.timestamp)`) | false positive | `== 0` on computed amounts, not on balances with which an attacker can break an equality. `:691` is the block check itself: equality means "observation in this block" (Base block times are unique per block; `uint32` only overflows in 2106). |
| divide-before-multiply (Medium) | 1 | `_maxInput` `:784-786` | intended | Deliberate rounding of the tick to a multiple of `TICK_SPACING`, with a correction for negative ticks (`:785`). Example: tick −5 → `−5 / 10 = 0`, remainder ≠ 0 → −1 → boundary −10 (floor). Tested in `test_cliff_negativeTickInCbbtcPool` (`test/BlockWindow.t.sol`). |
| uninitialized-local (Medium) | 4 | `caps` `:438`, `:468`, `:540`; `n` `:466` | false positive | `RunCaps caps` must start empty (empty cache, NatSpec `:726-729`); counter `n` deliberately starts at 0. |
| unused-return (Medium) | 8 | `_quote` `:600`, `_spotOut` `:641`, `_window` `:689-690`, `_requireWithinWindow` `:712`, `_maxInput` `:790`, `_readFeed` `:812`, `_sell` `:995` | intended | Unused tuple fields. `answeredInRound` is deprecated by Chainlink. `_sell` measures the proceeds via the balance difference (`:994`, `:1003`), which also correctly excludes fee left behind in the contract. |
| calls-loop (Low) | 5 | `dueOwners` → `_plan` `:880`, `:881`, `:924`, `:931`; `_maxInput` `:790` | intended | Only in the paginated view `dueOwners`; the caller chooses `limit`. `pool.ticks` is read once per direction per page (`RunCaps`, review I-2). No on-chain DoS: no state-changing function loops over owners. |
| timestamp (Low) | 4 | `_timing` `:514`, `:517`; `_quote` `:602`; `_readFeed` `:815`; `_window` `:691` | intended | Intervals of minutes to hours; on Base the sequencer sets the timestamp (2 s per block). `:691` is the block check. |
| naming-convention (Info) | 10 | immutables `:107-121` | style | Immutables in UPPER CASE are deliberate (same style as constants). |

## Aderyn

| Aderyn ID | Location | Verdict | Reason |
|---|---|---|---|
| H-1 Incorrect Assembly Shift Parameter Order (3×) | `src/libraries/TickMath.sol:64` (2×), `:95` | **false positive** | In Yul, `shl(x, y)` is "logical shift left y by x bits" and `shr(x, y)` is "logical shift right y by x bits" (`docs/yul.rst:809`, `:811` in `github.com/argotorg/solidity`, blob `f36a29e`, read 2026-09-17). So `shl(128, 1)` is `1 << 128` and `shr(32, …)` is `… >> 32`, exactly what is intended. Apart from the revert style (`revert InvalidTick(tick)` instead of `InvalidTick.selector.revertWith(tick)`), `getSqrtPriceAtTick` is identical to Uniswap v4-core commit `46c6834` (`diff -w` on 2026-09-17). Fork tests that measure the window edges against real pools are green (`forge-test.txt`). |
| L-1 Large Numeric Literal (2×) | `src/Rebalancer.sol:130`, `:177` | style | `50_000` and `10_000` are readable with separators. |
| L-2 Literal Instead of Constant (19×) | `TickMath.sol:66-84` | style | Magic numbers from the Uniswap table; copied unchanged. |
| L-3 Loop Contains `require`/`revert` (1×) | `src/Rebalancer.sol:469` (`dueOwners`) | intended | The path in the loop does not revert with real tokens and pools: feed, sequencer and spot errors are caught before the loop via `try this.quoteChecked()` (`:455`, `_tryQuote` `:821-827`), extreme ticks give an empty window (`:697-700`). Tested with `test_dueOwners_emptyOnFeedFailureNeverReverts` and `test_spot_extremeSqrtPriceNeverPanicsInViews`. |
| L-4 Unchecked Return (1×) | `src/Rebalancer.sol:995` | intended | See Slither unused-return: `_sell` measures via the balance difference. |

Compared with 2026-09-16 (30 Slither findings, 0 High / 2 Low Aderyn): the extra findings come from the new block window code (`_window`, `_maxInput`, `RunCaps`) and from `TickMath.sol`, which did not exist then.
