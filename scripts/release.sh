#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="${APP_NAME:-utisuna}"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/build}"
OUTPUT_BASENAME="${OUTPUT_BASENAME:-utisuna}"
FORMULA_PATH="$ROOT_DIR/Formula/utisuna.rb"

APP_REPO="${APP_REPO:-rioriost/utisuna}"
HOMEBREW_TAP_REPO="${HOMEBREW_TAP_REPO:-rioriost/homebrew-tap}"
HOMEBREW_TAP_PATH="${HOMEBREW_TAP_PATH:-}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

NOTARIZE="${NOTARIZE:-1}"
PUBLISH="${PUBLISH:-1}"

usage() {
  cat <<'EOF'
Usage:
  scripts/release.sh [tag]

Description:
  Build the Swift CLI in release mode, optionally notarize it, create or update
  the GitHub release, refresh Formula/utisuna.rb, and publish that formula to
  github.com/rioriost/homebrew-tap.

Default behavior:
  - Detect the latest git tag when no tag argument is given
  - Build the release zip and checksum
  - Notarize the zip unless NOTARIZE=0
  - Create or update the GitHub release unless PUBLISH=0
  - Refresh Formula/utisuna.rb in this repository
  - Copy Formula/utisuna.rb into HOMEBREW_TAP_PATH and commit/push it unless PUBLISH=0

Release procedure:
  1. Confirm the working tree is clean and tests pass.
  2. Create the release tag, for example:
       git tag 0.1.0
  3. Export release settings:
       export SIGN_IDENTITY="Developer ID Application: Ryo Fujita (23889H77KX)"
       export NOTARY_PROFILE="AC_PROFILE"
       export HOMEBREW_TAP_PATH="../homebrew-tap"
  4. Run:
       scripts/release.sh
  5. The script will:
       - push the current branch and tag to github.com/rioriost/utisuna
       - upload the zip and checksum to the GitHub release
       - refresh Formula/utisuna.rb
       - copy it to github.com/rioriost/homebrew-tap
       - commit and push the tap update

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

  APP_REPO             GitHub repo for releases. Default: rioriost/utisuna
  HOMEBREW_TAP_REPO    GitHub tap repo. Default: rioriost/homebrew-tap
  HOMEBREW_TAP_PATH    Local checkout of github.com/rioriost/homebrew-tap
  DEFAULT_BRANCH       Branch to push before the tag. Default: main

  NOTARIZE             Set to 1 to notarize the generated zip archive. Default: 1
  PUBLISH              Set to 1 to publish GitHub release and tap update. Default: 1

  SIGN_IDENTITY        Required when NOTARIZE=1. Developer ID Application identity
  NOTARY_PROFILE       Recommended when NOTARIZE=1. Existing notarytool profile

  RELEASE_NOTES        Optional notes for gh release create
  TAP_COMMIT_MESSAGE   Optional commit message for the tap update

Examples:
  scripts/release.sh
  scripts/release.sh 0.1.0
  NOTARIZE=0 PUBLISH=0 scripts/release.sh 0.1.0
  HOMEBREW_TAP_PATH=../homebrew-tap scripts/release.sh
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

ensure_clean_worktree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: Working tree is not clean."
    echo "Commit or stash changes before running the release flow."
    exit 1
  fi
}

ensure_tag_exists_locally() {
  if ! git rev-parse -q --verify "refs/tags/$TAG_VALUE" >/dev/null 2>&1; then
    echo "ERROR: Tag not found locally: $TAG_VALUE"
    echo "Create it first, for example: git tag $TAG_VALUE"
    exit 1
  fi
}

ensure_gh_auth() {
  if ! gh auth status -h github.com >/dev/null 2>&1; then
    echo "ERROR: gh CLI is not authenticated."
    echo "Run: gh auth login"
    exit 1
  fi
}

push_release_refs() {
  echo "==> Pushing branch and tag to origin"
  git push origin "$DEFAULT_BRANCH"
  git push origin "$TAG_VALUE"
}

create_archive() {
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
}

write_checksum() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$ZIP_PATH" > "$CHECKSUM_PATH"
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$ZIP_PATH" > "$CHECKSUM_PATH"
  else
    echo "WARN: No SHA-256 tool found; checksum file was not created."
  fi
}

refresh_formula() {
  local checksum
  checksum="$(awk '{print $1}' "$CHECKSUM_PATH")"

  echo "==> Refreshing Homebrew formula: $FORMULA_PATH"
  mkdir -p "$(dirname "$FORMULA_PATH")"
  cat > "$FORMULA_PATH" <<EOF
class Utisuna < Formula
  desc "Set the default app for the content type of a sample file"
  homepage "https://github.com/${APP_REPO}"
  url "https://github.com/${APP_REPO}/releases/download/${TAG_VALUE}/${ARCHIVE_STEM}.zip"
  sha256 "${checksum}"
  version "${VERSION}"

  def install
    bin.install "${ARCHIVE_STEM}/utisuna" => "utisuna"
  end

  test do
    assert_match "Set the default app for the content type of a sample file",
                 shell_output("#{bin}/utisuna --help")
  end
end
EOF
}

