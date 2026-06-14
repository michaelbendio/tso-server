#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALBQ_DIR="/Users/michaelbendio/albq"
TSO_RESOURCES_DIR="/Users/michaelbendio/tso-resources"
WWW_DIR="$ROOT_DIR/TSO/www"
BUNDLE_ID="com.michael-bendio.TSO"

DEFAULT_DEVICES=(
  "00008132-001805161A85001C"
  "6785B0DB-CB55-56FA-95F7-D51F1812FBE5"
)

DEVICES=("$@")
if [ "${#DEVICES[@]}" -eq 0 ]; then
  DEVICES=("${DEFAULT_DEVICES[@]}")
fi

require_file() {
  if [ ! -f "$1" ]; then
    echo "Missing required file: $1" >&2
    exit 1
  fi
}

require_file "$ALBQ_DIR/albq.html"
require_file "$ALBQ_DIR/albq-resource-package.zip"
require_file "$ALBQ_DIR/jszip.min.js"
require_file "$TSO_RESOURCES_DIR/tso.html"
require_file "$TSO_RESOURCES_DIR/tso-resource-package.zip"

mkdir -p "$WWW_DIR"
cp -p "$ALBQ_DIR/albq-resource-package.zip" "$WWW_DIR/albq-resource-package.zip"
cp -p "$TSO_RESOURCES_DIR/tso-resource-package.zip" "$WWW_DIR/tso-resource-package.zip"

payload_dir="$(mktemp -d)"
trap 'rm -rf "$payload_dir"' EXIT
mkdir -p "$payload_dir/TSO"

cp -p "$ALBQ_DIR/albq.html" "$payload_dir/TSO/albq.html"
cp -p "$ALBQ_DIR/albq-resource-package.zip" "$payload_dir/TSO/albq-resource-package.zip"
cp -p "$ALBQ_DIR/jszip.min.js" "$payload_dir/TSO/jszip.min.js"
cp -p "$TSO_RESOURCES_DIR/tso.html" "$payload_dir/TSO/tso.html"
cp -p "$TSO_RESOURCES_DIR/tso-resource-package.zip" "$payload_dir/TSO/tso-resource-package.zip"

xcodebuild \
  -project "$ROOT_DIR/TSO.xcodeproj" \
  -scheme TSO \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  build

app_bundle="$(
  xcodebuild \
    -project "$ROOT_DIR/TSO.xcodeproj" \
    -scheme TSO \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -showBuildSettings 2>/dev/null |
    awk -F ' = ' '
      $1 ~ /[[:space:]]*TARGET_BUILD_DIR$/ { target=$2 }
      $1 ~ /[[:space:]]*WRAPPER_NAME$/ { wrapper=$2 }
      END { if (target && wrapper) print target "/" wrapper }
    '
)"

if [ ! -d "$app_bundle" ]; then
  echo "Built app bundle was not found: $app_bundle" >&2
  exit 1
fi

for device in "${DEVICES[@]}"; do
  echo "Installing app on $device"
  xcrun devicectl device install app --device "$device" "$app_bundle"

  echo "Copying current TSO files to the app Documents folder on $device"
  xcrun devicectl device copy to \
    --device "$device" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source "$payload_dir/TSO" \
    --destination Documents \
    --remove-existing-content true
done

echo "Installed $app_bundle and copied current files to ${#DEVICES[@]} device(s)."
