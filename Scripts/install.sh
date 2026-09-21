#!/bin/sh
# Install or update Latch from a GitHub release:
#   curl -fsSL https://latchapp.dev/install.sh | sh
#
# LATCH_VERSION=0.1.0   install that release instead of the latest
# LATCH_INSTALL_DIR=... install somewhere other than /Applications
#
# curl does not mark what it downloads as quarantined, so the ad-hoc-signed app opens without a
# Gatekeeper prompt. The checksum is fetched from the same release as the archive: it catches a
# corrupted download, not a compromised release.
set -eu

repo="mercho40/latch"
base="${LATCH_DOWNLOAD_BASE:-https://github.com/$repo/releases}"

fail() { echo "latch: $1" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail 'Latch is a macOS app'
[ "$(uname -m)" = arm64 ] || fail 'Latch requires Apple silicon'
major="$(sw_vers -productVersion | cut -d . -f 1)"
[ "$major" -ge 15 ] || fail 'Latch requires macOS 15 or later'

version="${LATCH_VERSION:-}"
if [ -z "$version" ]; then
    # The latest release redirects to its tag, which avoids the rate-limited API and parsing JSON in sh.
    latest="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$base/latest")" || fail 'could not look up the latest release'
    case "$latest" in
        */tag/v*) version="${latest##*/tag/v}" ;;
        *) fail 'there is no published release yet; build from source as the README describes' ;;
    esac
fi
archive="Latch-$version.zip"

work="$(mktemp -d "${TMPDIR:-/tmp}/latch-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT
echo "latch: downloading $version"
curl -fsSL -o "$work/$archive" "$base/download/v$version/$archive" || fail "could not download $archive"
curl -fsSL -o "$work/$archive.sha256" "$base/download/v$version/$archive.sha256" || fail 'could not download the checksum'
(cd "$work" && shasum -a 256 -c "$archive.sha256" > /dev/null 2>&1) || fail 'the checksum does not match'

ditto -x -k "$work/$archive" "$work/unpacked"
new="$work/unpacked/Latch.app"
[ -d "$new" ] || fail 'the archive does not contain Latch.app'
codesign --verify --deep --strict "$new" || fail 'the app does not pass signature verification'
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$new/Contents/Info.plist")"

directory="${LATCH_INSTALL_DIR:-/Applications}"
if [ ! -w "$directory" ]; then
    [ -z "${LATCH_INSTALL_DIR:-}" ] || fail "$directory is not writable"
    directory="$HOME/Applications"
    mkdir -p "$directory"
fi
# The physical path, because that is what a running copy's process reports.
directory="$(cd "$directory" && pwd -P)"
target="$directory/Latch.app"

# Ask, never kill: a running Latch may be hosting agents in the middle of a turn.
is_running() { pgrep -f "^$target/Contents/MacOS/Latch" > /dev/null; }
running=0
if is_running; then
    running=1
    echo 'latch: asking the running app to quit'
    osascript -e "tell application id \"$identifier\" to quit" > /dev/null 2>&1 || true
    waited=0
    while is_running; do
        [ "$waited" -lt 20 ] || fail 'Latch is still running; quit it and run this again'
        sleep 0.5
        waited=$((waited + 1))
    done
fi

if [ -e "$target" ]; then
    mv "$target" "$work/previous.app"
fi
if ! mv "$new" "$target"; then
    [ ! -e "$work/previous.app" ] || mv "$work/previous.app" "$target"
    fail "could not install into $directory"
fi

echo "latch: installed $version at $target"
if [ "$running" -eq 1 ]; then open "$target"; else echo "latch: open it with: open \"$target\""; fi
