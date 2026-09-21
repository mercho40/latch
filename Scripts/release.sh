#!/bin/bash
# Build, verify, and publish a release: bash Scripts/release.sh [--dry-run] <version>
# A dry run does everything except tag, push, and create the GitHub release.
set -euo pipefail

dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then dry_run=1; shift; fi
if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo 'usage: bash Scripts/release.sh [--dry-run] <major.minor.patch>' >&2
    exit 2
fi
version="$1"
tag="v$version"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

fail() { echo "RELEASE: $1" >&2; exit 1; }

# The tag must name exactly what is on the remote's main, or the release notes and the binary disagree.
if [[ -n "$(git status --porcelain)" ]]; then fail 'the working tree is not clean'; fi
if [[ $dry_run -eq 0 ]]; then
    [[ "$(git branch --show-current)" == main ]] || fail 'releases are cut from main'
    git fetch --quiet origin main
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail 'main is not in sync with origin/main'
    if git rev-parse --quiet --verify "refs/tags/$tag" > /dev/null; then fail "tag $tag already exists"; fi
    gh auth status > /dev/null 2>&1 || fail 'gh is not authenticated'
fi
for config in Apps/LatchMac/Configuration/App.xcconfig Apps/LatchMac/Configuration/AgentService.xcconfig; do
    configured="$(sed -n 's/^MARKETING_VERSION = //p' "$config")"
    [[ "$configured" == "$version" ]] || fail "$config has MARKETING_VERSION = $configured, not $version; commit the bump first"
done

bash Scripts/test-mac-app.sh --release

products="$root/.build/LatchMacApp/Build/Products/Release"
app="$products/Latch.app"
built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$built" == "$version" ]] || fail "the built app reports version $built"

out="$root/.build/release/$tag"
rm -rf "$out"
mkdir -p "$out"
archive="Latch-$version.zip"
symbols="Latch-$version.dSYM.zip"
/usr/bin/ditto -c -k --keepParent "$app" "$out/$archive"
(cd "$products" && /usr/bin/zip -qry "$out/$symbols" Latch.app.dSYM LatchAgentXPCService.xpc.dSYM)

# A zip that does not unpack to a validly signed app is what users would actually receive.
check="$(mktemp -d "${TMPDIR:-/tmp}/latch-release.XXXXXX")"
trap 'rm -rf "$check"' EXIT
/usr/bin/ditto -x -k "$out/$archive" "$check"
/usr/bin/codesign --verify --deep --strict "$check/Latch.app" || fail 'the archived app does not verify'

(cd "$out" && /usr/bin/shasum -a 256 "$archive" > "$archive.sha256")
digest="$(cut -d ' ' -f 1 "$out/$archive.sha256")"
echo "RELEASE: $archive $(/usr/bin/stat -f %z "$out/$archive") bytes, sha256 $digest"

if [[ $dry_run -eq 1 ]]; then
    echo "RELEASE: dry run; artifacts are in ${out#"$root"/}. Nothing was tagged or published."
    exit 0
fi

git tag -a "$tag" -m "Latch $version"
git push --quiet origin "$tag"
gh release create "$tag" "$out/$archive" "$out/$archive.sha256" "$out/$symbols" \
    --title "Latch $version" --generate-notes \
    --notes "Apple silicon, macOS 15 or later. Ad-hoc signed and not notarized; see the README for how to install.

\`\`\`
$digest  $archive
\`\`\`"
echo "RELEASE: published $tag"
