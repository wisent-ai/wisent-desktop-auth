#!/bin/bash
set -euo pipefail

: "${WISENT_VERSION:?WISENT_VERSION is required}"
: "${WISENT_SOURCE_DIR:?WISENT_SOURCE_DIR is required}"
: "${WISENT_OUTPUT_DIR:?WISENT_OUTPUT_DIR is required}"
: "${WISENT_PLATFORM:?WISENT_PLATFORM is required}"
[ "$WISENT_PLATFORM" = "darwin-arm64" ] || { printf 'unsupported platform: %s\n' "$WISENT_PLATFORM" >&2; exit 1; }

work="$WISENT_OUTPUT_DIR/work"
source="$work/source"
rm -rf "$work"
# Throwaway state is removed by the code that made it: the source copy and
# the SwiftPM scratch tree end with the run.
trap 'rm -rf "$work"' EXIT
mkdir -p "$source"
rsync -a --exclude .git --exclude .build "$WISENT_SOURCE_DIR/" "$source/"

swift build --package-path "$source" --scratch-path "$work/swift" --configuration release --disable-automatic-resolution

case "${1:-}" in
  compile) exit 0 ;;
  build) ;;
  *) printf 'usage: %s {compile|build}\n' "$0" >&2; exit 64 ;;
esac

dist="$WISENT_OUTPUT_DIR/dist"
mkdir -p "$dist"
# The worker builds an unpacked git archive, which has no repository to ask:
# the source archive is made from the clean copy this run built, and the
# commit is the one the release names.
packaged="$work/wisent-desktop-auth-$WISENT_VERSION"
mv "$source" "$packaged"
stado product tree-archive --source "$packaged" --output "$dist/wisent-desktop-auth-source.tar.gz"
printf '%s\n' "${WISENT_SOURCE_COMMIT:?WISENT_SOURCE_COMMIT is required}" > "$dist/SOURCE_REVISION"
source_sha="$(shasum -a 256 "$dist/wisent-desktop-auth-source.tar.gz" | awk '{print $1}')"
printf '{"schema_version":1,"product":"wisent-desktop-auth","version":"%s","platform":"%s","source_sha256":"%s"}\n' "$WISENT_VERSION" "$WISENT_PLATFORM" "$source_sha" > "$dist/build-evidence.json"