publish_github_release() {
  local target_ref
  target_ref="$(git rev-parse "$TAG_VALUE")"

  echo "==> Publishing GitHub release: $TAG_VALUE"
  if gh release view "$TAG_VALUE" --repo "$APP_REPO" >/dev/null 2>&1; then
    gh release upload "$TAG_VALUE" "$ZIP_PATH" "$CHECKSUM_PATH" --clobber --repo "$APP_REPO"
  else
    if [[ -n "${RELEASE_NOTES:-}" ]]; then
      gh release create "$TAG_VALUE" "$ZIP_PATH" "$CHECKSUM_PATH" \
        --notes "$RELEASE_NOTES" \
        --repo "$APP_REPO" \
        --target "$target_ref"
    else
      gh release create "$TAG_VALUE" "$ZIP_PATH" "$CHECKSUM_PATH" \
        --generate-notes \
        --repo "$APP_REPO" \
        --target "$target_ref"
    fi
  fi
}

publish_homebrew_tap() {
  require_env HOMEBREW_TAP_PATH "Set HOMEBREW_TAP_PATH to the local checkout of github.com/${HOMEBREW_TAP_REPO}."

  if [[ ! -d "$HOMEBREW_TAP_PATH/.git" ]]; then
    echo "ERROR: HOMEBREW_TAP_PATH is not a git repository: $HOMEBREW_TAP_PATH"
    exit 1
  fi

  echo "==> Updating Homebrew tap: $HOMEBREW_TAP_PATH"
  mkdir -p "$HOMEBREW_TAP_PATH/Formula"
  cp "$FORMULA_PATH" "$HOMEBREW_TAP_PATH/Formula/utisuna.rb"

  git -C "$HOMEBREW_TAP_PATH" add Formula/utisuna.rb
  if ! git -C "$HOMEBREW_TAP_PATH" diff --cached --quiet; then
    git -C "$HOMEBREW_TAP_PATH" commit -m "${TAP_COMMIT_MESSAGE:-utisuna ${VERSION}}"
  else
    echo "==> No Homebrew formula changes to commit"
  fi

  git -C "$HOMEBREW_TAP_PATH" push
}

TAG_VALUE="$(detect_tag "${1:-}")"
if [[ -z "$TAG_VALUE" ]]; then
  echo "ERROR: No git tag found. Pass a tag as an argument, set TAG, or create a tag first."
  exit 1
fi

VERSION="$(normalize_version "$TAG_VALUE")"
ARCHIVE_STEM="${OUTPUT_BASENAME}-${VERSION}-macos"
STAGING_DIR="$ARTIFACTS_DIR/$ARCHIVE_STEM"
BINARY_DEST="$STAGING_DIR/$APP_NAME"
ZIP_PATH="$ARTIFACTS_DIR/$ARCHIVE_STEM.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

require_cmd git "Install git and ensure the repository is available."
require_cmd swift "Install a recent Swift toolchain with Swift Package Manager."
require_cmd zip "Install the zip command line tool."

ensure_clean_worktree
ensure_tag_exists_locally

if [[ "$PUBLISH" == "1" ]]; then
  require_cmd gh "Install GitHub CLI: https://cli.github.com/"
  ensure_gh_auth
fi

echo "==> Building $APP_NAME ($CONFIGURATION)"
swift build -c "$CONFIGURATION"

BINARY_PATH="$(resolve_binary_path)" || {
  echo "ERROR: Built binary not found under $BUILD_DIR"
  echo "Checked common SwiftPM output locations for executable: $APP_NAME"
  exit 1
}

create_archive
write_checksum

if [[ "$NOTARIZE" == "1" ]]; then
  if [[ ! -x "$ROOT_DIR/scripts/notarize.sh" ]]; then
    echo "ERROR: NOTARIZE=1 was requested, but scripts/notarize.sh is missing or not executable."
    exit 1
  fi

  echo "==> Running notarization helper for zip archive"
  ZIP_PATH="$ZIP_PATH" PRODUCT_NAME="$APP_NAME" VERSION="$VERSION" ARTIFACTS_DIR="$ARTIFACTS_DIR" \
    "$ROOT_DIR/scripts/notarize.sh" "$TAG_VALUE"
  write_checksum
fi

refresh_formula

if [[ "$PUBLISH" == "1" ]]; then
  push_release_refs
  publish_github_release
  publish_homebrew_tap
fi

cat <<EOF

Release artifacts:
- Repo: $APP_REPO
- Tag: $TAG_VALUE
- Version: $VERSION
- Binary: $BINARY_PATH
- Archive: $ZIP_PATH
- Staging: $STAGING_DIR
- Checksum: $CHECKSUM_PATH
- Formula: $FORMULA_PATH
- Notarize: $NOTARIZE
- Publish: $PUBLISH

EOF
