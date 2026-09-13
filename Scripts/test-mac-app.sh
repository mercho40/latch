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
require_plist CFBundleIdentifier sh.latch.mac
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
if ! xcrun assetutil --info "$app/Contents/Resources/Assets.car" | grep -q IconImageStack; then
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
trap 'rm -f "$entitlements"' EXIT
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
require_service_plist CFBundleIdentifier sh.latch.mac.agent
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
