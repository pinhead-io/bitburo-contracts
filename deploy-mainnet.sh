#!/usr/bin/env bash
# Deploy van het Rebalancer-contract naar Base mainnet.
#
# Standen:
#   dry     simuleert de deploy, verstuurt niets
#   go      deployt echt; weigert als er al een deploy in broadcast/ staat
#   verify  verifieert de laatste broadcast op Basescan
#
# Ondertekenen, bij voorkeur met een keystore zodat de sleutel niet in de procestabel belandt:
#   DEPLOYER_ACCOUNT=bitburo-deployer bash deploy-mainnet.sh dry
# Of, met de sleutel uit een .env (forge krijgt hem dan via --private-key, zichtbaar in `ps`):
#   set -a; source ~/Code/bitburo/.env; set +a; bash deploy-mainnet.sh dry
#
# Een keystore aanmaken doe je eenmalig met:
#   ~/.foundry/bin/cast wallet import bitburo-deployer --interactive
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-dry}"
FORGE="$HOME/.foundry/bin/forge"
BROADCAST="broadcast/Deploy.s.sol/8453/run-latest.json"

export TREASURY="0xD6a4f92C9c2c35B4816deC5147231226Fb7598a9"        # zelfde treasury als het huidige contract
export BASE_RPC_URL="${BASE_RPC_URL:-https://mainnet.base.org}"
export BASESCAN_API_KEY="${BASESCAN_API_KEY:-${ETHERSCAN_API_KEY:-}}"

# ─── Ondertekenen ───────────────────────────────────────────────────────────
# Een keystore heeft de voorkeur: forge vraagt dan om het wachtwoord en de sleutel
# komt nooit op de opdrachtregel, waar elk ander proces hem via `ps` kan lezen.
SIGNER=()
if [ -n "${DEPLOYER_ACCOUNT:-}" ]; then
  SIGNER=(--account "$DEPLOYER_ACCOUNT")
elif [ -n "${DEPLOYER_PRIVATE_KEY:-}" ]; then
  SIGNER=(--private-key "$DEPLOYER_PRIVATE_KEY")
  echo "Let op: de sleutel gaat via --private-key en is zichtbaar in de procestabel." >&2
  echo "       Veiliger is een keystore: cast wallet import <naam> --interactive, dan DEPLOYER_ACCOUNT=<naam>." >&2
else
  echo "Geen ondertekenaar. Zet DEPLOYER_ACCOUNT (keystore) of DEPLOYER_PRIVATE_KEY." >&2
  exit 1
fi

# ─── Hulpfuncties ───────────────────────────────────────────────────────────

# Het adres uit de laatste broadcast, of leeg als er geen deploy is vastgelegd.
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

# De commit waarvandaan de laatste broadcast is gedraaid.
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

# ─── Standen ────────────────────────────────────────────────────────────────

if [ "$MODE" = "dry" ]; then
  echo "== Droge run (er wordt niets verstuurd)"
  "$FORGE" script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" "${SIGNER[@]}"
  exit 0
fi

if [ "$MODE" = "go" ]; then
  EXISTING="$(deployed_address)"
  if [ -n "$EXISTING" ] && [ "${FORCE_REDEPLOY:-}" != "1" ]; then
    cat >&2 <<MSG
Er staat al een deploy in $BROADCAST:

  adres   $EXISTING
  commit  $(deployed_commit)

Deze stand is niet idempotent: opnieuw draaien zet een tweede, los contract op
mainnet dat niets van het eerste weet. Gebruikers houden hun allowance op het
oude adres, dat permissionless uitvoerbaar blijft.

Wil je echt een nieuw contract, dan hoort daar een plan bij (zie issue #7):
het nieuwe adres in de app, het oude in legacy_addresses, en gebruikers die
opnieuw goedkeuren. Noteer $EXISTING eerst ergens buiten deze machine; de map
broadcast/ staat in .gitignore.

Daarna: FORCE_REDEPLOY=1 bash deploy-mainnet.sh go
MSG
    exit 1
  fi

  echo "== Echte deploy naar Base mainnet"
  [ -n "$EXISTING" ] && echo "   (FORCE_REDEPLOY=1; het bestaande $EXISTING blijft gewoon op de keten staan)"
  VERIFY=()
  if [ -n "$BASESCAN_API_KEY" ]; then
    VERIFY=(--verify)
  else
    echo "Geen BASESCAN_API_KEY: het contract wordt niet geverifieerd. Draai daarna 'verify'." >&2
  fi
  "$FORGE" script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" "${SIGNER[@]}" --broadcast "${VERIFY[@]}"
  echo
  echo "Klaar. Adres: $(deployed_address), vanaf commit $(deployed_commit)."
  echo "Noteer dat adres in README.md en in de app; broadcast/ staat in .gitignore."
  exit 0
fi

if [ "$MODE" = "verify" ]; then
  if [ -z "$BASESCAN_API_KEY" ]; then
    echo "Geen ETHERSCAN_API_KEY/BASESCAN_API_KEY geladen." >&2
    exit 1
  fi
  if [ ! -f "$BROADCAST" ]; then
    echo "Geen broadcast gevonden op $BROADCAST; er valt niets te verifiëren." >&2
    exit 1
  fi

  # Basescan vergelijkt de aangeboden broncode met de bytecode op de keten. Compileren
  # we een andere commit dan die is uitgerold, dan kan die vergelijking niet kloppen.
  WANT="$(deployed_commit)"
  HAVE="$(git rev-parse --short HEAD 2>/dev/null || echo onbekend)"
  if [ -n "$WANT" ] && [ "${WANT#"$HAVE"}" = "$WANT" ] && [ "${HAVE#"$WANT"}" = "$HAVE" ]; then
    cat >&2 <<MSG
De broadcast is van commit $WANT, maar je staat op $HAVE. Verifiëren vanaf deze
broncode biedt bytecode aan die niet matcht met wat er op de keten staat.

Check eerst de juiste commit uit:

  git stash        # als je werk hebt liggen
  git checkout $WANT
  bash deploy-mainnet.sh verify
MSG
    exit 1
  fi
  if [ -n "$(git status --porcelain src/ script/ 2>/dev/null)" ]; then
    echo "src/ of script/ heeft ongecommitte wijzigingen; de bytecode wijkt dan af van de deploy." >&2
    exit 1
  fi

  echo "== Broncode verifiëren op Basescan voor de laatste broadcast (commit $WANT)"
  "$FORGE" script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" "${SIGNER[@]}" --broadcast --resume --verify
  exit 0
fi

echo "Onbekende stand '$MODE'; gebruik 'dry', 'go' of 'verify'." >&2
exit 1
