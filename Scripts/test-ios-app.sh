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
# Simulator builds are signed ad hoc with Configuration/Latch.entitlements, as App.xcconfig
# says, so the app and the tests it hosts use the real Keychain. No team is needed.
build() {
    xcodebuild -quiet -project "$project" -scheme 'Latch iOS' -derivedDataPath "$derived" "$@"
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
# The Simulator reads a build's entitlements from this section; without the access group every
# Keychain call fails and the app stops at launch rather than keep tokens elsewhere.
entitlements="$(mktemp "${TMPDIR:-/tmp}/latch-ios-entitlements.XXXXXX")"
xcrun segedit "$app/Latch" -extract __TEXT __entitlements "$entitlements" 2>/dev/null || true
access_group="$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$entitlements" 2>/dev/null || true)"
rm -f "$entitlements"
if [[ "$access_group" != *".$bundle_id" ]]; then
    echo "IOS APP: the Simulator build has no keychain access group for $bundle_id (got '$access_group')" >&2
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
echo "IOS APP: $configuration Simulator build signed with its keychain access group, tests built, metadata, latch:// URL scheme and layered app icon — PASS"

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
# Devices whose appearance or text size the screenshots changed: put back on every exit, even
# on a device that was booted before this run and stays booted after it.
restyled=()
console=
console_pid=
server_dir=
server_pid=
# Sends latch-server TERM and waits up to 10 s for it to exit; returns 1 if it had to be killed.
stop_server() {
    kill -TERM "$server_pid" 2>/dev/null || true
    for _ in $(seq 100); do
        if ! kill -0 "$server_pid" 2>/dev/null; then return 0; fi
        sleep 0.1
    done
    kill -KILL "$server_pid" 2>/dev/null || true
    return 1
}
cleanup() {
    if [[ -n "$console_pid" ]]; then kill "$console_pid" 2>/dev/null || true; fi
    if [[ -n "$console" ]]; then rm -f "$console"; fi
    if [[ -n "$server_pid" ]]; then stop_server || true; fi
    if [[ -n "$server_dir" ]]; then rm -rf "$server_dir"; fi
    for udid in ${restyled[@]+"${restyled[@]}"}; do
        xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
        xcrun simctl ui "$udid" appearance light 2>/dev/null || true
        xcrun simctl ui "$udid" content_size large 2>/dev/null || true
    done
    for udid in ${booted[@]+"${booted[@]}"}; do
        xcrun simctl shutdown "$udid" 2>/dev/null || true
    done
}
trap cleanup EXIT
boot() {
    if ! xcrun simctl list devices booted | grep "($1)" > /dev/null; then booted+=("$1"); fi
    xcrun simctl bootstatus "$1" -b > /dev/null
}
boot "$iphone"
boot "$ipad"

# Hosted by the app, so the Keychain test runs against the real Keychain.
build -configuration Debug -destination "id=$iphone" test-without-building
echo "IOS APP: LatchiOSUITests on Latch iPhone ($runtime_name), the real Keychain included — PASS"

# Launches the app on device $1 with the arguments after $2, and waits up to $2 seconds for it
# to exit. Leaves what it printed in $console and how it ended in $outcome.
launch() {
    local udid="$1" seconds="$2"
    shift 2
    outcome=exited
    console="$(mktemp "${TMPDIR:-/tmp}/latch-ios-console.XXXXXX")"
    xcrun simctl launch --console-pty --terminate-running-process "$udid" "$bundle_id" "$@" > "$console" 2>&1 &
    console_pid=$!
    for _ in $(seq $((seconds * 10))); do
        if ! kill -0 "$console_pid" 2>/dev/null; then break; fi
        sleep 0.1
    done
    if kill -0 "$console_pid" 2>/dev/null; then
        kill "$console_pid" 2>/dev/null || true
        xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
        outcome="did not exit within $seconds s"
    fi
    wait "$console_pid" 2>/dev/null || true
    console_pid=
}
# The console is a pty, so its lines end in CR LF.
console_lines() { tr -d '\r' < "$console" | grep "^$1" || true; }
done_with_console() {
    rm -f "$console"
    console=
}
# A fresh install: nothing saved from an earlier run, so each smoke starts from an empty list.
reinstall() {
    xcrun simctl uninstall "$1" "$bundle_id" 2>/dev/null || true
    xcrun simctl install "$1" "$app"
}

