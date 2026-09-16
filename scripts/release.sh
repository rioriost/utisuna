#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/release-common.sh
source "$(dirname "$0")/release-common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/release.sh [--publish|--resume] [tag]

Default: build an unsigned local archive in build/unsigned. Never publish.
--publish: preflight, build, sign, notarize, push refs, create release, update tap.
--resume: publish the existing notarized archive without rebuilding or replacing it.

HEAD must match the release tag and the worktree must be clean.
Published archives are immutable; a fresh publish refuses an existing release.
Resume accepts an existing release only if its assets match the local archive.

Signing: SIGN_IDENTITY, NOTARY_PROFILE (existing notarytool keychain profile).
Publishing: HOMEBREW_TAP_PATH (clean checkout, synchronized with origin/main).
Optional: TAG, BUILD_DIR, ARTIFACTS_DIR, CONFIGURATION, SWIFT, OUTPUT_BASENAME,
          APP_REPO, HOMEBREW_TAP_REPO, DEFAULT_BRANCH, RELEASE_NOTES.
NOTARIZE=1 creates a signed local archive. PUBLISH=1 also requires NOTARIZE=1.
The generated Formula is saved beside the archive; tracked files are not edited.

Examples:
  scripts/release.sh 0.1.2
  scripts/notarize.sh 0.1.2
  HOMEBREW_TAP_PATH=../homebrew-tap scripts/release.sh --resume 0.1.2
EOF
}

PUBLISH="${PUBLISH:-0}"
NOTARIZE="${NOTARIZE:-0}"
RESUME=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --publish) PUBLISH=1; NOTARIZE=1; shift ;;
  --resume) PUBLISH=1; NOTARIZE=1; RESUME=1; shift ;;
esac
[[ $# -le 1 ]] || fail "Expected at most one release tag."
[[ "$PUBLISH" =~ ^[01]$ && "$NOTARIZE" =~ ^[01]$ ]] || fail "PUBLISH and NOTARIZE must be 0 or 1."
[[ "$PUBLISH" == "0" || "$NOTARIZE" == "1" ]] || fail "Publishing requires notarization."
if [[ "$NOTARIZE" == "0" && -z "${ARTIFACTS_DIR:-}" ]]; then
  ARTIFACTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/build/unsigned"
fi

check_origin() {
  local repo_path="$1" expected="$2" remote
  remote="$(git -C "$repo_path" remote get-url origin)"
  case "$remote" in
    https://github.com/*) remote="${remote#https://github.com/}" ;;
    git@github.com:*) remote="${remote#git@github.com:}" ;;
    *) fail "Unsupported origin URL: $remote" ;;
  esac
  [[ "${remote%.git}" == "$expected" ]] || fail "Origin must be github.com/$expected."
}

preflight_publish() {
  require_cmd gh
  [[ -n "${HOMEBREW_TAP_PATH:-}" ]] || fail "Set HOMEBREW_TAP_PATH before publishing."
  HOMEBREW_TAP_PATH="$(cd "$HOMEBREW_TAP_PATH" && pwd -P)" ||
    fail "HOMEBREW_TAP_PATH does not exist."
  [[ "$(git -C "$HOMEBREW_TAP_PATH" rev-parse --show-toplevel)" == "$HOMEBREW_TAP_PATH" ]] ||
    fail "HOMEBREW_TAP_PATH must be the root of a git checkout."
  [[ -z "$(git -C "$HOMEBREW_TAP_PATH" status --porcelain)" ]] ||
    fail "Tap worktree and index must be clean; no files have been overwritten."
  check_origin "$ROOT_DIR" "$APP_REPO"
  check_origin "$HOMEBREW_TAP_PATH" "$HOMEBREW_TAP_REPO"
  [[ "$(git -C "$HOMEBREW_TAP_PATH" symbolic-ref --short HEAD)" == "$DEFAULT_BRANCH" ]] ||
    fail "Tap must be on $DEFAULT_BRANCH."
  gh auth status -h github.com >/dev/null 2>&1 || fail "GitHub CLI authentication failed."
  git -C "$HOMEBREW_TAP_PATH" fetch --quiet origin "$DEFAULT_BRANCH"
  local tap_head tap_remote
  tap_head="$(git -C "$HOMEBREW_TAP_PATH" rev-parse HEAD)"
  TAP_HEAD="$tap_head"
  tap_remote="$(git -C "$HOMEBREW_TAP_PATH" rev-parse "refs/remotes/origin/$DEFAULT_BRANCH")"
  if [[ "$tap_head" != "$tap_remote" ]]; then
    if [[ "$RESUME" != "1" || ! -f "$ZIP_PATH.tap-commit" ]] ||
      [[ "$(cat "$ZIP_PATH.tap-commit")" != "$tap_head" ]] ||
      [[ "$(git -C "$HOMEBREW_TAP_PATH" rev-parse HEAD^)" != "$tap_remote" ]] ||
      [[ "$(git -C "$HOMEBREW_TAP_PATH" diff-tree --no-commit-id --name-only -r HEAD)" != "Formula/utisuna.rb" ]]; then
      fail "Tap must match origin/$DEFAULT_BRANCH; refusing to push unrelated commits."
    fi
  fi
  RELEASE_ID="$(gh api --paginate "repos/$APP_REPO/releases" \
    --jq ".[] | select(.tag_name == \"$TAG_VALUE\") | .id")"
  if [[ -n "$RELEASE_ID" && "$RESUME" != "1" ]]; then
    fail "Release $TAG_VALUE already exists. Use --resume with the identical notarized archive."
  fi
  if [[ -z "$RELEASE_ID" ]]; then
    [[ "$(git symbolic-ref --short HEAD)" == "$DEFAULT_BRANCH" ]] ||
      fail "Publish a new release from $DEFAULT_BRANCH at the tagged commit."
  fi
}

