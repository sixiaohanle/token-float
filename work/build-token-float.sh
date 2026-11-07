#!/bin/bash
set -euo pipefail

work_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_dir="$(cd "$work_dir/.." && pwd)/outputs"
display_name="Token 悬浮球"
minimum_version="13.0"
architecture="$(uname -m)"
build_dir="$(mktemp -d "$work_dir/token-float-build.XXXXXXXX")"
trap 'find "$build_dir" -depth -delete' EXIT

app="$build_dir/$display_name.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources" "$output_dir"
cp "$work_dir/assets/KittenRun60.png" "$work_dir/assets/KittenStart60.png" \
    "$work_dir/assets/KittenStop60.png" "$contents/Resources/"
cp "$work_dir/../LICENSE" "$contents/Resources/LICENSE"

xcrun swiftc "$work_dir/GenerateIcon.swift" -o "$build_dir/generate-icon"
"$build_dir/generate-icon" "$build_dir/TokenFloat.iconset"
iconutil -c icns "$build_dir/TokenFloat.iconset" -o "$contents/Resources/TokenFloat.icns"

xcrun swiftc -O -target "$architecture-apple-macosx$minimum_version" \
    "$work_dir/main.swift" "$work_dir/TokenFloatUI.swift" "$work_dir/DetailSessionScroll.swift" \
    "$work_dir/RunningCat.swift" "$work_dir/CodexMeter.swift" \
    "$work_dir/DailyTokenUsage.swift" "$work_dir/ClaudeCodeMeter.swift" "$work_dir/ProviderModels.swift" \
    "$work_dir/MeterSettings.swift" "$work_dir/MeterApplication.swift" "$work_dir/UsageHistory.swift" \
    "$work_dir/GitHubUpdateChecker.swift" \
    -lsqlite3 -o "$contents/MacOS/TokenFloat"

cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleDisplayName</key>
    <string>$display_name</string>
    <key>CFBundleExecutable</key>
    <string>TokenFloat</string>
    <key>CFBundleIconFile</key>
    <string>TokenFloat.icns</string>
    <key>CFBundleIdentifier</key>
    <string>com.xiaohan.codex-token-float</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$display_name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.7.6</string>
    <key>CFBundleVersion</key>
    <string>17</string>
    <key>LSMinimumSystemVersion</key>
    <string>$minimum_version</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "$contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"

destination="$output_dir/$display_name.app"
if [[ -e "$destination" ]]; then
    previous_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$previous_id" != "com.xiaohan.codex-token-float" ]]; then
        printf 'Another application occupies %s\n' "$destination" >&2
        exit 1
    fi
    mv "$destination" "$build_dir/previous.app"
fi
if ! mv "$app" "$destination"; then
    if [[ -e "$build_dir/previous.app" ]]; then
        mv "$build_dir/previous.app" "$destination"
    fi
    exit 1
fi
printf '%s\n' "$destination"
