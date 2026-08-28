#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_ID="${1:-$(date -u +%Y%m%dT%H%M%SZ)}"

if [[ ! "$RUN_ID" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
  echo "Run id must contain only letters, numbers, underscores, and hyphens." >&2
  exit 64
fi

OUTPUT_DIR="$REPO_ROOT/.artifacts/marketing-capture/$RUN_ID"
mkdir -p "$(dirname "$OUTPUT_DIR")"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/clipboard-router-marketing-capture-clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/clipboard-router-marketing-capture-swiftpm"

cd "$REPO_ROOT"
CLIPBOARD_ROUTER_MARKETING_EVIDENCE_DIR="$OUTPUT_DIR" \
CLIPBOARD_ROUTER_MARKETING_RUN_ID="$RUN_ID" \
  swift test --filter MarketingCaptureTests/testRenderMarketingScreenshots

EXPECTED_NAMES=(capture-library.png capture-actions.png capture-private-session.png capture-vault.png)
for name in "${EXPECTED_NAMES[@]}"; do
  if [[ ! -f "$OUTPUT_DIR/$name" ]]; then
    echo "Expected marketing screenshot missing: $name" >&2
    exit 1
  fi
done

PNG_COUNT="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')"
if [[ "$PNG_COUNT" != "4" ]]; then
  echo "Expected exactly 4 marketing screenshots; found $PNG_COUNT." >&2
  exit 1
fi

jq empty "$OUTPUT_DIR/manifest.json"

(
  cd "$OUTPUT_DIR"
  shasum -a 256 -c sha256.txt
)

echo "Marketing capture passed."
echo "Evidence: $OUTPUT_DIR"
