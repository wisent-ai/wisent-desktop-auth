#!/bin/bash
set -euo pipefail

ECHO_SHA256="b086ee88ca870556f738589dd5548efea515bcc4f4831fa2d36cba93465113ba"

: "${WISENT_VERSION:?WISENT_VERSION is required}"
: "${WISENT_SOURCE_DIR:?WISENT_SOURCE_DIR is required}"
: "${WISENT_OUTPUT_DIR:?WISENT_OUTPUT_DIR is required}"
: "${WISENT_PLATFORM:?WISENT_PLATFORM is required}"
: "${WISENT_INPUTS_DIR:?WISENT_INPUTS_DIR is required}"
[ "$WISENT_PLATFORM" = "darwin-arm64" ] || { printf 'unsupported platform: %s\n' "$WISENT_PLATFORM" >&2; exit 1; }

input="$WISENT_INPUTS_DIR/echo.tar.gz"
[ -f "$input" ] || { printf 'missing immutable Echo source input\n' >&2; exit 1; }
[ "$(shasum -a 256 "$input" | awk '{print $1}')" = "$ECHO_SHA256" ] || { printf 'Echo source digest mismatch\n' >&2; exit 1; }

work="$WISENT_OUTPUT_DIR/work"
source="$work/source"
rm -rf "$work"
mkdir -p "$source"
rsync -a --exclude .git --exclude .build "$WISENT_SOURCE_DIR/" "$source/"
tar -xzf "$input" -C "$work"
python3 - "$source/Package.swift" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = '.package(url: "https://github.com/wisent-ai/echo.git", from: "0.1.2"),'
new = '.package(path: "../echo"),'
if text.count(old) != 1:
    raise SystemExit("the pinned Echo package declaration was not found exactly once")
path.write_text(text.replace(old, new))
PY

swift build --package-path "$source" --scratch-path "$work/swift" --configuration release --product wisent-auth-onboarding-host --disable-automatic-resolution

case "${1:-}" in
  compile) exit 0 ;;
  build) ;;
  *) printf 'usage: %s {compile|build}\n' "$0" >&2; exit 64 ;;
esac

dist="$WISENT_OUTPUT_DIR/dist"
mkdir -p "$dist"
binary="$(swift build --package-path "$source" --scratch-path "$work/swift" --configuration release --show-bin-path)/wisent-auth-onboarding-host"
[ -x "$binary" ] || { printf 'release executable was not produced\n' >&2; exit 1; }
install -m 0755 "$binary" "$dist/wisent-auth-onboarding-host"
git -C "$WISENT_SOURCE_DIR" archive --format=tar.gz --prefix="wisent-desktop-auth-$WISENT_VERSION/" --output="$dist/wisent-desktop-auth-source.tar.gz" HEAD
git -C "$WISENT_SOURCE_DIR" rev-parse HEAD > "$dist/SOURCE_REVISION"
binary_sha="$(shasum -a 256 "$dist/wisent-auth-onboarding-host" | awk '{print $1}')"
source_sha="$(shasum -a 256 "$dist/wisent-desktop-auth-source.tar.gz" | awk '{print $1}')"
printf '{"schema_version":1,"product":"wisent-desktop-auth","version":"%s","platform":"%s","binary_sha256":"%s","source_sha256":"%s","echo_source_sha256":"%s"}\n' "$WISENT_VERSION" "$WISENT_PLATFORM" "$binary_sha" "$source_sha" "$ECHO_SHA256" > "$dist/build-evidence.json"
