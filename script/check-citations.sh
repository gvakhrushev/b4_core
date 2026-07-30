#!/usr/bin/env bash
#
# Archive currency: every reference in a LIVE document must resolve against the code as it is now.
#
# Why this is a build gate and not a review habit. `Keeper.sol` cited `test/unit/GasBounds.t.sol`
# as the source of all four of its gas budgets — three separate times — and that file had never
# existed, in the tree or anywhere in git history. Four load-bearing constants therefore rested on
# numbers nothing re-derived, and one had already gone false ("cheap (<0.1M each)" against a
# measured 0.106M) with nobody noticing. A citation to something that does not exist is WORSE than
# no citation: it reads as evidence, so it actively suppresses the checking it appears to have had.
#
# Live vs historical, which is the distinction that decides whether this stays switched on:
# Every document in the tree is LIVE. The narrative audit reports that used to need a historical
# exemption were deleted when `docs/audits/REGISTRY.md` replaced them: an unmaintained document
# reads as current because nothing marks it stale, which is the failure this whole check exists to
# prevent. There is therefore no advisory tier and no exemption to argue about.
#
# Five checks, deliberately different in strictness — a checker that cries wolf gets muted, and
# this repository has already been bitten by a fuzz lane whose property "was never once evaluated".
set -uo pipefail

cd "$(dirname "$0")/.."