# Launches the app with --smoke-test on device $1 (called $2) and waits up to a minute for
# the line it prints before it exits.
smoke() {
    local line
    reinstall "$1"
    launch "$1" 60 --smoke-test
    line="$(console_lines 'IOS SMOKE: ')"
    printf '%s\n' "$line"
    if [[ "$outcome" != exited || "$line" != *' — PASS' ]]; then
        echo "IOS APP: the in-app smoke on $2 did not pass (the app $outcome); the console said:" >&2
        tr -d '\r' < "$console" >&2
        exit 1
    fi
    done_with_console
}
smoke "$iphone" 'Latch iPhone'
smoke "$ipad" 'Latch iPad'
echo "IOS APP: in-app smoke on Latch iPhone and Latch iPad ($runtime_name) — PASS"

# The remote smoke: a freshly built latch-server on loopback, which the Simulator shares with
# this Mac, and the app driving its own screens against it. The remote smoke is Debug only.
if [[ "$configuration" == Debug ]]; then
    swift build --package-path "$root/Packages/LatchAgentCore" --product latch-server
    server_bin="$(swift build --package-path "$root/Packages/LatchAgentCore" --product latch-server --show-bin-path)/latch-server"
    # Symbolic links resolved: the server runs the agent from the path the app writes it to.
    server_dir="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/latch-ios-server.XXXXXX")" && pwd -P)"
    server_log="$server_dir/server.log"
    "$server_bin" --listen 127.0.0.1:0 --config-dir "$server_dir/config" 2> "$server_log" &
    server_pid=$!
    port=
    for _ in $(seq 100); do
        port="$(sed -n 's/^listening on 127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' "$server_log" | head -n 1)"
        if [[ -n "$port" ]] || ! kill -0 "$server_pid" 2>/dev/null; then break; fi
        sleep 0.1
    done
    if [[ -z "$port" ]]; then
        echo "IOS APP: latch-server did not start listening:" >&2
        cat "$server_log" >&2
        exit 1
    fi
    token="$(tr -d '[:space:]' < "$server_dir/config/server-token")"

    # Runs the remote smoke on device $1 (called $2) in a folder of its own, and checks that
    # it reached the server over the network and launched two agents there, stopping none.
    remote_smoke() {
        local workspace="$server_dir/workspace-${2##* }" launched
        mkdir "$workspace"
        reinstall "$1"
        launch "$1" 180 --smoke-test-remote "latch://127.0.0.1:$port?token=$token" "$workspace"
        console_lines 'IOS SMOKE REMOTE: '
        if [[ "$outcome" != exited || -n "$(console_lines 'IOS SMOKE REMOTE: FAIL')" \
              || -z "$(console_lines 'IOS SMOKE REMOTE: .*removed the server and its Keychain token — PASS$')" ]]; then
            echo "IOS APP: the remote smoke on $2 did not pass (the app $outcome); the console said:" >&2
            tr -d '\r' < "$console" >&2
            echo "IOS APP: latch-server said:" >&2
            cat "$server_log" >&2
            exit 1
        fi
        if [[ "$(console_lines 'IOS SMOKE REMOTE: agent service transport')" != *"= remote 127.0.0.1:$port" ]]; then
            echo "IOS APP: the remote smoke on $2 did not run over the network to 127.0.0.1:$port" >&2
            exit 1
        fi
        done_with_console
        # Removing the server detaches; the agents run on until the server stops.
        launched="$(grep -c '^runtime .* launched: sh$' "$server_log" || true)"
        if [[ "$launched" != "$3" ]] || grep -Eq '^runtime .* (stopped|exited)' "$server_log"; then
            echo "IOS APP: after the remote smoke on $2, latch-server had not launched $3 agents and stopped none:" >&2
            cat "$server_log" >&2
            exit 1
        fi
    }
    remote_smoke "$iphone" 'Latch iPhone' 2
    remote_smoke "$ipad" 'Latch iPad' 4

    if grep -Eq 'rejected|refused|failed' "$server_log"; then
        echo "IOS APP: latch-server refused or failed something during the remote smoke:" >&2
        cat "$server_log" >&2
        exit 1
    fi
    if ! stop_server; then
        echo "IOS APP: latch-server did not exit within 10 s of TERM:" >&2
        cat "$server_log" >&2
        exit 1
    fi
    server_status=0
    wait "$server_pid" || server_status=$?
    server_pid=
    if [[ "$server_status" != 0 || "$(grep -c '^runtime .* stopped$' "$server_log" || true)" != 4 ]]; then
        echo "IOS APP: latch-server did not stop its four agents and exit cleanly (status $server_status):" >&2
        cat "$server_log" >&2
        exit 1
    fi
    echo "IOS APP: remote smoke against latch-server on 127.0.0.1:$port, on Latch iPhone and Latch iPad — PASS"
