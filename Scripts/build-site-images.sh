#!/bin/bash
# Rebuild site/img from the README screenshots: crop the baked-in window shadow (the page draws
# its own), flatten onto the window's colour, and write AVIF and WebP at each width the page offers.
# Needs cwebp (brew install webp); AVIF comes from sips.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# The directory is named for its contents, so the images can be cached forever and a new
# screenshot gets a new URL. The page's references are rewritten to match.
hash="$(cat "$root/docs/images/latch-light.png" "$root/docs/images/latch-dark.png" "$0" | shasum -a 256 | cut -c1-8)"
out="$root/site/img/$hash"
rm -rf "$root/site/img"
work="$(mktemp -d "${TMPDIR:-/tmp}/latch-site-images.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"
cat > "$work/crop.swift" <<'SWIFT'
import AppKit
// usage: crop in.png out-prefix width...   Finds the opaque window inside the shadow and resamples it.
let args = CommandLine.arguments
guard let source = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
let w = source.width, h = source.height
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let probe = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
probe.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
let pixels = probe.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
func opaque(_ x: Int, _ y: Int) -> Bool { pixels[(y * w + x) * 4 + 3] == 255 }
// Scan the centre row and column: corners are rounded, the middles of the edges are not.
let left = (0..<w).first { opaque($0, h / 2) }!, right = (0..<w).last { opaque($0, h / 2) }!
let top = (0..<h).first { opaque(w / 2, $0) }!, bottom = (0..<h).last { opaque(w / 2, $0) }!
let window = source.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1))!
// The window's own background, sampled just inside the top edge, fills the rounded corners.
let i = ((top + 4) * w + w / 2) * 4
let fill = CGColor(srgbRed: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255, blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
for width in args[3...].compactMap({ Int($0) }) {
    let height = Int((Double(window.height) * Double(width) / Double(window.width)).rounded())
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.interpolationQuality = .high
    context.setFillColor(fill); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(window, in: CGRect(x: 0, y: 0, width: width, height: height))
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(args[2])-\(width).png"))
    print("\(width)x\(height)")
}
SWIFT
widths=(800 1200 1600 2400)
for theme in light dark; do
    swift "$work/crop.swift" "$root/docs/images/latch-$theme.png" "$work/$theme" "${widths[@]}" > "$work/$theme.sizes"
    for width in "${widths[@]}"; do
        sips -s format avif -s formatOptions 55 "$work/$theme-$width.png" --out "$out/latch-$theme-$width.avif" > /dev/null
        cwebp -quiet -q 78 "$work/$theme-$width.png" -o "$out/latch-$theme-$width.webp"
    done
done
# The link-preview card: the dark window on black, running off the bottom edge.
cat > "$work/og.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
let window = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let context = CGContext(data: nil, width: 1200, height: 630, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(.black); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 630))
context.interpolationQuality = .high
let width = 1040.0, height = width * Double(window.height) / Double(window.width)
context.draw(window, in: CGRect(x: (1200 - width) / 2, y: 630 - 56 - height, width: width, height: height))
let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])!.write(to: URL(fileURLWithPath: args[2]))
SWIFT
swift "$work/og.swift" "$work/dark-1200.png" "$out/og.jpg"
/usr/bin/sed -i '' -E "s#/img/[0-9a-f]{8}/#/img/$hash/#g" "$root/site/index.html"
echo "dimensions: $(tr '\n' ' ' < "$work/light.sizes")"
ls -l "$out" | awk 'NR>1 {printf "%7d  %s\n", $5, $NF}'
