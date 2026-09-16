#!/usr/bin/env bash
# Deterministische audit-stappen: compilerbugs, forge-tests, diepe invariants, Slither en Aderyn.
# De AI-reviews en het rapport doet de skill /contract-audit; dit script levert de ruwe output.
#
# Gebruik (vanuit de repo-root):
#   bash audit/run-static.sh                 # schrijft naar audit/<vandaag>/
#   bash audit/run-static.sh audit/2026-10-01
#   INVARIANT_RUNS=1000 INVARIANT_DEPTH=100 SKIP_FORK=1 bash audit/run-static.sh
#
# Vereist: Foundry (~/.foundry/bin), slither, aderyn, gh (voor de compilerbuglijst).
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

OUT="${1:-audit/$(date +%F)}"
INVARIANT_RUNS="${INVARIANT_RUNS:-1000}"
INVARIANT_DEPTH="${INVARIANT_DEPTH:-100}"
# `forge` op het PATH kan Laravel Forge zijn; Foundry expliciet voorop zetten.
export PATH="$HOME/.foundry/bin:$PATH"

mkdir -p "$OUT"
status=0

step() { printf '\n==> %s\n' "$1"; }
fail() { printf '    FOUT: %s\n' "$1"; status=1; }

for tool in forge slither aderyn gh python3; do
  command -v "$tool" >/dev/null || { echo "Ontbreekt: $tool"; exit 1; }
done

step "Versies"
{
  echo "commit: $(git rev-parse --short HEAD) ($(git branch --show-current))"
  forge --version | head -1
  echo "slither $(slither --version)"
  aderyn --version
} | tee "$OUT/versions.txt"

SOLC=$(sed -nE 's/^solc_version *= *"([0-9.]+)".*/\1/p' foundry.toml | head -1)
VIA_IR=$(sed -nE 's/^via_ir *= *(true|false).*/\1/p' foundry.toml | head -1)
EVM=$(sed -nE 's/^evm_version *= *"([a-z]+)".*/\1/p' foundry.toml | head -1)

step "Bekende compilerbugs voor solc $SOLC (via_ir=${VIA_IR:-false}, evm=${EVM:-default})"
if gh api repos/argotorg/solidity/contents/docs/bugs_by_version.json --jq .content | base64 -d > "$OUT/.bugs_by_version.json" \
  && gh api repos/argotorg/solidity/contents/docs/bugs.json --jq .content | base64 -d > "$OUT/.bugs.json"; then
  python3 - "$SOLC" "$OUT/.bugs_by_version.json" "$OUT/.bugs.json" > "$OUT/compiler-bugs.txt" <<'EOF'
import json, sys
version, by_version, bugs = sys.argv[1], json.load(open(sys.argv[2])), json.load(open(sys.argv[3]))
names = by_version.get(version, {}).get("bugs", [])
if version not in by_version:
    print(f"WAARSCHUWING: solc {version} staat niet in bugs_by_version.json; controleer de lijst handmatig")
print(f"solc {version}: {len(names)} bekende bugs (bron: github.com/argotorg/solidity docs/bugs.json)")
for bug in bugs:
    if bug["name"] in names:
        print(f"- {bug['uid']} {bug['name']} [{bug['severity']}] fixed {bug.get('fixed', '?')} conditions={bug.get('conditions', {})}")
        print(f"  {bug['summary']}")
        print(f"  {bug['link']}")
EOF
  rm -f "$OUT/.bugs_by_version.json" "$OUT/.bugs.json"
  head -1 "$OUT/compiler-bugs.txt"
else
  fail "compilerbuglijst niet opgehaald"
fi

step "forge test"
if [ "${SKIP_FORK:-0}" = "1" ]; then
  FORGE_ARGS=(--no-match-contract 'Fork|Sandwich')
else
  FORGE_ARGS=()
fi
forge test "${FORGE_ARGS[@]}" > "$OUT/forge-test.txt" 2>&1 || fail "forge test faalt, zie $OUT/forge-test.txt"
grep -E '^Ran [0-9]+ test suites?' "$OUT/forge-test.txt" || true

step "Invariants diep ($INVARIANT_RUNS runs x depth $INVARIANT_DEPTH)"
FOUNDRY_INVARIANT_RUNS="$INVARIANT_RUNS" FOUNDRY_INVARIANT_DEPTH="$INVARIANT_DEPTH" \
  forge test --match-test '^invariant_' > "$OUT/invariants.txt" 2>&1 || fail "invariants falen, zie $OUT/invariants.txt"
grep -E '^Ran [0-9]+ test suites?' "$OUT/invariants.txt" || true

step "Slither"
slither . --compile-force-framework foundry --filter-paths '(lib|test|script)/' \
  --json "$OUT/slither.json" > "$OUT/slither.txt" 2>&1
# Slither eindigt met een niet-nul exitcode zodra er meldingen zijn; alleen een ontbrekend resultaat is een fout.
grep -E 'analyzed .* result' "$OUT/slither.txt" || fail "Slither gaf geen resultaat, zie $OUT/slither.txt"

step "Aderyn"
aderyn . -i src -o "$OUT/aderyn.md" > "$OUT/aderyn-run.log" 2>&1 || fail "Aderyn faalt, zie $OUT/aderyn-run.log"
sed -n '/^## Issue Summary/,/^# /p' "$OUT/aderyn.md" | grep -E '^\| (High|Low)' || true

step "Klaar: $OUT"
exit $status
