#!/usr/bin/env bash
# Fail if any deprecated Mojo 1.0.0b2 origin alias / cast method appears in
# in-scope source. The b2 replacements are forwarding aliases / a pure method
# rename, so these tokens must never reappear.
#   as_any_origin -> as_unsafe_any_origin
#   {,Immut,Mut}ExternalOrigin -> {,Immut,Mut}UntrackedOrigin
# *AnyOrigin is NOT deprecated and must NOT be flagged.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
DIRS=(boucle tests examples)
PAT='\b(as_any_origin|ExternalOrigin|ImmutExternalOrigin|MutExternalOrigin)\b'
# grep (not rg): rg is absent on bash's PATH in CI; grep -rEn is the portable
# convention already used by run_tests.sh's other gates.
HITS=$(grep -rEn --include='*.mojo' "$PAT" "${DIRS[@]}" 2>/dev/null || true)
if [ -n "$HITS" ]; then
  echo "check_no_deprecated_origins: FAIL — deprecated b2 origin tokens found:" >&2
  echo "$HITS" >&2
  echo "Rename: as_any_origin->as_unsafe_any_origin, *ExternalOrigin->*UntrackedOrigin" >&2
  exit 1
fi
echo "check_no_deprecated_origins: PASS"
