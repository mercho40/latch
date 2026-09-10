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
"$app/Contents/MacOS/Latch" --smoke-test
echo "MAC APP: $configuration metadata, ad-hoc signing, hardened runtime, no sandbox, and AppKit smoke — PASS"
