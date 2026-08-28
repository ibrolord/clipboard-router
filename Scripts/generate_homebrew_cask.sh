#!/bin/bash

set -euo pipefail

CASK_NAME="clipboard-router"
DISPLAY_NAME="Clipboard Router"
VERSION=""
BUNDLE_ID="com.clipboardrouter.ClipboardRouter"
HOMEPAGE=""
DESCRIPTION="Menu-bar clipboard manager with actionable clip routing"
ARM64_URL=""
ARM64_SHA256=""
X8664_URL=""
X8664_SHA256=""
OUTPUT_PATH=""
OVERWRITE=0

usage() {
    cat <<'USAGE'
Generate a Homebrew Cask definition for a Clipboard Router customer archive
produced by Scripts/create_customer_archive.sh.

Usage:
  Scripts/generate_homebrew_cask.sh [options]

Required:
  --version VERSION            Cask/app version (two or three numeric components)
  --homepage URL                Project homepage (HTTPS, no query/fragment/credentials)
  --arm64-url URL                HTTPS download URL for the arm64 customer archive
  --arm64-sha256 HASH             sha256 of that archive (from its .sha256 sidecar)

Optional:
  --cask-name TOKEN              Homebrew Cask token (default: clipboard-router)
  --display-name NAME             App name as packaged, matches --display-name used by
                                   create_customer_archive.sh (default: "Clipboard Router")
  --bundle-id IDENTIFIER          Bundle identifier, used only to derive the zap path
                                   (default: com.clipboardrouter.ClipboardRouter)
  --desc TEXT                     Cask description
  --x86-64-url URL                HTTPS download URL for a future Intel or universal archive
  --x86-64-sha256 HASH              sha256 of that archive (required together with --x86-64-url)
  --output PATH                   Write the generated cask to PATH instead of stdout
  --overwrite                     Replace an existing --output file
  --help                          Show this help

If --x86-64-url/--x86-64-sha256 are omitted, the cask is generated arm64-only and pinned
with `depends_on arch: :arm64`. If they are supplied and differ from the arm64 pair, the
cask selects per-architecture downloads with `on_arm`/`on_intel` blocks. If they are
supplied and exactly match the arm64 pair, the cask is generated as a single universal
download with no architecture restriction.

This script never fabricates a homepage or download URL: both must be supplied by the
caller from real, already-published release infrastructure. It performs no network
access and does not publish to any Homebrew tap.
USAGE
}

die() {
    echo "error: $*" >&2
    exit 1
}

require_value() {
    [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
}

require_https_url() {
    local flag="$1"
    local value="$2"
    /usr/bin/python3 -c 'import sys, urllib.parse
p = urllib.parse.urlsplit(sys.argv[1])
ok = (p.scheme == "https" and bool(p.hostname) and p.username is None and p.password is None
      and not p.query and not p.fragment and not any(c.isspace() for c in sys.argv[1]))
raise SystemExit(0 if ok else 1)' "${value}" \
        || die "${flag} must be an HTTPS URL without query, fragment, whitespace, or credentials"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cask-name)
            require_value "$@"
            CASK_NAME="$2"
            shift 2
            ;;
        --display-name)
            require_value "$@"
            DISPLAY_NAME="$2"
            shift 2
            ;;
        --version)
            require_value "$@"
            VERSION="$2"
            shift 2
            ;;
        --bundle-id)
            require_value "$@"
            BUNDLE_ID="$2"
            shift 2
            ;;
        --homepage)
            require_value "$@"
            HOMEPAGE="$2"
            shift 2
            ;;
        --desc)
            require_value "$@"
            DESCRIPTION="$2"
            shift 2
            ;;
        --arm64-url)
            require_value "$@"
            ARM64_URL="$2"
            shift 2
            ;;
        --arm64-sha256)
            require_value "$@"
            ARM64_SHA256="$2"
            shift 2
            ;;
        --x86-64-url)
            require_value "$@"
            X8664_URL="$2"
            shift 2
            ;;
        --x86-64-sha256)
            require_value "$@"
            X8664_SHA256="$2"
            shift 2
            ;;
        --output)
            require_value "$@"
            OUTPUT_PATH="$2"
            shift 2
            ;;
        --overwrite)
            OVERWRITE=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ "${CASK_NAME}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "--cask-name must be lowercase, digits, and hyphens only"