fi

# Every --ui-fixture screen on each device, in light and dark, and a few at an accessibility
# text size: <device>-<screen>-<appearance>[-<size>].png. Debug only, as the fixtures are.
if [[ -n "$screenshots" && "$configuration" == Debug ]]; then
    mkdir -p "$screenshots"
    shell_screens='onboarding sessions new-session servers server-add server-edit banner'
    session_screens='conversation markdown streaming photos slash permission question plan-approval reconnecting error empty subagents plan queue resume'
    large_screens='sessions conversation streaming permission question new-session'
    large_size=accessibility-extra-large
    # The largest size, where a sheet's controls are likeliest to fall out of sight.
    largest_screens='new-session permission question'
    largest_size=accessibility-extra-extra-extra-large
    # Shows fixture $2 on device $1 and saves the screen as $3.
    capture() {
        local line
        console="$(mktemp "${TMPDIR:-/tmp}/latch-ios-console.XXXXXX")"
        xcrun simctl launch --console-pty --terminate-running-process "$1" "$bundle_id" --ui-fixture "$2" \
            > "$console" 2>&1 &
        console_pid=$!
        for _ in $(seq 150); do
            line="$(console_lines "UI FIXTURE: $2 ready")"
            if [[ -n "$line" ]] || ! kill -0 "$console_pid" 2>/dev/null; then break; fi
            sleep 0.1
        done
        if [[ -z "$line" ]]; then
            echo "IOS APP: the $2 fixture did not come up; the console said:" >&2
            tr -d '\r' < "$console" >&2
            exit 1
        fi
        # Sheets, banners and the keyboard finish arriving.
        sleep 1.5
        xcrun simctl io "$1" screenshot "$3" > /dev/null 2>&1
        kill "$console_pid" 2>/dev/null || true
        wait "$console_pid" 2>/dev/null || true
        console_pid=
        done_with_console
    }
    count=0
    for device in "iphone:$iphone" "ipad:$ipad"; do
        name="${device%%:*}"
        udid="${device#*:}"
        screens="$shell_screens $session_screens"
        if [[ "$name" == ipad ]]; then screens="$screens split"; fi
        restyled+=("$udid")
        xcrun simctl ui "$udid" content_size large
        for appearance in light dark; do
            xcrun simctl ui "$udid" appearance "$appearance"
            for screen in $screens; do
                capture "$udid" "$screen" "$screenshots/$name-$screen-$appearance.png"
                count=$((count + 1))
            done
        done
        xcrun simctl ui "$udid" appearance light
        xcrun simctl ui "$udid" content_size "$large_size"
        for screen in $large_screens; do
            capture "$udid" "$screen" "$screenshots/$name-$screen-light-$large_size.png"
            count=$((count + 1))
        done
        xcrun simctl ui "$udid" content_size "$largest_size"
        for screen in $largest_screens; do
            capture "$udid" "$screen" "$screenshots/$name-$screen-light-$largest_size.png"
            count=$((count + 1))
        done
        xcrun simctl ui "$udid" content_size large
        xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
    done
    echo "IOS APP: $count screenshots in $screenshots"
elif [[ -n "$screenshots" ]]; then
    echo 'IOS APP: NOTE --screenshots needs a Debug build, which has the fixtures; none were taken'
fi
