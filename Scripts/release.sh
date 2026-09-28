#!/bin/bash
# Build, verify, and publish a release: bash Scripts/release.sh [--dry-run] <version>
# A dry run does everything except tag, push, and create the GitHub release.
# Besides the Mac app it builds latch-server for Linux, which needs Apple's container tool.
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
for config in Apps/LatchMac/Configuration/App.xcconfig Apps/LatchMac/Configuration/AgentService.xcconfig \
    Apps/LatchiOS/Configuration/App.xcconfig; do
    configured="$(sed -n 's/^MARKETING_VERSION = //p' "$config")"
    [[ "$configured" == "$version" ]] || fail "$config has MARKETING_VERSION = $configured, not $version; commit the bump first"
done
# latch-server reports its own version in the welcome; a server and the app from one release must agree.
server_version_file=Packages/LatchAgentCore/Sources/LatchAgentServer/LatchServerVersion.swift
server_version="$(sed -n 's/^ *public static let current = "\(.*\)"$/\1/p' "$server_version_file")"
[[ "$server_version" == "$version" ]] ||
    fail "$server_version_file has LatchServerVersion.current = \"$server_version\", not $version; commit the bump first"
# Checked before the long Mac build: Scripts/build-linux-server.sh runs in a Linux container.
command -v container > /dev/null ||
    fail "Apple's container tool is needed to build latch-server for Linux: https://github.com/apple/container"
[[ "$(container system status 2> /dev/null || true)" =~ status[[:space:]]+running ]] ||
    fail 'the container system service is not running; start it with: container system start'

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

# latch-server for Linux: static musl binaries, one per tarball holding only the executable.
bash Scripts/build-linux-server.sh
linux_assets=()
checksums="$digest  $archive"
for arch in x86_64 aarch64; do
    binary="$root/.build/linux-server/latch-server-$arch"
    [[ -x "$binary" ]] || fail "Scripts/build-linux-server.sh left no $binary"
    # e_machine in the ELF header: 0x3e is x86_64, 0xb7 aarch64.
    expected_machine="$([[ $arch == x86_64 ]] && echo 3e00 || echo b700)"
    machine="$(/usr/bin/xxd -s 18 -l 2 -p "$binary")"
    [[ "$(/usr/bin/head -c 4 "$binary" | /usr/bin/xxd -p)" == 7f454c46 && "$machine" == "$expected_machine" ]] ||
        fail "latch-server-$arch is not a Linux $arch executable"
    tarball="latch-server-$version-linux-$arch.tar.gz"
    stage="$check/linux-$arch"
    mkdir -p "$stage"
    /usr/bin/install -m 755 "$binary" "$stage/latch-server"
    COPYFILE_DISABLE=1 /usr/bin/tar -czf "$out/$tarball" --no-mac-metadata --no-xattrs --uid 0 --gid 0 --uname root --gname root \
        -C "$stage" latch-server
    listing="$(/usr/bin/tar -tzf "$out/$tarball")"
    [[ "$listing" == latch-server ]] || fail "$tarball holds $(echo "$listing" | tr '\n' ' ')rather than latch-server alone"
    (cd "$out" && /usr/bin/shasum -a 256 "$tarball" > "$tarball.sha256")
    linux_digest="$(cut -d ' ' -f 1 "$out/$tarball.sha256")"
    checksums+=$'\n'"$linux_digest  $tarball"
    linux_assets+=("$out/$tarball" "$out/$tarball.sha256")
    echo "RELEASE: $tarball $(/usr/bin/stat -f %z "$out/$tarball") bytes, sha256 $linux_digest"
done
# What a user unpacks must say it is this release. This Mac runs the aarch64 one in a container.
unpacked="$check/linux-unpacked"
mkdir -p "$unpacked"
/usr/bin/tar -xzf "$out/latch-server-$version-linux-aarch64.tar.gz" -C "$unpacked"
reported="$(container run --rm --arch arm64 -v "$unpacked:/release" swift:6.4.0-noble /release/latch-server --version)"
[[ "$reported" == "latch-server $version" ]] || fail "the aarch64 latch-server reports \"$reported\", not latch-server $version"
echo "RELEASE: latch-server-$version-linux-aarch64 reports \"$reported\" in a container"

if [[ $dry_run -eq 1 ]]; then
    echo "RELEASE: dry run; artifacts are in ${out#"$root"/}. Nothing was tagged or published."
    exit 0
fi

git tag -a "$tag" -m "Latch $version"
git push --quiet origin "$tag"
gh release create "$tag" "$out/$archive" "$out/$archive.sha256" "$out/$symbols" "${linux_assets[@]}" \
    --title "Latch $version" --generate-notes \
    --notes "Apple silicon, macOS 15 or later. Ad-hoc signed and not notarized; see the README for how to install.

latch-server for Linux on x86_64 and aarch64 is in the latch-server tarballs, static binaries for any distribution; see docs/server.md.

\`\`\`
$checksums
\`\`\`"
echo "RELEASE: published $tag"
