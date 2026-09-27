#!/bin/bash
set -euo pipefail

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--release" ) ]]; then
    echo 'usage: bash Scripts/test-mac-app.sh [--release]' >&2
    exit 2
fi
configuration=Debug
if [[ $# -eq 1 ]]; then configuration=Release; fi

root="$(cd "$(dirname "$0")/.." && pwd)"
derived="$root/.build/LatchMacApp"
xcodebuild -quiet -project "$root/Apps/LatchMac/Latch.xcodeproj" \
    -scheme Latch -configuration "$configuration" \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$derived" build
app="$derived/Build/Products/$configuration/Latch.app"

require_plist() {
    local actual
    actual="$(/usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist")"
    if [[ "$actual" != "$2" ]]; then
        echo "MAC APP: expected $1=$2, got $actual" >&2
        exit 1
    fi
}
require_plist CFBundleIdentifier dev.latchapp.mac
require_plist CFBundleExecutable Latch
require_plist CFBundlePackageType APPL
require_plist LSMinimumSystemVersion 15.0
require_plist NSPrincipalClass NSApplication
require_plist CFBundleIconName Latch
# actool compiles Latch.icon into the layered asset catalog plus a legacy icns fallback.
for icon in Resources/Assets.car Resources/Latch.icns; do
    if [[ ! -s "$app/Contents/$icon" ]]; then
        echo "MAC APP: missing compiled app icon at $icon" >&2
        exit 1
    fi
done
# Drain assetutil's output: grep -q may close early and trigger SIGPIPE under pipefail.
if ! xcrun assetutil --info "$app/Contents/Resources/Assets.car" | grep IconImageStack > /dev/null; then
    echo 'MAC APP: Assets.car has no layered icon stack; Latch.icon was not compiled' >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$app"
signing="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)"
flags="${signing#* flags=}"
flags="${flags%% hashes=*}"
if [[ "$signing" != *"Signature=adhoc"* || "$flags" != *runtime* ]]; then
    echo 'MAC APP: expected ad-hoc signing with hardened runtime' >&2
    exit 1
fi
entitlements="$(mktemp "${TMPDIR:-/tmp}/latch-mac-entitlements.XXXXXX")"
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
    rm -f "$entitlements"
    if [[ -n "$server_pid" ]]; then stop_server || true; fi
    if [[ -n "$server_dir" ]]; then rm -rf "$server_dir"; fi
}
trap cleanup EXIT
/usr/bin/codesign --display --entitlements - --xml "$app" > "$entitlements"
if [[ -s "$entitlements" ]]; then
    /usr/bin/plutil -lint "$entitlements"
    sandbox="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements" 2>/dev/null || true)"
    if [[ "$sandbox" == true ]]; then
        echo 'MAC APP: arbitrary ACP subprocesses require an unsandboxed app' >&2
        exit 1
    fi
fi
service="$app/Contents/XPCServices/LatchAgentXPCService.xpc"
require_service_plist() {
    local actual
    actual="$(/usr/libexec/PlistBuddy -c "Print :$1" "$service/Contents/Info.plist")"
    if [[ "$actual" != "$2" ]]; then
        echo "MAC APP: expected service $1=$2, got $actual" >&2
        exit 1
    fi
}
require_service_plist CFBundleIdentifier dev.latchapp.mac.agent
require_service_plist CFBundlePackageType 'XPC!'
require_service_plist XPCService:ServiceType Application
# Without this the service gets its own security session and every keychain read
# fails with errSecInteractionNotAllowed, so agents report a false "not signed in".
require_service_plist XPCService:JoinExistingSession true
/usr/bin/codesign --verify --strict "$service"
service_signing="$(/usr/bin/codesign --display --verbose=4 "$service" 2>&1)"
service_flags="${service_signing#* flags=}"
service_flags="${service_flags%% hashes=*}"
if [[ "$service_signing" != *"Signature=adhoc"* || "$service_flags" != *runtime* ]]; then
    echo 'MAC APP: expected the XPC service to be ad-hoc signed with hardened runtime' >&2
    exit 1
fi
if [[ "$configuration" == Release ]]; then
    require_release_symbols() {
        local binary="$1" dsym="$2" slices binary_uuids dsym_uuids
        slices="$(/usr/bin/lipo -archs "$binary" | tr ' ' '\n' | LC_ALL=C sort | paste -sd ' ' -)"
        if [[ "$slices" != 'arm64' ]]; then
            echo "MAC APP: expected an arm64-only Release binary: $binary ($slices)" >&2
            exit 1
        fi
        if [[ ! -s "$dsym" ]]; then
            echo "MAC APP: missing Release dSYM: $dsym" >&2
            exit 1
        fi
        binary_uuids="$(xcrun dwarfdump --uuid "$binary" | awk '{print $2, $3}' | LC_ALL=C sort)"
        dsym_uuids="$(xcrun dwarfdump --uuid "$dsym" | awk '{print $2, $3}' | LC_ALL=C sort)"
        if [[ -z "$binary_uuids" || "$binary_uuids" != "$dsym_uuids" ]]; then
            echo "MAC APP: Release binary/dSYM UUID mismatch: $binary" >&2
            exit 1
        fi
        printf 'MAC APP: Release %s bytes=%s slices=%s; matching dSYM UUIDs:\n%s\n' \
            "$(basename "$binary")" "$(/usr/bin/stat -f %z "$binary")" "$slices" "$binary_uuids"
    }
    require_release_symbols "$app/Contents/MacOS/Latch" \
        "$derived/Build/Products/Release/Latch.app.dSYM/Contents/Resources/DWARF/Latch"
    require_release_symbols "$service/Contents/MacOS/LatchAgentXPCService" \
        "$derived/Build/Products/Release/LatchAgentXPCService.xpc.dSYM/Contents/Resources/DWARF/LatchAgentXPCService"
