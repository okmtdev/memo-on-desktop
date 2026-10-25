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
    "$project_dir/Sources/MemoOnDesktop/IntegrationAPI.swift" \
    "$project_dir/Sources/MemoOnDesktop/IntegrationStore.swift" \
    "$project_dir/Sources/MemoOnDesktop/IntegrationSettingsView.swift" \
    "$project_dir/Sources/MemoOnDesktop/MeetingModels.swift" \
    "$project_dir/Sources/MemoOnDesktop/GoogleCalendarAPI.swift" \
    "$project_dir/Sources/MemoOnDesktop/GoogleOAuthFlow.swift" \
    "$project_dir/Sources/MemoOnDesktop/MeetingStore.swift" \
    "$project_dir/Sources/MemoOnDesktop/MeetingViews.swift" \
    "$project_dir/Sources/MemoOnDesktop/CalendarSelectionPicker.swift" \
    "$project_dir/Sources/MemoOnDesktop/TaskLink.swift" \
    "$project_dir/Tests/IntegrationChecks.swift" \
    -o "$project_dir/.build/integration-checks"
"$project_dir/.build/integration-checks"
