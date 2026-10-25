#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
default_sdk=$(xcrun --sdk macosx --show-sdk-path)
macos_major=$(sw_vers -productVersion | cut -d . -f 1)
matching_sdk="$(dirname "$default_sdk")/MacOSX${macos_major}.sdk"

# Prefer the installed SDK for this macOS release over a newer default SDK.
if [ -n "${SDKROOT:-}" ]; then
    sdk_path=$SDKROOT
elif [ -d "$matching_sdk" ]; then
    sdk_path=$matching_sdk
else
    sdk_path=$default_sdk
fi

if [ ! -d "$sdk_path" ]; then
    printf 'macOS SDK が見つかりません: %s\n' "$sdk_path" >&2
    exit 1
fi

printf '使用する SDK: %s\n' "$sdk_path"
swift build --package-path "$project_dir" --sdk "$sdk_path"
bin_dir=$(swift build --package-path "$project_dir" --sdk "$sdk_path" --show-bin-path)
staging_dir=$(mktemp -d "$project_dir/.build/app.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT HUP INT TERM
staged_app="$staging_dir/MemoOnDesktop.app"
installed_app="$HOME/Applications/MemoOnDesktop.app"

mkdir -p "$staged_app/Contents/MacOS" "$HOME/Applications"
cp "$bin_dir/MemoOnDesktop" "$staged_app/Contents/MacOS/MemoOnDesktop"
cp "$project_dir/App/Info.plist" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" "$staged_app/Contents/Info.plist"
codesign --force --sign - "$staged_app"

# Restart only after the new build and bundle are ready.
pkill -x MemoOnDesktop || [ "$?" -eq 1 ]
attempts=0
while pgrep -x MemoOnDesktop >/dev/null; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 50 ]; then
        printf 'アプリが終了しないため更新を中止しました。終了してから再実行してください。\n' >&2
        exit 1
    fi
    sleep 0.1
done
ditto "$staged_app" "$installed_app"
open "$installed_app"
printf '最新版を起動しました: %s\n' "$installed_app"