fi
smoke="$("$app/Contents/MacOS/Latch" --smoke-test)"
printf '%s\n' "$smoke"
transport_line="$(printf '%s\n' "$smoke" | grep 'agent service transport = ' || true)"
service_pid="$(printf '%s' "$transport_line" | sed -n 's/.*xpc pid \([0-9]*\).*/\1/p')"
app_pid="$(printf '%s' "$transport_line" | sed -n 's/.*app pid \([0-9]*\).*/\1/p')"
if [[ -z "$service_pid" || "$service_pid" == 0 || -z "$app_pid" || "$service_pid" == "$app_pid" ]]; then
    echo "MAC APP: smoke test did not run through a separate embedded XPC service process: $transport_line" >&2
    exit 1
fi
echo "MAC APP: $configuration metadata, ad-hoc signing, hardened runtime, no sandbox, embedded XPC service, layered app icon, and AppKit smoke over XPC — PASS"

# The remote smoke: a freshly built latch-server on loopback, a session on it through the app,
# and a quit that must leave its agent running there.
swift build --package-path "$root/Packages/LatchAgentCore" --product latch-server
server_bin="$(swift build --package-path "$root/Packages/LatchAgentCore" --product latch-server --show-bin-path)/latch-server"
server_dir="$(mktemp -d "${TMPDIR:-/tmp}/latch-server-smoke.XXXXXX")"
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
    echo "MAC APP: latch-server did not start listening:" >&2
    cat "$server_log" >&2
    exit 1
fi
token="$(tr -d '[:space:]' < "$server_dir/config/server-token")"
# The session's folder on the server, which on loopback is this Mac: inside $server_dir, so
# cleanup removes it however the app ends.
remote_workspace="$server_dir/workspace"
mkdir "$remote_workspace"
remote_status=0
remote_smoke="$("$app/Contents/MacOS/Latch" --smoke-test-remote "latch://127.0.0.1:$port?token=$token" "$remote_workspace")" \
    || remote_status=$?
printf '%s\n' "$remote_smoke"
remote_line() { printf '%s\n' "$remote_smoke" | grep "^UI SMOKE REMOTE: $1" || true; }
if [[ "$remote_status" != 0 || -z "$(remote_line '.* — PASS$')" ]]; then
    echo "MAC APP: the remote smoke did not pass (status $remote_status); latch-server said:" >&2
    cat "$server_log" >&2
    exit 1
fi
if [[ "$(remote_line 'agent service transport')" != *"= remote 127.0.0.1:$port ("* ]]; then
    echo "MAC APP: the remote smoke did not run over the network to 127.0.0.1:$port" >&2
    exit 1
fi
runtime_line="$(remote_line 'runtime ')"
runtime="$(printf '%s' "$runtime_line" | sed -n 's/^UI SMOKE REMOTE: runtime \([^ ]*\) .*/\1/p')"
agent_pid="$(printf '%s' "$runtime_line" | sed -n 's/.* agent pid \([0-9][0-9]*\) .*/\1/p')"
if [[ -z "$runtime" || -z "$agent_pid" || -z "$(remote_line "quit detached runtime $runtime ")" ]]; then
    echo "MAC APP: the remote smoke did not quit by detaching from its runtime: $runtime_line" >&2
    exit 1
fi
# Quitting Latch never stops a remote agent: the server still runs it after the app has gone.
sleep 1
if ! kill -0 "$agent_pid" 2>/dev/null || grep -Eq "^runtime $runtime (stopped|exited)" "$server_log"; then
    echo "MAC APP: quitting Latch stopped the remote agent:" >&2
    cat "$server_log" >&2
    exit 1
fi
if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "MAC APP: latch-server was gone before it was asked to stop:" >&2
    cat "$server_log" >&2
    exit 1
fi
if ! stop_server; then
    echo "MAC APP: latch-server did not exit within 10 s of TERM:" >&2
    cat "$server_log" >&2
    exit 1
fi
server_status=0
wait "$server_pid" || server_status=$?
server_pid=
if [[ "$server_status" != 0 ]] || ! grep -q "^runtime $runtime stopped$" "$server_log"; then
    echo "MAC APP: latch-server did not stop cleanly (status $server_status):" >&2
    cat "$server_log" >&2
    exit 1
fi
for _ in $(seq 50); do
    if ! kill -0 "$agent_pid" 2>/dev/null; then break; fi
    sleep 0.1
done
if kill -0 "$agent_pid" 2>/dev/null; then
    echo "MAC APP: the remote agent outlived latch-server" >&2
    exit 1
fi
echo "MAC APP: remote smoke against latch-server on 127.0.0.1:$port, and a quit that left its agent running there — PASS"
