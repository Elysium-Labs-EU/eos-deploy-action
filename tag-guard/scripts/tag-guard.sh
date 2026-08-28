#!/bin/bash
set -euo pipefail

VERSION="${VERSION:?VERSION must be set}"
REPOSITORY="${REPOSITORY:?REPOSITORY must be set}"
GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
export GITHUB_TOKEN

# A pre-release always ranks below the stable release with the same
# MAJOR.MINOR.PATCH (semver), so a "-rc.N" tag cut after that version
# already shipped stable is permanently unreachable to any update
# check — silently. Block both that case and exact tag reuse.
BASE="${VERSION%%-*}"
IS_PRE=false
[[ "$VERSION" =~ -[a-zA-Z] ]] && IS_PRE=true

if gh release view "$VERSION" --repo "$REPOSITORY" >/dev/null 2>&1; then
  echo "::error::Tag $VERSION already has a release — refusing to re-tag/overwrite."
  exit 1
fi

if [ "$IS_PRE" = true ] && gh release view "$BASE" --repo "$REPOSITORY" --json isPrerelease -q '.isPrerelease' 2>/dev/null | grep -qx false; then
  NEXT_PATCH="${BASE%.*}.$(( ${BASE##*.} + 1 ))"
  echo "::error::$BASE already shipped as a stable release. A pre-release of it ($VERSION) can never be selected as an update target. Cut the next pre-release against an unreleased version instead, e.g. $NEXT_PATCH-rc.1"
  exit 1
fi

echo "OK: $VERSION does not reuse an already-released version line."
