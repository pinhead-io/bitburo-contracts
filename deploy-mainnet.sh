#!/usr/bin/env bash
# Deploy of the Rebalancer contract to Base mainnet.
#
# Modes:
#   dry     simulates the deploy, sends nothing
#   go      deploys for real; refuses if there is already a deploy in broadcast/
#   verify  verifies the latest broadcast on Basescan
#
# Signing, preferably with a keystore so that the key does not end up in the process table:
#   DEPLOYER_ACCOUNT=bitburo-deployer bash deploy-mainnet.sh dry
# Or, with the key from a .env (forge then gets it via --private-key, visible in `ps`):
#   set -a; source ~/Code/bitburo/.env; set +a; bash deploy-mainnet.sh dry
#
# Create a keystore once with:
#   ~/.foundry/bin/cast wallet import bitburo-deployer --interactive
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-dry}"
FORGE="$HOME/.foundry/bin/forge"
BROADCAST="broadcast/Deploy.s.sol/8453/run-latest.json"

export TREASURY="0xD6a4f92C9c2c35B4816deC5147231226Fb7598a9"        # same treasury as the current contract
export BASE_RPC_URL="${BASE_RPC_URL:-https://mainnet.base.org}"
export BASESCAN_API_KEY="${BASESCAN_API_KEY:-${ETHERSCAN_API_KEY:-}}"

# ─── Signing ────────────────────────────────────────────────────────────────
# A keystore is preferred: forge then asks for the password and the key
# never appears on the command line, where any other process can read it via `ps`.
SIGNER=()
if [ -n "${DEPLOYER_ACCOUNT:-}" ]; then
  SIGNER=(--account "$DEPLOYER_ACCOUNT")
elif [ -n "${DEPLOYER_PRIVATE_KEY:-}" ]; then
  SIGNER=(--private-key "$DEPLOYER_PRIVATE_KEY")
  echo "Note: the key is passed via --private-key and is visible in the process table." >&2
  echo "      A keystore is safer: cast wallet import <name> --interactive, then DEPLOYER_ACCOUNT=<name>." >&2
else
  echo "No signer. Set DEPLOYER_ACCOUNT (keystore) or DEPLOYER_PRIVATE_KEY." >&2
  exit 1
fi

# ─── Helper functions ───────────────────────────────────────────────────────

# The address from the latest broadcast, or empty if no deploy has been recorded.
deployed_address() {
  [ -f "$BROADCAST" ] || return 0
  python3 -c "
import json, sys
try:
    d = json.load(open('$BROADCAST'))
except Exception:
    sys.exit(0)
for t in d.get('transactions', []):
    if t.get('contractAddress'):
        print(t['contractAddress'])
        break
" 2>/dev/null
}

# The commit from which the latest broadcast was run.
deployed_commit() {
  [ -f "$BROADCAST" ] || return 0
  python3 -c "
import json, sys
try:
    print(json.load(open('$BROADCAST')).get('commit') or '')
except Exception:
    sys.exit(0)
" 2>/dev/null
}

# ─── Modes ──────────────────────────────────────────────────────────────────

if [ "$MODE" = "dry" ]; then
  echo "== Dry run (nothing is sent)"
  "$FORGE" script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" "${SIGNER[@]}"
  exit 0
fi

if [ "$MODE" = "go" ]; then
  EXISTING="$(deployed_address)"
  if [ -n "$EXISTING" ] && [ "${FORCE_REDEPLOY:-}" != "1" ]; then
    cat >&2 <<MSG
There is already a deploy in $BROADCAST:

  address $EXISTING
  commit  $(deployed_commit)

This mode is not idempotent: running it again puts a second, separate contract on
mainnet that knows nothing about the first. Users keep their allowance on the
old address, which remains permissionlessly executable.

If you really want a new contract, it needs a plan (see issue #7):
the new address in the app, the old one in legacy_addresses, and users who
approve again. Write down $EXISTING somewhere outside this machine first; the
broadcast/ directory is in .gitignore.

Then: FORCE_REDEPLOY=1 bash deploy-mainnet.sh go
MSG
    exit 1
  fi

  echo "== Real deploy to Base mainnet"
  [ -n "$EXISTING" ] && echo "   (FORCE_REDEPLOY=1; the existing $EXISTING simply stays on chain)"
  VERIFY=()
  if [ -n "$BASESCAN_API_KEY" ]; then
    VERIFY=(--verify)
  else
    echo "No BASESCAN_API_KEY: the contract will not be verified. Run 'verify' afterwards." >&2
  fi
  "$FORGE" script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" "${SIGNER[@]}" --broadcast "${VERIFY[@]}"
  echo
  echo "Done. Address: $(deployed_address), from commit $(deployed_commit)."
  echo "Record that address in README.md and in the app; broadcast/ is in .gitignore."
  exit 0
fi

if [ "$MODE" = "verify" ]; then
  if [ -z "$BASESCAN_API_KEY" ]; then
    echo "No ETHERSCAN_API_KEY/BASESCAN_API_KEY loaded." >&2
    exit 1
  fi
  if [ ! -f "$BROADCAST" ]; then
    echo "No broadcast found at $BROADCAST; there is nothing to verify." >&2
    exit 1
  fi

  # Basescan compares the submitted source code with the bytecode on chain. If we compile
  # a different commit than the one that was deployed, that comparison cannot match.
  WANT="$(deployed_commit)"
  HAVE="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  if [ -n "$WANT" ] && [ "${WANT#"$HAVE"}" = "$WANT" ] && [ "${HAVE#"$WANT"}" = "$HAVE" ]; then
    cat >&2 <<MSG
The broadcast is from commit $WANT, but you are on $HAVE. Verifying from this
source code submits bytecode that does not match what is on chain.

Check out the right commit first:

  git stash        # if you have uncommitted work
  git checkout $WANT
  bash deploy-mainnet.sh verify
MSG
    exit 1
  fi
  if [ -n "$(git status --porcelain src/ script/ 2>/dev/null)" ]; then
    echo "src/ or script/ has uncommitted changes; the bytecode then differs from the deploy." >&2
    exit 1
  fi

  echo "== Verifying source code on Basescan for the latest broadcast (commit $WANT)"
  "$FORGE" script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" "${SIGNER[@]}" --broadcast --resume --verify
  exit 0
fi

echo "Unknown mode '$MODE'; use 'dry', 'go' or 'verify'." >&2
exit 1
