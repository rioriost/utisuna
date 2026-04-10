#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PRODUCT_NAME="${PRODUCT_NAME:-utisuna}"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/build}"
OUTPUT_BASENAME="${OUTPUT_BASENAME:-utisuna}"

usage() {
  cat <<'EOF'
Usage:
  scripts/notarize.sh [tag]

Description:
  Build or reuse the release binary, codesign it, package it into a zip archive,
  and submit the zip to Apple notarization for Homebrew distribution.

Arguments:
  tag                  Optional release tag such as v0.1.0 or 0.1.0.
                       If omitted, TAG env is used, then the latest git tag.

Required environment:
  SIGN_IDENTITY        Developer ID Application identity used to sign the binary.

Notary credentials:
  NOTARY_PROFILE       Existing notarytool keychain profile name.
  or
  APPLE_ID             Apple ID email for notarytool.
  TEAM_ID              Apple Developer Team ID.
  APP_PASSWORD         App-specific password.

Optional environment:
  PRODUCT_NAME         Executable product name. Default: utisuna
  CONFIGURATION        Swift build configuration. Default: release
  BUILD_DIR            SwiftPM build directory. Default: .build
  ARTIFACTS_DIR        Output directory for packaged artifacts. Default: build
  OUTPUT_BASENAME      Base name used for packaged files. Default: utisuna
  ZIP_PATH             Explicit path to the zip archive to create/use
  TAG                  Release tag if not passed as the first argument

Examples:
  SIGN_IDENTITY="Developer ID Application: Example Corp (TEAMID)" \
  NOTARY_PROFILE="AC_PROFILE" \
  scripts/notarize.sh v0.1.0
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_cmd() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $cmd"
    echo "Hint: $hint"
    exit 1
  fi
}

require_env() {
  local var_name="$1"
  local hint="$2"
  local value="${!var_name:-}"
  if [[ -z "$value" ]]; then
    echo "ERROR: Required environment variable is not set: $var_name"
    echo "Hint: $hint"
    exit 1
  fi
}

detect_tag() {
  local explicit_tag="${1:-}"
  if [[ -n "$explicit_tag" ]]; then
    printf '%s\n' "$explicit_tag"
    return 0
  fi

  if [[ -n "${TAG:-}" ]]; then
    printf '%s\n' "$TAG"
    return 0
  fi

  if command -v git >/dev/null 2>&1; then
    local git_tag
    git_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
    if [[ -n "$git_tag" ]]; then
      printf '%s\n' "$git_tag"
      return 0
    fi
  fi

  printf '%s\n' ""
}

normalize_version() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    printf '%s\n' "dev"
  else
    printf '%s\n' "${raw#v}"
  fi
}

resolve_binary_path() {
  local candidate

  candidate="$BUILD_DIR/$CONFIGURATION/$PRODUCT_NAME"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="$BUILD_DIR/apple/Products/$CONFIGURATION/$PRODUCT_NAME"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="$BUILD_DIR/arm64-apple-macosx/$CONFIGURATION/$PRODUCT_NAME"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

ensure_binary() {
  local existing
  if existing="$(resolve_binary_path)"; then
    printf '%s\n' "$existing"
    return 0
  fi

  echo "==> Binary not found, building with SwiftPM"
  swift build -c "$CONFIGURATION"

  if existing="$(resolve_binary_path)"; then
    printf '%s\n' "$existing"
    return 0
  fi

  echo "ERROR: Built binary not found under $BUILD_DIR"
  echo "Checked common SwiftPM output locations for executable: $PRODUCT_NAME"
  exit 1
}

ensure_notary_credentials() {
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Using notarytool profile: $NOTARY_PROFILE"
    return 0
  fi

  if [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APP_PASSWORD:-}" ]]; then
    NOTARY_PROFILE="AC_PROFILE"
    echo "==> Storing notarytool credentials in keychain profile: $NOTARY_PROFILE"
    xcrun notarytool store-credentials "$NOTARY_PROFILE" \
      --apple-id "$APPLE_ID" \
      --team-id "$TEAM_ID" \
      --password "$APP_PASSWORD"
    return 0
  fi

  echo "ERROR: Notary credentials not configured."
  echo "Set NOTARY_PROFILE to an existing keychain profile, or set:"
  echo "  APPLE_ID, TEAM_ID, APP_PASSWORD"
  exit 1
}

TAG_VALUE="$(detect_tag "${1:-}")"
VERSION="$(normalize_version "$TAG_VALUE")"
ARCHIVE_STEM="${OUTPUT_BASENAME}-${VERSION}-macos"
STAGING_DIR="$ARTIFACTS_DIR/$ARCHIVE_STEM"
BINARY_DEST="$STAGING_DIR/$PRODUCT_NAME"
ZIP_PATH="${ZIP_PATH:-$ARTIFACTS_DIR/$ARCHIVE_STEM.zip}"
CHECKSUM_PATH="$ZIP_PATH.sha256"

require_cmd swift "Install a recent Swift toolchain with Swift Package Manager."
require_cmd codesign "Install Xcode command line tools."
require_cmd xcrun "Install Xcode command line tools."
require_cmd ditto "Use macOS; ditto is required to create the notarization zip."
require_env SIGN_IDENTITY "Set SIGN_IDENTITY to your Developer ID Application identity."

BINARY_PATH="$(ensure_binary)"

echo "==> Preparing notarization staging directory"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
mkdir -p "$ARTIFACTS_DIR"

cp "$BINARY_PATH" "$BINARY_DEST"
chmod 0755 "$BINARY_DEST"

if [[ -f "$ROOT_DIR/README.md" ]]; then
  cp "$ROOT_DIR/README.md" "$STAGING_DIR/README.md"
fi

if [[ -f "$ROOT_DIR/LICENSE" ]]; then
  cp "$ROOT_DIR/LICENSE" "$STAGING_DIR/LICENSE"
fi

cat > "$STAGING_DIR/INSTALL.txt" <<EOF
utisuna notarized release package

Version: $VERSION
Executable: $PRODUCT_NAME

Run directly:
  ./${PRODUCT_NAME} --help

Or install somewhere on your PATH:
  install -m 0755 ${PRODUCT_NAME} /usr/local/bin/${PRODUCT_NAME}
EOF

echo "==> Codesigning binary with identity: $SIGN_IDENTITY"
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$BINARY_DEST"
codesign --verify --deep --strict --verbose=2 "$BINARY_DEST"

echo "==> Creating zip for notarization: $ZIP_PATH"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$STAGING_DIR" "$ZIP_PATH"

ensure_notary_credentials

echo "==> Submitting zip for notarization"
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$ZIP_PATH" > "$CHECKSUM_PATH"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$ZIP_PATH" > "$CHECKSUM_PATH"
else
  echo "WARN: No SHA-256 tool found; checksum file was not created."
fi

echo "==> Notarization complete"
echo "Binary : $BINARY_DEST"
echo "Archive: $ZIP_PATH"
echo "SHA256 : $CHECKSUM_PATH"
