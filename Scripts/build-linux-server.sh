#!/bin/bash
# Build static musl latch-server binaries for x86_64 and aarch64 Linux in Apple's container:
# bash Scripts/build-linux-server.sh. They land in .build/linux-server/latch-server-<arch>
# and run on any Linux distribution of that architecture, glibc or musl.
set -euo pipefail

fail() { echo "LINUX SERVER: $1" >&2; exit 1; }

# Pinned with Scripts/test-linux.sh; change both together.
image=swift:6.4.0-noble
sdk_url=https://download.swift.org/swift-6.4.0-release/static-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
sdk_checksum=47d2fd89eebfdf9eb4d536b6710414297f755c17926cdebc4742c08982b40a9e
sdk_bundle=swift-6.4.0-RELEASE_static-linux-0.1.0
sdk_volume=latch-swiftpm

[[ $# -eq 0 ]] || { echo 'usage: bash Scripts/build-linux-server.sh' >&2; exit 2; }
command -v container > /dev/null || fail "Apple's container CLI is not installed: https://github.com/apple/container"
status="$(container system status 2> /dev/null || true)"
[[ "$status" =~ status[[:space:]]+running ]] || fail 'the container system service is not running; start it with: container system start'

root="$(cd "$(dirname "$0")/.." && pwd)"
container volume inspect "$sdk_volume" > /dev/null 2>&1 || container volume create "$sdk_volume" > /dev/null

container run --rm --memory 4g --cpus 4 -v "$root:/src" -v "$sdk_volume:/root/.swiftpm" -w /src "$image" bash -c '
    set -euo pipefail
    sdk_url="$1" sdk_checksum="$2" sdk_bundle="$3"
    if ! swift sdk list | grep -Fx "$sdk_bundle" > /dev/null; then
        swift sdk install "$sdk_url" --checksum "$sdk_checksum"
    fi
    mkdir -p .build/linux-server
    for arch in x86_64 aarch64; do
        echo "== static build latch-server for $arch"
        swift build --package-path Packages/LatchAgentCore --scratch-path .build/linux/static \
            --swift-sdk "$arch-swift-linux-musl" -c release --product latch-server
        binary="$(swift build --package-path Packages/LatchAgentCore --scratch-path .build/linux/static \
            --swift-sdk "$arch-swift-linux-musl" -c release --show-bin-path)/latch-server"
        # Debug info is most of an unstripped binary; the symbol table stays, so a crash
        # report or a debugger can still name functions.
        llvm-objcopy --strip-debug "$binary" ".build/linux-server/latch-server-$arch"
    done
    # The binary for this machine must start. Package.swift asks for 8 MiB thread stacks,
    # which musl takes from PT_GNU_STACK; without them nested JSON overflows a reader thread.
    native="$(uname -m)"
    ".build/linux-server/latch-server-$native" --version
    for arch in x86_64 aarch64; do
        readelf -lW ".build/linux-server/latch-server-$arch" | grep "GNU_STACK .* 0x0*800000 " > /dev/null ||
            { echo "latch-server-$arch: PT_GNU_STACK does not ask for 8 MiB stacks" >&2; exit 1; }
    done
    ls -l .build/linux-server
' bash "$sdk_url" "$sdk_checksum" "$sdk_bundle"

echo "LINUX SERVER: built $root/.build/linux-server/latch-server-{x86_64,aarch64}"
