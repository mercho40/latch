#!/bin/bash
set -euo pipefail

usage() {
    echo 'usage: bash Scripts/test-ios-app.sh [--release] [--screenshots DIR]' >&2
    exit 2
}
configuration=Debug
screenshots=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) configuration=Release; shift ;;
        --screenshots)
            if [[ $# -lt 2 || -z "$2" ]]; then usage; fi
            screenshots="$2"
            shift 2
            ;;
        *) usage ;;
    esac
done

root="$(cd "$(dirname "$0")/.." && pwd)"
derived="$root/.build/LatchiOSApp"
project="$root/Apps/LatchiOS/Latch.xcodeproj"
# Simulator builds are never signed: no team is committed, and the Simulator needs none.
build() {
    xcodebuild -quiet -project "$project" -scheme 'Latch iOS' -derivedDataPath "$derived" \
        CODE_SIGNING_ALLOWED=NO "$@"
}
build -configuration "$configuration" -destination 'generic/platform=iOS Simulator' build
# The tests import LatchiOSUI with @testable, which only a Debug build allows.
build -configuration Debug -destination 'generic/platform=iOS Simulator' build-for-testing
app="$derived/Build/Products/$configuration-iphonesimulator/Latch.app"

require_plist() {
    local actual
    actual="$(/usr/libexec/PlistBuddy -c "Print :$1" "$app/Info.plist")"
    if [[ "$actual" != "$2" ]]; then
        echo "IOS APP: expected $1=$2, got $actual" >&2
        exit 1
    fi
}
# Configuration/Local.xcconfig may set a developer's own bundle ID, so launch what was built.
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
require_plist CFBundleExecutable Latch
require_plist CFBundlePackageType APPL
require_plist CFBundleDisplayName Latch
require_plist MinimumOSVersion 18.0
require_plist CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName Latch
# A pairing link opens the app; one window, so a link always lands in the same place.
require_plist CFBundleURLTypes:0:CFBundleURLSchemes:0 latch
require_plist UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes false
if [[ -z "$(/usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' "$app/Info.plist")" ]]; then
    echo 'IOS APP: missing NSLocalNetworkUsageDescription; iOS would block the connection to a server on the LAN' >&2
    exit 1
fi
if [[ ! -s "$app/Assets.car" ]]; then
    echo 'IOS APP: missing the compiled app icon at Assets.car' >&2
    exit 1
fi
# Drain assetutil's output: grep -q may close early and trigger SIGPIPE under pipefail.
if ! xcrun assetutil --info "$app/Assets.car" | grep IconImageStack > /dev/null; then
    echo 'IOS APP: Assets.car has no layered icon stack; Latch.icon was not compiled' >&2
    exit 1
fi
echo "IOS APP: $configuration Simulator build, tests built, metadata, latch:// URL scheme and layered app icon — PASS"

# The newest installed iOS Simulator runtime. Without one there is nothing to run the app on.
runtime_line="$(xcrun simctl list runtimes available | grep '^iOS ' | sort -V | tail -n 1 || true)"
if [[ -z "$runtime_line" ]]; then
    echo 'IOS APP: NOTE no iOS Simulator runtime is installed, so the tests and the in-app smoke did not run;'
    echo 'IOS APP: NOTE install one with: xcodebuild -downloadPlatform iOS'
    exit 0
fi
runtime_name="$(printf '%s' "$runtime_line" | sed -n 's/^\(iOS [0-9.]*\) .*/\1/p')"
runtime_id="$(printf '%s' "$runtime_line" | sed -n 's/.* - \(com\.apple\.CoreSimulator\.SimRuntime\.[^ ]*\).*/\1/p')"
if [[ -z "$runtime_name" || -z "$runtime_id" ]]; then
    echo "IOS APP: could not read the Simulator runtime from: $runtime_line" >&2
    exit 1
fi

# The UDID of the available device called $1 on this runtime, if there is one.
device_named() {
    xcrun simctl list devices available | awk -v section="-- $runtime_name --" -v name="$1" '
        /^-- / { inside = ($0 == section); next }
        inside {
            line = $0
            sub(/^ +/, "", line)
            if (index(line, name " (") == 1 && match(line, /\([0-9A-F-]+\)/)) {
                print substr(line, RSTART + 1, RLENGTH - 2)
                exit
            }
        }'
}
# Reuses the device called $1, or creates it from the first of the device types in $2 (one
# per line, newest first) that this runtime supports.
ensure_device() {
    local udid type
    udid="$(device_named "$1")"
    if [[ -z "$udid" ]]; then
        while IFS= read -r type; do
            if udid="$(xcrun simctl create "$1" "$type" "$runtime_id" 2>/dev/null)"; then break; fi
            udid=
        done <<< "$2"
    fi
    if [[ -z "$udid" ]]; then
        echo "IOS APP: no device type in $runtime_name could make '$1'" >&2
        exit 1
    fi
    printf '%s\n' "$udid"
}
device_types() {
    xcrun simctl list devicetypes | sed -n "s/^$1.* (\(com\.apple\.CoreSimulator\.SimDeviceType\.[^)]*\))$/\1/p"
}
iphone="$(ensure_device 'Latch iPhone' "$(device_types iPhone)")"
# An 11-inch iPad first: the size most people hold, and a split view that still has to fit.
ipad_types="$(device_types iPad)"
ipad="$(ensure_device 'Latch iPad' "$(grep 11-inch <<< "$ipad_types" || true)"$'\n'"$ipad_types")"

booted=()
console=
console_pid=
cleanup() {
    if [[ -n "$console_pid" ]]; then kill "$console_pid" 2>/dev/null || true; fi
    if [[ -n "$console" ]]; then rm -f "$console"; fi
    for udid in ${booted[@]+"${booted[@]}"}; do xcrun simctl shutdown "$udid" 2>/dev/null || true; done
}
trap cleanup EXIT
boot() {
    if ! xcrun simctl list devices booted | grep "($1)" > /dev/null; then booted+=("$1"); fi
    xcrun simctl bootstatus "$1" -b > /dev/null
}
boot "$iphone"
boot "$ipad"

build -configuration Debug -destination "id=$iphone" test-without-building
echo "IOS APP: LatchiOSUITests on Latch iPhone ($runtime_name) — PASS"

# Launches the app with --smoke-test on device $1 (called $2) and waits up to a minute for
# the line it prints before it exits.
smoke() {
    local outcome=exited line
    xcrun simctl install "$1" "$app"
    console="$(mktemp "${TMPDIR:-/tmp}/latch-ios-smoke.XXXXXX")"
    xcrun simctl launch --console-pty --terminate-running-process "$1" "$bundle_id" --smoke-test \
        > "$console" 2>&1 &
    console_pid=$!
    for _ in $(seq 600); do
        if ! kill -0 "$console_pid" 2>/dev/null; then break; fi
        sleep 0.1
    done
    if kill -0 "$console_pid" 2>/dev/null; then
        kill "$console_pid" 2>/dev/null || true
        xcrun simctl terminate "$1" "$bundle_id" 2>/dev/null || true
        outcome='did not exit within 60 s'
    fi
    wait "$console_pid" 2>/dev/null || true
    console_pid=
    # The console is a pty, so its lines end in CR LF.
    line="$(tr -d '\r' < "$console" | grep '^IOS SMOKE: ' || true)"
    printf '%s\n' "$line"
    if [[ "$outcome" != exited || "$line" != *' — PASS' ]]; then
        echo "IOS APP: the in-app smoke on $2 did not pass (the app $outcome); the console said:" >&2
        tr -d '\r' < "$console" >&2
        exit 1
    fi
    rm -f "$console"
    console=
}
smoke "$iphone" 'Latch iPhone'
smoke "$ipad" 'Latch iPad'
echo "IOS APP: in-app smoke on Latch iPhone and Latch iPad ($runtime_name) — PASS"

# The launch screen each device shows, in light and dark, for a look at the layout.
if [[ -n "$screenshots" ]]; then
    mkdir -p "$screenshots"
    for device in "iphone:$iphone" "ipad:$ipad"; do
        udid="${device#*:}"
        for appearance in light dark; do
            xcrun simctl ui "$udid" appearance "$appearance"
            xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" > /dev/null
            sleep 3
            xcrun simctl io "$udid" screenshot "$screenshots/${device%%:*}-sessions-$appearance.png" > /dev/null 2>&1
        done
        xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
        xcrun simctl ui "$udid" appearance light
    done
    echo "IOS APP: screenshots in $screenshots"
fi
