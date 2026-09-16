#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/release-common.sh
source "$(dirname "$0")/release-common.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: scripts/notarize.sh [tag]

Build, sign and notarize one arm64 archive. Never publish or update a tap.
The worktree must be clean and HEAD must match the tag (or TAG environment).

Required: SIGN_IDENTITY and an existing NOTARY_PROFILE keychain profile.
Optional: BUILD_DIR, ARTIFACTS_DIR, CONFIGURATION, SWIFT, OUTPUT_BASENAME.
Existing artifacts are never overwritten. To publish an accepted archive:
  scripts/release.sh --resume <tag>
EOF
  exit 0
fi
[[ $# -le 1 ]] || fail "Expected at most one release tag."
NOTARIZE=1
init_release "${1:-}"
validate_source
require_notary_settings
create_archive
verify_archive
write_formula
printf 'Notarized archive: %s\nChecksum: %s\nFormula: %s\n' "$ZIP_PATH" "$CHECKSUM_PATH" "$FORMULA_PATH"
