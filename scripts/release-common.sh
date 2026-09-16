#!/usr/bin/env bash
# shellcheck disable=SC2034

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

init_release() {
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "$ROOT_DIR" || fail "Cannot enter repository: $ROOT_DIR"
  SWIFT="${SWIFT:-swift}"
  PRODUCT_NAME="${APP_NAME:-${PRODUCT_NAME:-utisuna}}"
  CONFIGURATION="${CONFIGURATION:-release}"
  BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build}"
  ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/build}"
  OUTPUT_BASENAME="${OUTPUT_BASENAME:-utisuna}"
  APP_REPO="${APP_REPO:-rioriost/utisuna}"
  HOMEBREW_TAP_REPO="${HOMEBREW_TAP_REPO:-rioriost/homebrew-tap}"
  DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
  [[ "$BUILD_DIR" = /* ]] || BUILD_DIR="$ROOT_DIR/$BUILD_DIR"
  [[ "$ARTIFACTS_DIR" = /* ]] || ARTIFACTS_DIR="$ROOT_DIR/$ARTIFACTS_DIR"
  [[ "$PRODUCT_NAME" == "utisuna" ]] || fail "The release product must be utisuna."
  [[ "$OUTPUT_BASENAME" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "Invalid OUTPUT_BASENAME."
  [[ "$APP_REPO" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || fail "Invalid APP_REPO."

  TAG_VALUE="${1:-${TAG:-}}"
  if [[ -z "$TAG_VALUE" ]]; then
    TAG_VALUE="$(git describe --tags --exact-match 2>/dev/null)" ||
      fail "Pass a release tag, set TAG, or check out a tagged commit."
  fi
  [[ "$TAG_VALUE" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "Use a version tag such as 0.1.2 or v0.1.2."
  VERSION="${TAG_VALUE#v}"
  ARCHIVE_STEM="$OUTPUT_BASENAME-$VERSION-macos"
  ZIP_PATH="$ARTIFACTS_DIR/$ARCHIVE_STEM.zip"
  CHECKSUM_PATH="$ZIP_PATH.sha256"
  FORMULA_PATH="$ARTIFACTS_DIR/$ARCHIVE_STEM.rb"
}

validate_source() {
  [[ -z "$(git status --porcelain)" ]] || fail "Working tree is not clean."
  SOURCE_COMMIT="$(git rev-parse --verify "refs/tags/$TAG_VALUE^{commit}")" ||
    fail "Tag not found locally: $TAG_VALUE"
  [[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" ]] ||
    fail "HEAD must match tag $TAG_VALUE. Check out the tagged commit before building or resuming."
}

build_binary() {
  require_cmd "$SWIFT"
  require_cmd lipo
  require_cmd otool
  printf '==> Building %s (%s, arm64)\n' "$PRODUCT_NAME" "$CONFIGURATION" >&2
  "$SWIFT" build --scratch-path "$BUILD_DIR" -c "$CONFIGURATION" \
    --arch arm64 --product "$PRODUCT_NAME" >&2
  local bin_dir
  bin_dir="$("$SWIFT" build --scratch-path "$BUILD_DIR" -c "$CONFIGURATION" \
    --arch arm64 --show-bin-path)"
  BINARY_PATH="$bin_dir/$PRODUCT_NAME"
  [[ -x "$BINARY_PATH" ]] || fail "Built executable not found: $BINARY_PATH"
  [[ "$("$BINARY_PATH" --version)" == "$VERSION" ]] ||
    fail "Executable version does not match tag $TAG_VALUE."
  [[ "$(lipo -archs "$BINARY_PATH")" == "arm64" ]] ||
    fail "Distribution binary must contain only arm64."
  [[ "$(otool -l "$BINARY_PATH" | awk '$1 == "minos" { print $2 }')" == "12.0" ]] ||
    fail "Distribution binary must target macOS 12.0."
}

require_notary_settings() {
  require_cmd codesign
  require_cmd xcrun
  require_cmd plutil
  [[ -n "${SIGN_IDENTITY:-}" ]] || fail "Set SIGN_IDENTITY to a Developer ID Application identity."
  [[ -n "${NOTARY_PROFILE:-}" ]] || fail "Set NOTARY_PROFILE to an existing notarytool keychain profile."
}

cleanup_staging() {
  if [[ -n "${STAGING_ROOT:-}" ]]; then
    rm -f "$STAGING_ROOT/$ARCHIVE_STEM/$PRODUCT_NAME" \
      "$STAGING_ROOT/$ARCHIVE_STEM/README.md" \
      "$STAGING_ROOT/$ARCHIVE_STEM/LICENSE" \
      "$STAGING_ROOT/$ARCHIVE_STEM/INSTALL.txt" \
      "$STAGING_ROOT/$ARCHIVE_STEM.zip" "$STAGING_ROOT/notary.json"
    rmdir "$STAGING_ROOT/$ARCHIVE_STEM" "$STAGING_ROOT"
  fi
}

create_archive() {
  require_cmd ditto
  require_cmd shasum
  local path
  for path in "$ZIP_PATH" "$CHECKSUM_PATH" "$ZIP_PATH.commit" "$ZIP_PATH.notarized" "$FORMULA_PATH"; do
    [[ ! -e "$path" ]] || fail "Artifact already exists: $path. Use --resume to publish it, or choose another ARTIFACTS_DIR."
  done
  build_binary
  mkdir -p "$ARTIFACTS_DIR"
  STAGING_ROOT="$(mktemp -d "$ARTIFACTS_DIR/.utisuna-stage.XXXXXX")"
  trap cleanup_staging EXIT
  local stage="$STAGING_ROOT/$ARCHIVE_STEM"
  mkdir "$stage"
  cp "$BINARY_PATH" "$stage/$PRODUCT_NAME"
  chmod 0755 "$stage/$PRODUCT_NAME"
  cp "$ROOT_DIR/README.md" "$ROOT_DIR/LICENSE" "$stage/"
  cat > "$stage/INSTALL.txt" <<EOF
utisuna $VERSION (macOS 12+, Apple Silicon)

Run: ./$PRODUCT_NAME --help
Install: install -m 0755 $PRODUCT_NAME /usr/local/bin/$PRODUCT_NAME
EOF

  if [[ "$NOTARIZE" == "1" ]]; then
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$stage/$PRODUCT_NAME"
    codesign --verify --strict --verbose=2 "$stage/$PRODUCT_NAME"
  fi
  COPYFILE_DISABLE=1 ditto --norsrc -c -k --keepParent "$stage" "$STAGING_ROOT/$ARCHIVE_STEM.zip"
  if [[ "$NOTARIZE" == "1" ]]; then
    printf '==> Submitting archive for notarization\n' >&2
    if ! xcrun notarytool submit "$STAGING_ROOT/$ARCHIVE_STEM.zip" \
      --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$STAGING_ROOT/notary.json"; then
      cp "$STAGING_ROOT/notary.json" "$ARTIFACTS_DIR/$ARCHIVE_STEM.notary.json"
      fail "Notarization failed. See $ARTIFACTS_DIR/$ARCHIVE_STEM.notary.json."
    fi
    local status
    status="$(plutil -extract status raw -o - "$STAGING_ROOT/notary.json")"
    cp "$STAGING_ROOT/notary.json" "$ARTIFACTS_DIR/$ARCHIVE_STEM.notary.json"
    [[ "$status" == "Accepted" ]] || fail "Notarization status: $status. Archive will not be published."
  fi

  # A hard link installs the completed archive without overwriting an existing release.
  ln "$STAGING_ROOT/$ARCHIVE_STEM.zip" "$ZIP_PATH"
  (cd "$ARTIFACTS_DIR" && shasum -a 256 "$ARCHIVE_STEM.zip" > "$ARCHIVE_STEM.zip.sha256")
  printf '%s\n' "$SOURCE_COMMIT" > "$ZIP_PATH.commit"
  if [[ "$NOTARIZE" == "1" ]]; then
    awk '{ print $1 }' "$CHECKSUM_PATH" > "$ZIP_PATH.notarized"
  fi
  cleanup_staging
  STAGING_ROOT=""
  trap - EXIT
}

verify_archive() {
  require_cmd shasum
  [[ -f "$ZIP_PATH" && -f "$CHECKSUM_PATH" && -f "$ZIP_PATH.commit" ]] ||
    fail "Missing archive or provenance files. Build the release first."
  local expected actual
  actual="$(shasum -a 256 "$ZIP_PATH" | awk '{ print $1 }')"
  expected="$actual  $ARCHIVE_STEM.zip"
  [[ "$(cat "$CHECKSUM_PATH")" == "$expected" ]] || fail "Archive checksum mismatch."
  [[ "$(cat "$ZIP_PATH.commit")" == "$SOURCE_COMMIT" ]] || fail "Archive source commit mismatch."
  if [[ "$NOTARIZE" == "1" ]]; then
    [[ -f "$ZIP_PATH.notarized" ]] || fail "Archive has no successful notarization receipt."
    [[ "$(cat "$ZIP_PATH.notarized")" == "$actual" ]] || fail "Notarized archive checksum mismatch."
  fi
}

write_formula() {
  local checksum
  checksum="$(awk '{ print $1 }' "$CHECKSUM_PATH")"
  sed -e "s|{{REPO}}|$APP_REPO|g" -e "s|{{TAG}}|$TAG_VALUE|g" \
    -e "s|{{VERSION}}|$VERSION|g" -e "s|{{ARCHIVE}}|$ARCHIVE_STEM.zip|g" \
    -e "s|{{SHA256}}|$checksum|g" "$ROOT_DIR/docs/utisuna.rb.template" > "$FORMULA_PATH"
}
