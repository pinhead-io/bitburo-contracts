# Samples, every 6 hours over 30 days on Base: Chainlink cbBTC/USD, Chainlink BTC/USD and the Uniswap v3
# USDC/cbBTC 0.05% pool's spot price. Prints the deviations in bps.
# The measurement behind the feed choice in SCOPE.md section 4. From the repository root:
#   python3 audit/feed-vs-pool.py <head block> audit/static/feed-vs-pool-30d.json
# Needs Foundry's `cast`; the public RPC rate-limits, hence two threads and the back-off.
import json
import os
import statistics
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

CAST = os.path.expanduser("~/.foundry/bin/cast")
RPC = "https://mainnet.base.org"
CBBTC_USD = "0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D"
BTC_USD = "0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F"
POOL = "0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef"
ROUND = "latestRoundData()(uint80,int256,uint256,uint256,uint80)"

head = int(sys.argv[1])
step = 43200 // 4  # 6 hours of 2-second blocks
n = 120


def run(args):
    for i in range(8):
        r = subprocess.run(args, capture_output=True, text=True)
        if r.returncode == 0:
            return r.stdout
        time.sleep(2**i)
    raise RuntimeError(r.stderr)


def call(addr, sig, block):
    return run([CAST, "call", addr, sig, "--rpc-url", RPC, "--block", str(block)]).split("\n")


def num(s):
    return int(s.split()[0])


def sample(i):
    b = head - i * step
    cb = call(CBBTC_USD, ROUND, b)
    bt = call(BTC_USD, ROUND, b)
    s0 = call(POOL, "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)", b)
    ts = int(run([CAST, "block", str(b), "--field", "timestamp", "--rpc-url", RPC]).strip())
    sq = num(s0[0])
    pool = 1e8 * 2**192 / sq**2 / 1e6  # USD (USDC) per cbBTC; token0 = USDC (6 dec), token1 = cbBTC (8 dec)
    return dict(block=b, ts=ts, cbbtc_usd=num(cb[1]) / 1e8, btc_usd=num(bt[1]) / 1e8, pool=pool,
                cb_age=ts - num(cb[3]), bt_age=ts - num(bt[3]))


with ThreadPoolExecutor(2) as ex:
    rows = list(ex.map(sample, range(n)))
json.dump(rows, open(sys.argv[2], "w"), indent=1)


def bps(a, b):
    return (a - b) / b * 1e4


def stats(name, xs):
    a = sorted(abs(x) for x in xs)
    print(f"{name:32} median {statistics.median(xs):+7.1f}  |x| p50 {a[len(a) // 2]:6.1f}  p90 {a[int(len(a) * .9)]:6.1f}"
          f"  max {a[-1]:6.1f}  >40bp {sum(x > 40 for x in a):3d}/{len(a)}  >55bp {sum(x > 55 for x in a):3d}/{len(a)}")


print(f"{n} samples every 6 h, blocks {rows[-1]['block']}..{rows[0]['block']}")
stats("cbBTC/USD feed vs BTC/USD feed", [bps(r["cbbtc_usd"], r["btc_usd"]) for r in rows])
stats("pool vs cbBTC/USD feed", [bps(r["pool"], r["cbbtc_usd"]) for r in rows])
stats("pool vs BTC/USD feed", [bps(r["pool"], r["btc_usd"]) for r in rows])
print("max feed age (s): cbBTC/USD", max(r["cb_age"] for r in rows), " BTC/USD", max(r["bt_age"] for r in rows))
