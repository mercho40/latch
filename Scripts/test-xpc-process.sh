#!/bin/bash
set -euo pipefail

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--live-codex" ) ]]; then
    echo 'usage: bash Scripts/test-xpc-process.sh [--live-codex]' >&2
    exit 2
fi
if [[ $# -eq 1 ]]; then
    echo 'Live Codex mode: uses the local login, network access, and model quota.'
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
package="$root/Packages/LatchAgentCore"
swift build --package-path "$package" --product LatchXPCProcessProbe
bin="$(swift build --package-path "$package" --show-bin-path)"
staging="$(mktemp -d "${TMPDIR:-/tmp}/latch-xpc-process.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/LatchXPCProcessProbe.app"
service="$app/Contents/XPCServices/dev.latchapp.process-probe.service.xpc"
mkdir -p "$app/Contents/MacOS" "$service/Contents/MacOS"
cp "$bin/LatchXPCProcessProbe" "$app/Contents/MacOS/LatchXPCProcessProbe"
cp "$bin/LatchXPCProcessProbe" "$service/Contents/MacOS/LatchXPCProcessProbe"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.latchapp.process-probe</string>
<key>CFBundleExecutable</key><string>LatchXPCProcessProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
cat > "$service/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.latchapp.process-probe.service</string>
<key>CFBundleExecutable</key><string>LatchXPCProcessProbe</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleVersion</key><string>1</string>
<key>XPCService</key><dict>
<key>ServiceType</key><string>Application</string>
<key>RunLoopType</key><string>dispatch_main</string>
</dict>
</dict></plist>
PLIST

/usr/bin/codesign --force --sign - "$service"
/usr/bin/codesign --force --sign - "$app"
"$app/Contents/MacOS/LatchXPCProcessProbe" "$@"
