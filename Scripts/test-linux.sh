#!/bin/bash
# Run the package tests on Linux in Apple's container: bash Scripts/test-linux.sh [--static] [package...]
# --static also builds latch-server for x86_64 and aarch64 musl with the Static Linux SDK and runs
# the executable tests against the one for this machine.
set -euo pipefail

usage() {
    echo 'usage: bash Scripts/test-linux.sh [--static] [LatchACP|LatchServiceProtocol|LatchAgentCore ...]' >&2
    exit 2
}
fail() { echo "LINUX: $1" >&2; exit 1; }

image=swift:6.4.0-noble
sdk_url=https://download.swift.org/swift-6.4.0-release/static-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
sdk_checksum=47d2fd89eebfdf9eb4d536b6710414297f755c17926cdebc4742c08982b40a9e
sdk_bundle=swift-6.4.0-RELEASE_static-linux-0.1.0
# The SDK is large; keep it in a volume rather than downloading it on every run or onto the Mac.
# Scripts/build-linux-server.sh pins the same image and SDK; change both together.
sdk_volume=latch-swiftpm

static=0
packages=()
for argument in "$@"; do
    package="${argument#Packages/}"
    package="${package%/}"
    case "$package" in
        --static) static=1 ;;
        LatchACP | LatchServiceProtocol | LatchAgentCore) packages+=("$package") ;;
        *) usage ;;
    esac
done
if [[ ${#packages[@]} -eq 0 ]]; then packages=(LatchACP LatchServiceProtocol LatchAgentCore); fi

command -v container > /dev/null || fail "Apple's container CLI is not installed: https://github.com/apple/container"
status="$(container system status 2> /dev/null || true)"
[[ "$status" =~ status[[:space:]]+running ]] || fail 'the container system service is not running; start it with: container system start'

root="$(cd "$(dirname "$0")/.." && pwd)"
mounts=(-v "$root:/src")
if [[ $static -eq 1 ]]; then
    container volume inspect "$sdk_volume" > /dev/null 2>&1 || container volume create "$sdk_volume" > /dev/null
    mounts+=(-v "$sdk_volume:/root/.swiftpm")
fi

# One container runs everything in sequence. Scratch paths under .build/linux keep it away from the macOS builds.
container run --rm --memory 4g --cpus 4 "${mounts[@]}" -w /src "$image" bash -c '
    set -euo pipefail
    static="$1" sdk_url="$2" sdk_checksum="$3" sdk_bundle="$4"
    shift 4
    for package in "$@"; do
        echo "== swift test $package"
        swift test --package-path "Packages/$package" --scratch-path ".build/linux/$package"
    done
    if [[ "$static" -eq 1 ]]; then
        if ! swift sdk list | grep -Fx "$sdk_bundle" > /dev/null; then
            swift sdk install "$sdk_url" --checksum "$sdk_checksum"
        fi
        for arch in x86_64 aarch64; do
            echo "== static build latch-server for $arch"
            swift build --package-path Packages/LatchAgentCore --scratch-path .build/linux/static \
                --swift-sdk "$arch-swift-linux-musl" -c release --product latch-server
        done
        # musl threads have other stacks than glibc ones; run the binary itself.
        echo "== swift test LatchServerExecutableTests against the static $(uname -m) latch-server"
        LATCH_SERVER_BINARY="$(swift build --package-path Packages/LatchAgentCore --scratch-path .build/linux/static \
            --swift-sdk "$(uname -m)-swift-linux-musl" -c release --show-bin-path)/latch-server" \
            swift test --package-path Packages/LatchAgentCore --scratch-path .build/linux/LatchAgentCore \
            --filter LatchServerExecutableTests
    fi
' bash "$static" "$sdk_url" "$sdk_checksum" "$sdk_bundle" "${packages[@]}"
