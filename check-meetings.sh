#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
default_sdk=$(xcrun --sdk macosx --show-sdk-path)
macos_major=$(sw_vers -productVersion | cut -d . -f 1)
matching_sdk="$(dirname "$default_sdk")/MacOSX${macos_major}.sdk"
sdk_path=${SDKROOT:-$default_sdk}
if [ -z "${SDKROOT:-}" ] && [ -d "$matching_sdk" ]; then sdk_path=$matching_sdk; fi
mkdir -p "$project_dir/.build"
swiftc -sdk "$sdk_path" -swift-version 6 -parse-as-library \
    "$project_dir/Sources/MemoOnDesktop/MeetingModels.swift" \
    "$project_dir/Tests/MeetingChecks.swift" \
    -o "$project_dir/.build/meeting-checks"
"$project_dir/.build/meeting-checks"
