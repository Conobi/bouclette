#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/_arch_sub.sh"
apply_arch_substitution

cd "$PROJECT_DIR"

echo "Removing stale precompiled packages..."
rm -f *.mojopkg *.mojoc

echo "Building boucle (arch=$ARCH)..."
uv run mojo precompile boucle -o boucle.mojoc

echo "All packages built."
ls -lh *.mojoc
