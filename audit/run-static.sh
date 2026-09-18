#!/usr/bin/env bash
# Deterministic audit steps: compiler bugs, forge tests, deep invariants, Slither and Aderyn.
# The AI reviews and the report are done by the /contract-audit skill; this script provides the raw output.
#
# Usage (from the repo root):
#   bash audit/run-static.sh                 # writes to audit/static/, the output for the current code
#   bash audit/run-static.sh /tmp/static     # writes elsewhere, e.g. to compare with the committed run
#   INVARIANT_RUNS=1000 INVARIANT_DEPTH=100 SKIP_FORK=1 bash audit/run-static.sh
#
# Requires: Foundry (~/.foundry/bin), slither, aderyn, gh (for the compiler bug list).
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"

OUT="${1:-audit/static}"
INVARIANT_RUNS="${INVARIANT_RUNS:-1000}"
INVARIANT_DEPTH="${INVARIANT_DEPTH:-100}"
# `forge` on the PATH may be Laravel Forge; put Foundry explicitly first.
export PATH="$HOME/.foundry/bin:$PATH"

mkdir -p "$OUT"
status=0

step() { printf '\n==> %s\n' "$1"; }
fail() { printf '    ERROR: %s\n' "$1"; status=1; }

for tool in forge slither aderyn gh python3; do
  command -v "$tool" >/dev/null || { echo "Missing: $tool"; exit 1; }
done

step "Versions"
{
  echo "commit: $(git rev-parse --short HEAD) ($(git branch --show-current))"
  echo "run at: $(date '+%F %T %Z')"
  # Fork tests without a fixed block give different numbers per run; set FORK_BLOCK for a repeatable measurement.
  echo "FORK_BLOCK: ${FORK_BLOCK:-latest}"
  forge --version | head -1
  echo "slither $(slither --version)"
  aderyn --version
} | tee "$OUT/versions.txt"

SOLC=$(sed -nE 's/^solc_version *= *"([0-9.]+)".*/\1/p' foundry.toml | head -1)
VIA_IR=$(sed -nE 's/^via_ir *= *(true|false).*/\1/p' foundry.toml | head -1)
EVM=$(sed -nE 's/^evm_version *= *"([a-z]+)".*/\1/p' foundry.toml | head -1)

step "Known compiler bugs for solc $SOLC (via_ir=${VIA_IR:-false}, evm=${EVM:-default})"
if gh api repos/argotorg/solidity/contents/docs/bugs_by_version.json --jq .content | base64 -d > "$OUT/.bugs_by_version.json" \
  && gh api repos/argotorg/solidity/contents/docs/bugs.json --jq .content | base64 -d > "$OUT/.bugs.json"; then
  python3 - "$SOLC" "$OUT/.bugs_by_version.json" "$OUT/.bugs.json" > "$OUT/compiler-bugs.txt" <<'EOF'
import json, sys
version, by_version, bugs = sys.argv[1], json.load(open(sys.argv[2])), json.load(open(sys.argv[3]))
names = by_version.get(version, {}).get("bugs", [])
if version not in by_version:
    print(f"WARNING: solc {version} is not in bugs_by_version.json; check the list manually")
print(f"solc {version}: {len(names)} known bugs (source: github.com/argotorg/solidity docs/bugs.json)")
for bug in bugs:
    if bug["name"] in names:
        print(f"- {bug['uid']} {bug['name']} [{bug['severity']}] fixed {bug.get('fixed', '?')} conditions={bug.get('conditions', {})}")
        print(f"  {bug['summary']}")
        print(f"  {bug['link']}")
EOF
  rm -f "$OUT/.bugs_by_version.json" "$OUT/.bugs.json"
  head -1 "$OUT/compiler-bugs.txt"
else
  fail "compiler bug list not retrieved"
fi

step "forge test"
if [ "${SKIP_FORK:-0}" = "1" ]; then
  FORGE_ARGS=(--no-match-contract 'Fork|Sandwich')
else
  FORGE_ARGS=()
fi
# `${arr[@]+...}`: an empty array gives "unbound variable" under `set -u` in bash 3.2 (macOS).
forge test ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} > "$OUT/forge-test.txt" 2>&1 || fail "forge test fails, see $OUT/forge-test.txt"
grep -E '^Ran [0-9]+ test suites?' "$OUT/forge-test.txt" || true

step "Invariants deep ($INVARIANT_RUNS runs x depth $INVARIANT_DEPTH)"
FOUNDRY_INVARIANT_RUNS="$INVARIANT_RUNS" FOUNDRY_INVARIANT_DEPTH="$INVARIANT_DEPTH" \
  forge test --match-test '^invariant_' > "$OUT/invariants.txt" 2>&1 || fail "invariants fail, see $OUT/invariants.txt"
grep -E '^Ran [0-9]+ test suites?' "$OUT/invariants.txt" || true

step "Slither"
slither . --compile-force-framework foundry --filter-paths '(lib|test|script)/' \
  --json "$OUT/slither.json" > "$OUT/slither.txt" 2>&1
# Slither exits with a non-zero exit code as soon as there are findings; only a missing result is an error.
grep -E 'analyzed .* result' "$OUT/slither.txt" || fail "Slither gave no result, see $OUT/slither.txt"

step "Aderyn"
aderyn . -i src -o "$OUT/aderyn.md" > "$OUT/aderyn-run.log" 2>&1 || fail "Aderyn fails, see $OUT/aderyn-run.log"
sed -n '/^## Issue Summary/,/^# /p' "$OUT/aderyn.md" | grep -E '^\| (High|Low)' || true

step "Done: $OUT"
exit $status