[[ -n "${DISPLAY_NAME}" && "${DISPLAY_NAME}" != */* ]] || die "--display-name must be a single non-empty path component"
[[ "${VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "--version must contain two or three numeric components"
[[ "${BUNDLE_ID}" =~ ^[A-Za-z0-9]+([.-][A-Za-z0-9]+)+$ ]] || die "invalid --bundle-id: ${BUNDLE_ID}"
[[ -n "${HOMEPAGE}" ]] || die "--homepage is required"
require_https_url "--homepage" "${HOMEPAGE}"
HOMEPAGE="$(/usr/bin/python3 -c 'import sys, urllib.parse; p=urllib.parse.urlsplit(sys.argv[1]); print(urllib.parse.urlunsplit((p.scheme, p.netloc, p.path or "/", "", "")))' "${HOMEPAGE}")"
[[ -n "${DESCRIPTION}" ]] || die "--desc must not be empty"
[[ -n "${ARM64_URL}" ]] || die "--arm64-url is required"
require_https_url "--arm64-url" "${ARM64_URL}"
[[ "${ARM64_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "--arm64-sha256 must be a lowercase 64-character hex sha256"

X8664_FIELD_COUNT=0
[[ -z "${X8664_URL}" ]] || X8664_FIELD_COUNT=$((X8664_FIELD_COUNT + 1))
[[ -z "${X8664_SHA256}" ]] || X8664_FIELD_COUNT=$((X8664_FIELD_COUNT + 1))
[[ "${X8664_FIELD_COUNT}" -eq 0 || "${X8664_FIELD_COUNT}" -eq 2 ]] \
    || die "--x86-64-url and --x86-64-sha256 must be supplied together"
HAVE_X8664=0
if [[ "${X8664_FIELD_COUNT}" -eq 2 ]]; then
    require_https_url "--x86-64-url" "${X8664_URL}"
    [[ "${X8664_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "--x86-64-sha256 must be a lowercase 64-character hex sha256"
    HAVE_X8664=1
fi

if [[ -n "${OUTPUT_PATH}" && -e "${OUTPUT_PATH}" ]]; then
    [[ "${OVERWRITE}" -eq 1 ]] || die "output already exists; pass --overwrite to replace ${OUTPUT_PATH}"
fi

# Homebrew Cask class names are the token's hyphen-separated words, capitalized and joined.
CLASS_NAME="$(/usr/bin/python3 -c 'print("".join(word.capitalize() for word in __import__("sys").argv[1].split("-")))' "${CASK_NAME}")"
# Intentionally literal: this becomes Ruby source text and Homebrew expands the
# tilde itself at run time, not this script.
# shellcheck disable=SC2088
ZAP_CONTAINER_PATH="~/Library/Containers/${BUNDLE_ID}"

render_universal_download() {
    cat <<CASK
  version "${VERSION}"
  sha256 "${ARM64_SHA256}"
  url "${ARM64_URL}"
CASK
}

render_arm64_only_download() {
    cat <<CASK
  version "${VERSION}"
  sha256 "${ARM64_SHA256}"
  url "${ARM64_URL}"
CASK
}

render_per_architecture_download() {
    cat <<CASK
  version "${VERSION}"

  on_arm do
    sha256 "${ARM64_SHA256}"
    url "${ARM64_URL}"
  end

  on_intel do
    sha256 "${X8664_SHA256}"
    url "${X8664_URL}"
  end

CASK
}

SINGLE_UNIVERSAL_DOWNLOAD=0
if [[ "${HAVE_X8664}" -eq 1 && "${X8664_URL}" == "${ARM64_URL}" && "${X8664_SHA256}" == "${ARM64_SHA256}" ]]; then
    SINGLE_UNIVERSAL_DOWNLOAD=1
fi

CASK_BODY="$(mktemp "${TMPDIR:-/tmp}/clipboard-router-cask.XXXXXX")"
trap 'rm -f "${CASK_BODY}"' EXIT

{
    echo "# typed: strict"
    echo "# frozen_string_literal: true"
    echo
    echo "cask \"${CASK_NAME}\" do"
    if [[ "${HAVE_X8664}" -eq 0 ]]; then
        render_arm64_only_download
    elif [[ "${SINGLE_UNIVERSAL_DOWNLOAD}" -eq 1 ]]; then
        render_universal_download
    else
        render_per_architecture_download
    fi
    cat <<CASK
  name "${DISPLAY_NAME}"
  desc "${DESCRIPTION}"
  homepage "${HOMEPAGE}"

CASK
    if [[ "${HAVE_X8664}" -eq 0 ]]; then
        cat <<CASK
  depends_on arch: :arm64
  depends_on macos: :sonoma

CASK
    else
        cat <<CASK
  depends_on macos: :sonoma

CASK
    fi
    cat <<CASK
  app "${DISPLAY_NAME}.app"

  zap trash: "${ZAP_CONTAINER_PATH}"
end
CASK
} > "${CASK_BODY}"

if command -v ruby >/dev/null 2>&1; then
    ruby -c "${CASK_BODY}" >/dev/null || die "generated cask has invalid Ruby syntax"
else
    echo "ruby: not installed (skipped syntax check)" >&2
fi

if [[ -n "${OUTPUT_PATH}" ]]; then
    mkdir -p "$(dirname "${OUTPUT_PATH}")"
    /bin/cp "${CASK_BODY}" "${OUTPUT_PATH}"
    echo "Generated ${OUTPUT_PATH} (class ${CLASS_NAME})" >&2
else
    cat "${CASK_BODY}"
fi