# The live surface, listed explicitly. No globs that could widen silently into `lib/` (vendored
# forge-std has its own tests and sources, and matching those would drown every real finding) or
# into `.git`. `docs/audits/` is deliberately absent — see the live/historical note above.
LIVE_PATHS="src spec docs/design INVARIANTS.md ARCHITECTURE.md README.md SECURITY.md"
for g in docs/*.md; do
  [ -f "$g" ] && LIVE_PATHS="$LIVE_PATHS $g"
done

# shellcheck disable=SC2086
scan() { grep -rhoE "$1" $LIVE_PATHS 2>/dev/null; }

status=0

# ------------------------------------------------------------ 1. cited .t.sol files exist
echo "== cited test files (live documents)"
cited=$(scan "[A-Za-z0-9_.]+\.t\.sol" | sort -u)
n=0
for f in $cited; do
  n=$((n + 1))
  find test -name "$f" -print -quit | grep -q . || { echo "FAIL  cited test file does not exist: $f"; status=1; }
done
[ "$status" -eq 0 ] && echo "ok    all $n cited test files resolve"

# ------------------------------------------------------------ 2. cited .sol sources exist
echo "== cited source files (live documents)"
cited_src=$(scan "src/[A-Za-z0-9_/]+\.sol" | sort -u)
m=0
for f in $cited_src; do
  m=$((m + 1))
  [ -f "$f" ] || { echo "FAIL  cited source file does not exist: $f"; status=1; }
done
echo "ok    all $m cited source paths resolve"

# ------------------------------- 3. INVARIANTS Tests column names tests that actually exist
#
# Scoped to that column on purpose: only there is a name a CLAIM OF COVERAGE. Prose legitimately
# names tests that are gone ("the old regression `test_x` no longer exists"), and flagging those
# is how a checker earns its way into someone's ignore list. Wildcards (`test_R1_*`) are coverage
# claims over a family and are matched as prefixes.
echo "== INVARIANTS traceability"
grep -rhoE "function (test|testFuzz|invariant)_[A-Za-z0-9_]+" test/ | sed 's/function //' | sort -u >/tmp/_b4_real
awk -F'|' '/^\|/ && NF >= 4 { print $4 }' INVARIANTS.md \
  | grep -oE "\b(test|testFuzz|invariant)_[A-Za-z0-9_]+\*?" | sort -u >/tmp/_b4_cited
miss=0
while read -r name; do
  [ -z "$name" ] && continue
  if [[ "$name" == *\* ]]; then
    grep -q "^${name%\*}" /tmp/_b4_real || { echo "FAIL  no test matches the family: $name"; miss=1; }
  else
    grep -qx "$name" /tmp/_b4_real || { echo "FAIL  traceability names a missing test: $name"; miss=1; }
  fi
done </tmp/_b4_cited
[ "$miss" -eq 0 ] && echo "ok    all $(wc -l </tmp/_b4_cited | tr -d ' ') tests named in the Tests column exist" || status=1

# ------------------------------------------------------ 4. cited Solidity symbols still exist
#
# The rename detector, and the reason this file covers more than filenames: `forfeitWeight` became
# `scaleWeight` in AUDIT-2026-07-29 F1, and eleven documents kept naming the old one. Renames are
# the commonest way normative text stops describing the code, and they are silent by construction.
#
# Only `functionName(` forms are checked — a backticked bare word is prose far more often than a
# symbol, and enforcing those is the cry-wolf failure again. Two exclusions, both learned by
# hitting them: `docs/design/` holds proposals for work not yet built, whose forward references
# are the point (`graduate()` belongs to the unbuilt tranche design); and the definition set spans
# `test/` too, because normative text legitimately names campaign handlers (`poolCrank()`).
# Public state variables count as definitions — Solidity generates their getters, so `oracle()`
# is real even though no `function oracle` is written anywhere.
echo "== cited Solidity symbols"
SYM_PATHS=$(echo "$LIVE_PATHS" | tr ' ' '\n' | grep -v '^docs/design$' | tr '\n' ' ')
# shellcheck disable=SC2086
grep -rhoE "\`[a-z][A-Za-z0-9_]+\(\)\`" $SYM_PATHS 2>/dev/null | tr -d '`()' | sort -u >/tmp/_b4_syms
{
  grep -rhoE "function [a-zA-Z0-9_]+" src/ test/ | sed 's/function //'
  grep -rhoE "(public|external)[a-zA-Z0-9_ ]* [a-zA-Z0-9_]+ *[;=]" src/ | grep -oE "[a-zA-Z0-9_]+ *[;=]" | tr -d ' ;='
} | sort -u >/tmp/_b4_defs
sym=0
while read -r s; do
  [ -z "$s" ] && continue
  grep -qx "$s" /tmp/_b4_defs || { echo "FAIL  live text names a function that no longer exists: ${s}()"; sym=1; }
done </tmp/_b4_syms
[ "$sym" -eq 0 ] && echo "ok    all $(wc -l </tmp/_b4_syms | tr -d ' ') cited functions exist in src/" || status=1

# -------------------------------------------- 5. every registry row's test still exists
#
# The registry replaced twelve narrative reports precisely so a finding would have ONE home, and
# its promise is the last column: a `Fixed` or `Enforced` row names the test that holds it. That
# promise is worth exactly as much as this check — without it the registry rots the way the
# reports did, just in one file instead of twelve.
echo "== registry -> test"
reg=0
grep -oE "\| [A-Za-z0-9_]+\.t\.sol" docs/audits/REGISTRY.md | sed 's/| //' | sort -u >/tmp/_b4_regtests
while read -r t; do
  [ -z "$t" ] && continue
  find test -name "$t" -print -quit | grep -q . || { echo "FAIL  registry names a test that does not exist: $t"; reg=1; }
done </tmp/_b4_regtests
[ "$reg" -eq 0 ] && echo "ok    all $(wc -l </tmp/_b4_regtests | tr -d ' ') tests named in the registry exist" || status=1

rm -f /tmp/_b4_real /tmp/_b4_cited /tmp/_b4_syms /tmp/_b4_defs /tmp/_b4_regtests

if [ "$status" -ne 0 ]; then
  echo
  echo "A citation that does not resolve is not a documentation nit: it is a claim of coverage"
  echo "or of behaviour that nothing backs. Either make it true, or stop making it."
fi
exit "$status"