verify_remote_assets() {
  local download_dir
  download_dir="$(mktemp -d "$ARTIFACTS_DIR/.utisuna-download.XXXXXX")"
  if ! gh release download "$TAG_VALUE" --repo "$APP_REPO" \
    --pattern "$ARCHIVE_STEM.zip" --pattern "$ARCHIVE_STEM.zip.sha256" --dir "$download_dir"; then
    rm -f "$download_dir/$ARCHIVE_STEM.zip" "$download_dir/$ARCHIVE_STEM.zip.sha256"
    rmdir "$download_dir"
    fail "Could not download existing assets; refusing to replace them."
  fi
  local matches=1
  cmp -s "$ZIP_PATH" "$download_dir/$ARCHIVE_STEM.zip" || matches=0
  cmp -s "$CHECKSUM_PATH" "$download_dir/$ARCHIVE_STEM.zip.sha256" || matches=0
  rm -f "$download_dir/$ARCHIVE_STEM.zip" "$download_dir/$ARCHIVE_STEM.zip.sha256"
  rmdir "$download_dir"
  [[ "$matches" == "1" ]] || fail "Remote release assets differ. They will not be overwritten."
}

publish_release() {
  validate_source
  if [[ -n "$RELEASE_ID" ]]; then
    verify_remote_assets
  else
    git push --atomic origin "$SOURCE_COMMIT:refs/heads/$DEFAULT_BRANCH" "refs/tags/$TAG_VALUE"
    local notes_args=(--generate-notes)
    if [[ -n "${RELEASE_NOTES:-}" ]]; then
      notes_args=(--notes "$RELEASE_NOTES")
    fi
    gh release create "$TAG_VALUE" "$ZIP_PATH" "$CHECKSUM_PATH" --repo "$APP_REPO" \
      --verify-tag --title "utisuna $VERSION" "${notes_args[@]}"
    verify_remote_assets
  fi
  printf '==> GitHub release assets verified; updating tap\n' >&2
  [[ "$(git -C "$HOMEBREW_TAP_PATH" rev-parse HEAD)" == "$TAP_HEAD" ]] ||
    fail "Tap HEAD changed during publication. Keep the archive and retry with --resume."
  [[ -z "$(git -C "$HOMEBREW_TAP_PATH" status --porcelain)" ]] ||
    fail "Tap changed during publication. Keep the archive and retry with --resume."
  mkdir -p "$HOMEBREW_TAP_PATH/Formula"
  cp "$FORMULA_PATH" "$HOMEBREW_TAP_PATH/Formula/utisuna.rb"
  git -C "$HOMEBREW_TAP_PATH" add -- Formula/utisuna.rb
  if ! git -C "$HOMEBREW_TAP_PATH" diff --cached --quiet -- Formula/utisuna.rb; then
    git -C "$HOMEBREW_TAP_PATH" commit --only -m "utisuna $VERSION" \
      -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" -- Formula/utisuna.rb
  fi
  local tap_commit
  tap_commit="$(git -C "$HOMEBREW_TAP_PATH" rev-parse HEAD)"
  printf '%s\n' "$tap_commit" > "$ZIP_PATH.tap-commit"
  git -C "$HOMEBREW_TAP_PATH" push origin "$tap_commit:refs/heads/$DEFAULT_BRANCH" ||
    fail "Release exists, but tap push failed. Keep these artifacts and retry with --resume; do not rebuild."
}

init_release "${1:-}"
validate_source
if [[ "$RESUME" == "1" ]]; then
  verify_archive
fi
if [[ "$PUBLISH" == "1" ]]; then
  preflight_publish
fi
if [[ "$RESUME" == "0" ]]; then
  if [[ "$NOTARIZE" == "1" ]]; then
    require_notary_settings
  fi
  create_archive
fi
verify_archive
write_formula
if [[ "$PUBLISH" == "1" ]]; then
  publish_release
fi
printf 'Archive: %s\nChecksum: %s\nFormula: %s\n' "$ZIP_PATH" "$CHECKSUM_PATH" "$FORMULA_PATH"
