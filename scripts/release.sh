#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="${APP_NAME:-utisuna}"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/build}"
OUTPUT_BASENAME="${OUTPUT_BASENAME:-utisuna}"

usage() {
  cat <<'EOF'
Usage:
  scripts/release.sh [tag]

Description:
  Build the Swift CLI in release mode and package the binary into a zip archive.

Release procedure:
  1. Confirm the working tree is clean and tests pass.
  2. Create and push the release tag, for example: 0.1.0
  3. Export notarization settings.
  4. Build the release zip:
       scripts/release.sh 0.1.0
  5. Build and notarize the release zip:
       NOTARIZE=1 scripts/release.sh 0.1.0
  6. Upload the generated .zip and .sha256 files from build/ to GitHub Releases
  7. Update the Homebrew formula to point at the uploaded zip URL and checksum

Arguments:
  tag                  Optional release tag.
                       If omitted, TAG env is used, then the latest git tag.

Environment:
  APP_NAME             Executable product name. Default: utisuna
  CONFIGURATION        Swift build configuration. Default: release
  BUILD_DIR            SwiftPM build directory. Default: .build
  ARTIFACTS_DIR        Output directory for packaged artifacts. Default: build
  OUTPUT_BASENAME      Base name used for packaged files. Default: utisuna
  TAG                  Release tag if not passed as the first argument
  NOTARIZE             Set to 1 to notarize the generated zip archive via scripts/notarize.sh
  PUBLISH              Reserved for external publishing steps. Default: 0
  SIGN_IDENTITY        Required when NOTARIZE=1. Developer ID Application identity
  NOTARY_PROFILE       Recommended when NOTARIZE=1. Existing notarytool profile

Examples:
  scripts/release.sh
  scripts/release.sh 0.1.0
  NOTARIZE=1 scripts/release.sh 0.1.0
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

  candidate="$BUILD_DIR/$CONFIGURATION/$APP_NAME"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="$BUILD_DIR/apple/Products/$CONFIGURATION/$APP_NAME"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="$BUILD_DIR/arm64-apple-macosx/$CONFIGURATION/$APP_NAME"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

TAG_VALUE="$(detect_tag "${1:-}")"
VERSION="$(normalize_version "$TAG_VALUE")"
ARCHIVE_STEM="${OUTPUT_BASENAME}-${VERSION}-macos"
STAGING_DIR="$ARTIFACTS_DIR/$ARCHIVE_STEM"
BINARY_DEST="$STAGING_DIR/$APP_NAME"
ZIP_PATH="$ARTIFACTS_DIR/$ARCHIVE_STEM.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

NOTARIZE="${NOTARIZE:-0}"
PUBLISH="${PUBLISH:-0}"

require_cmd swift "Install a recent Swift toolchain with Swift Package Manager."
require_cmd zip "Install the zip command line tool."

echo "==> Building $APP_NAME ($CONFIGURATION)"
swift build -c "$CONFIGURATION"

BINARY_PATH="$(resolve_binary_path)" || {
  echo "ERROR: Built binary not found under $BUILD_DIR"
  echo "Checked common SwiftPM output locations for executable: $APP_NAME"
  exit 1
}

echo "==> Preparing artifacts"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
mkdir -p "$ARTIFACTS_DIR"

cp "$BINARY_PATH" "$BINARY_DEST"
chmod +x "$BINARY_DEST"

if [[ -f "$ROOT_DIR/README.md" ]]; then
  cp "$ROOT_DIR/README.md" "$STAGING_DIR/README.md"
fi

if [[ -f "$ROOT_DIR/LICENSE" ]]; then
  cp "$ROOT_DIR/LICENSE" "$STAGING_DIR/LICENSE"
fi

cat > "$STAGING_DIR/INSTALL.txt" <<EOF
utisuna release package

Version: $VERSION
Executable: $APP_NAME

Run directly:
  ./${APP_NAME} --help

Or install somewhere on your PATH:
  install -m 0755 ${APP_NAME} /usr/local/bin/${APP_NAME}
EOF

echo "==> Creating archive: $ZIP_PATH"
rm -f "$ZIP_PATH"
(
  cd "$ARTIFACTS_DIR"
  zip -qry "$(basename "$ZIP_PATH")" "$(basename "$STAGING_DIR")"
)

if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$ZIP_PATH" > "$CHECKSUM_PATH"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$ZIP_PATH" > "$CHECKSUM_PATH"
else
  echo "WARN: No SHA-256 tool found; checksum file was not created."
fi

if [[ "$NOTARIZE" == "1" ]]; then
  if [[ ! -x "$ROOT_DIR/scripts/notarize.sh" ]]; then
    echo "ERROR: NOTARIZE=1 was requested, but scripts/notarize.sh is missing or not executable."
    exit 1
  fi

  echo "==> Running notarization helper for zip archive"
  ZIP_PATH="$ZIP_PATH" PRODUCT_NAME="$APP_NAME" VERSION="$VERSION" ARTIFACTS_DIR="$ARTIFACTS_DIR" "$ROOT_DIR/scripts/notarize.sh" "${TAG_VALUE:-$VERSION}"
fi

if [[ "$PUBLISH" == "1" ]]; then
  cat <<EOF
==> PUBLISH=1 was requested, but publishing is not implemented in this repository.
Artifacts are ready for manual upload:

- Archive : $ZIP_PATH
- Checksum: $CHECKSUM_PATH
EOF
fi

cat <<EOF

Release artifacts:
- Tag: ${TAG_VALUE:-"(none)"}
- Version: $VERSION
- Binary: $BINARY_PATH
- Archive: $ZIP_PATH
- Staging: $STAGING_DIR
- Checksum: ${CHECKSUM_PATH:-"(not created)"}
- Notarize: $NOTARIZE
- Publish: $PUBLISH

EOF
