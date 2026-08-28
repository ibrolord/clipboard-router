#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_ID="${1:-$(date -u +%Y%m%dT%H%M%SZ)}"

if [[ ! "$RUN_ID" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
  echo "Run id must contain only letters, numbers, underscores, and hyphens." >&2
  exit 64
fi

OUTPUT_DIR="$REPO_ROOT/.artifacts/settings-visual/$RUN_ID"
mkdir -p "$OUTPUT_DIR"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/clipboard-router-settings-visual-clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/clipboard-router-settings-visual-swiftpm"

cd "$REPO_ROOT"
CLIPBOARD_ROUTER_SETTINGS_EVIDENCE_DIR="$OUTPUT_DIR" \
  swift test --filter SettingsVisualAcceptanceTests/testRenderAllVisibleSettingsTabsAndClipCountStates

PNG_COUNT="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')"
if [[ "$PNG_COUNT" != "24" ]]; then
  echo "Expected 24 Settings screenshots; found $PNG_COUNT." >&2
  exit 1
fi

jq empty "$OUTPUT_DIR/manifest.json"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 ./*.png ./manifest.json > sha256.txt
  shasum -a 256 -c sha256.txt
)

echo "Settings visual acceptance passed."
echo "Evidence: $OUTPUT_DIR"
