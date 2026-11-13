#!/usr/bin/env bash
# Deploy of the Rebalancer contract to Base mainnet.
#
# Modes:
#   dry     simulates the deploy, sends nothing
#   go      deploys for real. Refuses when broadcast/ already holds a deploy, unless
#           REPLACES=<address> names the contract in that record, and when src, script,
#           lib or foundry.toml differ from HEAD
#   verify  verifies the latest broadcast on Basescan. Refuses when src, script, lib or
#           foundry.toml differ from the commit in the deploy record
#
# A deploy record that exists but cannot be read, or holds no contract address, stops
# go and verify: it is not treated as "no deploy".
#
# The treasury address comes from the environment: BITBURO_TREASURY=0x…
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

# The treasury receives every fee and alone can call retire(); it can never be changed after the deploy.
: "${BITBURO_TREASURY:?BITBURO_TREASURY is missing: set the treasury address in the environment, for example in the .env you source}"
export TREASURY="$BITBURO_TREASURY"        # the name script/Deploy.s.sol reads
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

# The address in the deploy record. Fails when the record cannot be read or holds no contract address.
deployed_address() {
  python3 -c "
import json, sys
for t in json.load(open('$BROADCAST'))['transactions']:
    if t.get('contractAddress'):
        print(t['contractAddress'])
        sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

# A record that is there but cannot be used says nothing about what is on chain, so the script stops.
unusable_record() {
  echo "$BROADCAST exists, but it cannot be read or holds no contract address." >&2
  echo "Restore the record first; this script does not guess what was deployed." >&2
  exit 1
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

# True when everything that determines the bytecode is, in this working tree, the same as in commit $1.
# A commit that is not in this clone counts as different. --ignore-submodules=none, so that a personal git setting
# (diff.ignoreSubmodules) cannot switch off the check on lib/.
same_build_inputs() { git diff --quiet --ignore-submodules=none "$1" -- src script lib foundry.toml; }

# Lower case with tr: the bash 3.2 that macOS ships has no ${x,,}.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ─── Modes ──────────────────────────────────────────────────────────────────

if [ "$MODE" = "dry" ]; then
  echo "== Dry run (nothing is sent)"
  "$FORGE" script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" "${SIGNER[@]}"
  exit 0
fi

if [ "$MODE" = "go" ]; then
  EXISTING=""
  # -L too: a symlink whose target is gone is a record that cannot be read, not "no deploy".
  if [ -e "$BROADCAST" ] || [ -L "$BROADCAST" ]; then
    EXISTING="$(deployed_address)" || unusable_record
  fi
  if [ -n "$EXISTING" ] && [ "$(lower "${REPLACES:-}")" != "$(lower "$EXISTING")" ]; then
    if [ -n "${REPLACES:-}" ]; then
      echo "REPLACES names $REPLACES, which is not the contract in the deploy record." >&2
      echo >&2
    fi
    cat >&2 <<MSG
There is already a deploy in $BROADCAST:

  address $EXISTING
  commit  $(deployed_commit)

This mode is not idempotent: running it again puts a second, separate contract on
mainnet that knows nothing about the first. The old contract keeps working: for
every wallet with a mandate, the owner or the keeper that owner appointed can
still run it, until the treasury calls retire() on it.

A new contract means: retire() on the old one, the new address in the app and in
README.md, and every user giving a new mandate to the new contract. Write down
the old address somewhere outside this machine first; the broadcast/ directory
is in .gitignore.

If that is what you want, name the contract you replace:

  REPLACES=$EXISTING bash deploy-mainnet.sh go
MSG
    exit 1
  fi

  # The deploy record names HEAD as the deployed source; verify later compares against that commit.
  if ! same_build_inputs HEAD; then
    echo "src, script, lib or foundry.toml differ from HEAD; the deploy record would then name a commit" >&2
    echo "that is not the deployed source. Commit or undo those changes first." >&2
    exit 1
  fi

  echo "== Real deploy to Base mainnet"
  [ -n "$EXISTING" ] && echo "   (replaces $EXISTING, which stays on chain and keeps working until the treasury calls retire() on it)"
  VERIFY=()
  if [ -n "$BASESCAN_API_KEY" ]; then
    VERIFY=(--verify)
  else
    echo "No BASESCAN_API_KEY: the contract will not be verified. Run 'verify' afterwards." >&2
  fi
  # The ${…+…} form, because the bash 3.2 that macOS ships treats an empty array under `set -u` as unbound.
  "$FORGE" script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" "${SIGNER[@]}" --broadcast ${VERIFY[@]+"${VERIFY[@]}"}
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

  deployed_address >/dev/null || unusable_record

  # Basescan compares the submitted source code with the bytecode on chain. That can only match
  # when everything that determines the bytecode is here as it was at the deploy.
  WANT="$(deployed_commit)"
  if ! same_build_inputs "$WANT"; then
    cat >&2 <<MSG
The deploy record names commit '$WANT'. Either that commit is not in this clone, or
src, script, lib or foundry.toml in this working tree differ from it. Verifying from
this source code submits bytecode that does not match what is on chain.

Check out that commit, or any commit that leaves those paths as they were, without
uncommitted changes in them (and run 'git submodule update' if lib differs), then
run verify again.
MSG
    exit 1
  fi

  echo "== Verifying source code on Basescan for the latest broadcast (commit $WANT)"
  "$FORGE" script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" "${SIGNER[@]}" --broadcast --resume --verify
  exit 0
fi

echo "Unknown mode '$MODE'; use 'dry', 'go' or 'verify'." >&2
exit 1
