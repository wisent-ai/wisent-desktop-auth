#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:?output path is required}
SOURCE="$ROOT/Sources/WisentIdentityKeychainHelper/main.swift"

mkdir -p "$(dirname "$OUTPUT")"
TEMP=$(mktemp "$OUTPUT.building.XXXXXXXX")
trap 'rm -f "$TEMP"' EXIT
swiftc -parse-as-library -O -framework Security "$SOURCE" -o "$TEMP"
install -m 0755 "$TEMP" "$OUTPUT"
