#!/usr/bin/env bash
# Deploy van het Rebalancer-contract naar Base mainnet.
#
# Gebruik (laadt de sleutel uit de .env van bitburo, zoals bij de vorige deploy):
#   set -a; source ~/Code/bitburo/.env; set +a; bash ~/Code/bitburo-contracts/deploy-mainnet.sh dry
#   set -a; source ~/Code/bitburo/.env; set +a; bash ~/Code/bitburo-contracts/deploy-mainnet.sh go
#
# "dry" simuleert alleen, "go" deployt echt, "verify" verifieert de laatste broadcast op Basescan (ETHERSCAN_API_KEY).
#
# WAARSCHUWINGEN, lees voor je "go" of "verify" draait:
#
#   * "go" is niet idempotent. Er is geen bestaanscheck en geen salt, dus een tweede run zet een
#     tweede, los contract op mainnet en overschrijft broadcast/Deploy.s.sol/8453/run-latest.json.
#     Die map staat in .gitignore, dus dat bestand is op deze machine het enige bewijs van de
#     huidige deploy. Maak er een kopie van voor je opnieuw deployt.
#   * "verify" slaagt alleen zolang src/ ongewijzigd is sinds de deploy. De huidige broadcast is van
#     commit f8a6d49; daarna is retire() toegevoegd. Verifieren vanaf de huidige broncode biedt dus
#     bytecode aan die niet matcht. Check uit op de commit uit run-latest.json voor je verifieert.
#   * De sleutel gaat als --private-key op de opdrachtregel mee en is daarmee zichtbaar in de
#     procestabel (ps) van deze machine. Voor een deploy vanaf een gedeelde machine: gebruik
#     forge script --account <keystore> of --interactive.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-dry}"
FORGE="$HOME/.foundry/bin/forge"
export TREASURY="0xD6a4f92C9c2c35B4816deC5147231226Fb7598a9"        # zelfde treasury als het huidige contract
export WORKFLOW_OWNER="0xdeb5e5b8bDc70e8f2BBB3bACbAFA2a981ee2E7A7"  # deployer; CRE wordt voorlopig niet gebruikt
export BASE_RPC_URL="${BASE_RPC_URL:-https://mainnet.base.org}"
export BASESCAN_API_KEY="${BASESCAN_API_KEY:-}"

if [ -z "${DEPLOYER_PRIVATE_KEY:-}" ]; then
  echo "DEPLOYER_PRIVATE_KEY is niet geladen. Draai eerst: set -a; source ~/Code/bitburo/.env; set +a" >&2
  exit 1
fi

if [ "$MODE" = "dry" ]; then
  echo "== Droge run (er wordt niets verstuurd)"
  "$FORGE" script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY"
  exit 0
fi

if [ "$MODE" = "go" ]; then
  echo "== Echte deploy naar Base mainnet"
  VERIFY=""
  if [ -n "$BASESCAN_API_KEY" ]; then VERIFY="--verify"; fi
  "$FORGE" script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast $VERIFY
  echo
  echo "Klaar. Het adres staat achter 'Rebalancer:' hierboven en in broadcast/Deploy.s.sol/8453/run-latest.json."
  exit 0
fi

if [ "$MODE" = "verify" ]; then
  export BASESCAN_API_KEY="${BASESCAN_API_KEY:-${ETHERSCAN_API_KEY:-}}"
  if [ -z "$BASESCAN_API_KEY" ]; then echo "Geen ETHERSCAN_API_KEY/BASESCAN_API_KEY geladen." >&2; exit 1; fi
  echo "== Broncode verifiëren op Basescan voor de laatste broadcast"
  "$FORGE" script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast --resume --verify
  exit 0
fi

echo "Onbekende stand '$MODE'; gebruik 'dry', 'go' of 'verify'." >&2
exit 1
