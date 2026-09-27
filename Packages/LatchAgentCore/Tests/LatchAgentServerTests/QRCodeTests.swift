import Foundation
import XCTest
@testable import LatchAgentServer
#if canImport(CoreImage)
import CoreImage
#endif

/// The QR encoder against the ISO/IEC 18004 worked example, published Reed–Solomon codewords
/// and BCH tables, symbols CoreImage's generator draws for the same input, and on macOS
/// CoreImage's detector reading what `latch-server pair --qr` prints.
final class QRCodeTests: XCTestCase {
    private static let token = "latch_Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6"

    /// Rows of `#` for dark and `.` for light.
    private func picture(_ symbol: QRCode) -> String {
        (0..<symbol.size).map { y in String((0..<symbol.size).map { x in symbol[x, y] ? "#" : "." }) }
            .joined(separator: "\n")
    }

    // MARK: Reed–Solomon

    /// Annex I's "01234567" at 1-M, and "HELLO WORLD" at 1-M from Thonky's QR tutorial.
    func testReedSolomonMatchesPublishedCodewords() {
        let generator = ReedSolomon.generator(degree: 10)
        XCTAssertEqual(
            ReedSolomon.remainder(Self.isoDataCodewords, generator: generator),
            [0xA5, 0x24, 0xD4, 0xC1, 0xED, 0x36, 0xC7, 0x87, 0x2C, 0x55]
        )
        let helloWorld: [UInt8] = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17]
        XCTAssertEqual(ReedSolomon.remainder(helloWorld, generator: generator), [196, 35, 39, 119, 235, 215, 231, 226, 93, 23])
    }

    /// Annex A's generator polynomials, as powers of α.
    func testGeneratorPolynomials() {
        var exponent = [UInt8: Int]()
        var power: UInt8 = 1
        for index in 0..<255 {
            exponent[power] = index
            power = ReedSolomon.multiply(power, 2)
        }
        XCTAssertEqual(power, 1)
        XCTAssertEqual(exponent.count, 255)
        XCTAssertEqual(ReedSolomon.generator(degree: 7).map { exponent[$0] }, [87, 229, 146, 149, 238, 102, 21])
        XCTAssertEqual(ReedSolomon.generator(degree: 10).map { exponent[$0] }, [251, 67, 46, 61, 118, 70, 64, 94, 32, 45])
    }

    // MARK: Tables

    /// Annex C's format information for level M and Annex D's version information.
    func testFormatAndVersionInformation() {
        XCTAssertEqual((0..<8).map { QRCode.formatBits(mask: $0) }, [
            0b101010000010010, 0b101000100100101, 0b101111001111100, 0b101101101001011,
            0b100010111111001, 0b100000011001110, 0b100111110010111, 0b100101010100000,
        ])
        XCTAssertEqual((7...10).map(QRCode.versionBits), [0x07C94, 0x085BC, 0x09A99, 0x0A4D3])
    }

    /// Tables 1 and 7: codewords in the symbol, and bytes at level M.
    func testCapacities() {
        XCTAssertEqual(QRCode.versions.map(QRCode.totalCodewordCount), [26, 44, 70, 100, 134, 172, 196, 242, 292, 346])
        XCTAssertEqual(QRCode.versions.map(QRCode.dataCodewordCount), [16, 28, 44, 64, 86, 108, 124, 154, 182, 216])
        XCTAssertEqual(QRCode.versions.map(QRCode.byteCapacity), [14, 26, 42, 62, 84, 106, 122, 152, 180, 213])
    }

    // MARK: Symbols

    /// Annex I's data codewords for "01234567" (numeric mode) at 1-M, placed with the mask the
    /// penalty rules choose, match the symbol CoreImage generates for that string.
    func testISOExampleSymbol() {
        let symbols = (0..<8).map { QRCode(version: 1, dataCodewords: Self.isoDataCodewords, mask: $0) }
        let chosen = symbols.min { $0.penalty < $1.penalty }!
        XCTAssertEqual(chosen.mask, 0)
        XCTAssertEqual(picture(chosen), """
        #######...###.#######
        #.....#.###...#.....#
        #.###.#..##...#.###.#
        #.###.#..#.##.#.###.#
        #.###.#.##.##.#.###.#
        #.....#....#..#.....#
        #######.#.#.#.#######
        .....................
        #.#.#.#...#.#...#..#.
        ##.#....#.##.#.#...#.
        ...##.###.##.###.###.
        ##..##.#.#.###.##..#.
        ..#..###.###.###....#
        ........#.#...#....#.
        #######.....#...#...#
        #.....#...#...#..#.##
        #.###.#.###.#.#.###.#
        #.###.#..#.#.#.#.###.
        #.###.#.##.#.###..#.#
        #.....#....###.###...
        #######.#..#.###..#.#
        """)
    }

    private static let isoDataCodewords: [UInt8] = [
        0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11,
    ]

    /// Byte-mode symbols as CoreImage's generator draws them at level M, including version 7,
    /// the first with version information, and version 8, the first whose Reed–Solomon blocks
    /// differ in length, so that interleaving is checked where the server runs too.
    func testSymbolsMatchReferenceEncodings() throws {
        let hello = try QRCode("hello, world!")
        XCTAssertEqual([hello.version, hello.mask], [1, 2])
        XCTAssertEqual(picture(hello), """
        #######..###..#######
        #.....#.......#.....#
        #.###.#.#.#.#.#.###.#
        #.###.#.#...#.#.###.#
        #.###.#.#.#.#.#.###.#
        #.....#.#.##..#.....#
        #######.#.#.#.#######
        ........#.#..........
        #.#####....#..#####..
        ###.......#.##..###.#
        .#...##.#...###..###.
        .#..##.##..###.#.##..
        #######.#.#.#.##....#
        ........###..#####..#
        #######..##.####..##.
        #.....#.#.#.##.#.###.
        #.###.#.#..####.#..##
        #.###.#.#.#....###...
        #.###.#.#.###.##..#..
        #.....#...#.##..###..
        #######.#..#..#.#..#.
        """)

        let url = try QRCode("https://example.com/")
        XCTAssertEqual([url.version, url.mask], [2, 4])
        XCTAssertEqual(picture(url), """
        #######.#..##.###.#######
        #.....#..###....#.#.....#
        #.###.#..#....#.#.#.###.#
        #.###.#.###.#####.#.###.#
        #.###.#.#..#..###.#.###.#
        #.....#.##...#....#.....#
        #######.#.#.#.#.#.#######
        ........##..#.#..........
        #...#.####.#..##.#####..#
        #..#.#..##.#..##.#..##.#.
        #..#.##.##.#####.###.##..
        #.#..#.#..##..##.#.#..##.
        ###.#.#.#....##..###.####
        ##......###.#.###...#..#.
        ....#.##.#.#######.####..
        ..#.#..#..##.#.#...##.##.
        ####..#.###.##.########..
        ........#....##.#...#....
        #######.#.#.....#.#.#....
        #.....#..#..#.#.#...####.
        #.###.#.####.##.#########
        #.###.#...#.#....###..###
        #.###.#..##########..#.#.
        #.....#....#.#....######.
        #######.###.##.#.##...###
        """)

        let pairing = try QRCode("latch://build-server-with-a-long-name.example-tailnet.ts.net:7428?token=\(Self.token)")
        XCTAssertEqual([pairing.version, pairing.mask], [7, 2])
        XCTAssertEqual(picture(pairing), """
        #######......#..##.#.....#...###....#.#######
        #.....#..#....##.###.#.#######.###.#..#.....#
        #.###.#.#..##..#...#....#######.##.#..#.###.#
        #.###.#.##.#.##.###.#.####...###...##.#.###.#
        #.###.#.#..##..##..######..#..#.#.###.#.###.#
        #.....#.#.#.##...##.#...###.#..#......#.....#
        #######.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#######
        ........##.##.###..##...#...#.#.##.##........
        #.#####......#....#.#####.#..#.#.##...#####..
        ####...####...####.####.#....##....##..#.##.#
        ##.##.#.....#.##.#.....##.#....#..########.#.
        .#.#.#.##.#..###..##...######.#.#######.#.#..
        .#....##...#.##..###...#..#..#.#.#.#.#.....##
        ####....#..##.###..##..#.#.####....###...####
        #.##..##.....#...########.###########.###.#..
        ###..#..###.#..##.#......#..#.#.#.####..#.#.#
        ####.##.#.#.#..#..#.#.###.##.#...##......#.#.
        ...#...##.#...####.#.###.#...##..#.###..#####
        .##..###..#.#.###.#.##.###..#..#..##..#.#.#..
        ######....#....###.#.#....####.#####.#.######
        #.#.#####..#.######.######...##.....########.
        ....#...#.....##.####...##...##.#...#...#.#.#
        ....#.#.##.#...######.#.######.#...##.#.####.
        ..###...#.##.#.....##...#####..##...#...###.#
        ....#####....##...#.######....##...#######.##
        #....#.#.#...####.##.###.#.#####......#..#..#
        ...##.##..#.##.###..##.#.##..##..#####...###.
        ##.##...##......##....####......##.#.#.#.##.#
        ##....######..#..#...#.###....##......###...#
        #.##....#.##.#..#######..#.#.##....##.#...##.
        ###.####..#....##.#.###..##..##..####...#..#.
        ..##.#.##.#...#........##.#####.#.##..##..#..
        ...#..##.#.#########...###...###....##..##..#
        ##...#...##.#....#..###..#.####....#.#.#...##
        ....#.#.#.#.#.###.#.###.#.####.######........
        .####...#..##....#..#..###.####..####.#.###.#
        #..##.####..#.#...#######.#...##....#####...#
        ........#...####....#...##...###...##...###.#
        #######..#####.######.#.##.#...######.#.#.##.
        #.....#.#.##.#..#####...##..##..#####...#####
        #.###.#.#.#####..#..#######..#.#...######..##
        #.###.#.#..#.###....#..###.####......##.##.##
        #.###.#.#..#...##.###..#..##.###########...#.
        #.....#....##..###..#.#..#..#####.####.#.##..
        #######.#...######.#....#..#...#......###..#.
        """)

        let longHost = try QRCode("latch://build-server-with-a-much-longer-name.example-tailnet-name.ts.net:7428?token=\(Self.token)")
        XCTAssertEqual([longHost.version, longHost.mask], [8, 2])
        XCTAssertEqual(picture(longHost), """
        #######....#.#.#.#...#..#.....##...##...#.#######
        #.....#..####.##.#.#.##..#.#.##......####.#.....#
        #.###.#.###..#.....##.#####..####......##.#.###.#
        #.###.#.#.....##.###.##.##...#.#...###.#..#.###.#
        #.###.#.###.##...#...######.###.#....#....#.###.#
        #.....#.#...##.###.#..#...##...#..#...#...#.....#
        #######.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#######
        ........#.###..####...#...#######..#.............
        #.#####..#.#..#...##########..##.#.###..#.#####..
        #.#.#..#..#######..#..####....##...###.#.##..##..
        .#...####.......###.#...#.#....#.###..#..##.##..#
        .#.#....#.##..##...#.#...####..##.#.....#...##...
        #####.##.#....#####...###.##.###...###.##..#..#.#
        .#.###..##.##########.#..#...###.#.#.#....###.#..
        ##..###..#..####....###..###.####.#.####....#..##
        ...#....#.##....##.##.#...##.#...###..#.###.#...#
        ##..###.#.###...#....#.##...#..##..###.#####.#.#.
        .#..##...#.##.##.###..#..#.###..#....#....##.#...
        ..###.#.#..#.##..#.#...#.#..#.##########...##..##
        ##...#.#.##...#.#..##....####....#.##.#######..##
        #.#..########.#.#########.#..###.#####..###...#..
        ####....##.#....#......#.#######...#.#...##...##.
        ..#############...#########..#.##.##..#######...#
        #..##...#.#....#..##..#...####..##...##.#...#....
        ...##.#.##.##.#.##..###.#.#..###....##.##.#.###.#
        .#.##...##.#.......#..#...#..##.#..###.##...#.##.
        .#.########.#.#...#.#.#####.#..##############.###
        ###....##...#.##..###.#.#..##...####.#..#...#..##
        ...##.####.##.##.#.#.#..###..##....##..#.###..###
        .##.#....##.#####....###.#...##.#..###.....#.....
        .###..##.##.#..#.#.#..#..#..#.....##..#...#######
        ##........##..##..#..###.##...#...#.##..##...#...
        ###..####..##.#.##..##.###.#.##....##.####..#.###
        #...##....#.#..##.##.####.....#.#..###.###.#...##
        .#######.###..##..##.#..##.#.###.#.#.#..#.####.##
        .##..#.##.....#.###.#.#####.###.#..####.#..##..##
        #.##..####..#.#.##.####..#.#..##.####..###..###..
        ...###.#....#.####...#..#.######....##.##..#..##.
        .#...###..#.##..#.#.#.##........###...##.###.##.#
        .###.....###.#..#.#.##..######..###.....#.......#
        ###...##.#.#.###..#.#.#####....#...##..##########
        ........#.###..#.#.#.##...#..##.....##..#...#....
        #######..##.###########.#.##...#####..#.#.#.##.##
        #.....#.#.####.#..#####...####.##.......#...#..#.
        #.###.#.#...##.#..#..#######.###.##.###.#########
        #.###.#.##.####..####.#....#.###....##...#..#...#
        #.###.#.#.#.#.......#..###.##.##...##.#....#.##..
        #.....#..#.###.##..######..#.#.##.....##..###...#
        #######.###..##....#...###..#....#####...#...####
        """)
    }

    func testPicksTheSmallestVersionAndRefusesWhatDoesNotFit() throws {
        XCTAssertEqual(try QRCode("").version, 1)
        XCTAssertEqual(try QRCode(String(repeating: "a", count: 14)).version, 1)
        XCTAssertEqual(try QRCode(String(repeating: "a", count: 15)).version, 2)
        XCTAssertEqual(try QRCode(String(repeating: "é", count: 7)).version, 1)
        XCTAssertEqual(try QRCode(String(repeating: "a", count: 213)).version, 10)
        XCTAssertThrowsError(try QRCode(String(repeating: "a", count: 214))) { error in
            XCTAssertEqual(error as? QRCodeError, QRCodeError(byteCount: 214))
        }
    }

    // MARK: Terminal

    func testTerminalText() throws {
        let symbol = try QRCode("hello, world!")
        let extent = symbol.size + 8
        for darkModules in [false, true] {
            let text = symbol.terminalText(darkModules: darkModules)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            XCTAssertEqual(lines.count, (extent + 1) / 2)
            XCTAssertTrue(lines.allSatisfy { $0.count == extent })
            XCTAssertTrue(Set(text).isSubset(of: ["█", "▀", "▄", " ", "\n"]))
            // The quiet zone above is two lines, and below it the last line's lower half is empty.
            XCTAssertEqual(lines.first, Substring(String(repeating: darkModules ? " " : "█", count: extent)))
            XCTAssertEqual(lines.last, Substring(String(repeating: darkModules ? " " : "▀", count: extent)))
            XCTAssertEqual(try modules(fromTerminalText: text, darkModules: darkModules), paddedModules(symbol))

            // In colour, each line sets its own and resets it before the newline.
            let colored = symbol.terminalText(darkModules: darkModules, colors: true)
            let start = darkModules ? "\u{1B}[38;5;16;48;5;231m" : "\u{1B}[38;5;231;48;5;16m"
            let coloredLines = colored.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            XCTAssertEqual(coloredLines.map { start + $0.dropFirst(start.count).dropLast(4) + "\u{1B}[0m" }, coloredLines.map(String.init))
            XCTAssertEqual(coloredLines.map { String($0.dropFirst(start.count).dropLast(4)) }, lines.map(String.init))
        }
    }

    /// Dark modules read back from `terminalText`, quiet zone included.
    private func modules(fromTerminalText text: String, darkModules: Bool) throws -> [[Bool]] {
        try drawnCells(fromTerminalText: text).map { row in row.map { $0 == darkModules } }
    }

    /// The half-character cells `terminalText` draws in the text's colour, quiet zone included.
    private func drawnCells(fromTerminalText text: String) throws -> [[Bool]] {
        var rows: [[Bool]] = []
        for line in text.split(separator: "\n") {
            var upper: [Bool] = [], lower: [Bool] = []
            for character in line {
                let halves: (Bool, Bool)
                switch character {
                case "█": halves = (true, true)
                case "▀": halves = (true, false)
                case "▄": halves = (false, true)
                case " ": halves = (false, false)
                default: throw HubTestError.unexpected("unexpected character \(character)")
                }
                upper.append(halves.0)
                lower.append(halves.1)
            }
            rows.append(upper)
            rows.append(lower)
        }
        // The last line's lower half lies below the quiet zone.
        return Array(rows.dropLast())
    }

    private func paddedModules(_ symbol: QRCode) -> [[Bool]] {
        (0..<symbol.size + 8).map { y in
            (0..<symbol.size + 8).map { x in
                (4..<symbol.size + 4).contains(x) && (4..<symbol.size + 4).contains(y) && symbol[x - 4, y - 4]
            }
        }
    }

    #if canImport(CoreImage)
    // MARK: CoreImage

    /// Every version against CoreImage's generator, with byte-mode text it cannot shorten
    /// with another mode. Where the two choose different masks, as they may since the
    /// standard's finder-pattern rule is read differently by different encoders, ours with
    /// CoreImage's mask must be its symbol.
    func testSymbolsMatchCoreImageForEveryVersion() throws {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz_?=&!~".utf8)
        var state: UInt32 = 1
        var sameMask = 0
        let lengths = [1, 14, 15, 26, 27, 42, 43, 62, 63, 84, 85, 106, 107, 122, 123, 152, 153, 180, 181, 213]
        for length in lengths {
            let bytes = (0..<length).map { _ in
                state = state &* 1_103_515_245 &+ 12_345
                return alphabet[Int(state >> 16) % alphabet.count]
            }
            let ours = try QRCode(bytes: bytes)
            let reference = try XCTUnwrap(coreImageModules(Data(bytes)))
            XCTAssertEqual(reference.count, ours.size * ours.size, "\(length) bytes")
            let codewords = QRCode.dataCodewords(bytes, version: ours.version)
            let masks = (0..<8).filter { QRCode(version: ours.version, dataCodewords: codewords, mask: $0).modules == reference }
            XCTAssertEqual(masks.count, 1, "\(length) bytes, version \(ours.version)")
            if masks == [ours.mask] { sameMask += 1 }
        }
        XCTAssertGreaterThanOrEqual(sameMask, lengths.count / 2)
    }

    /// CoreImage's detector reads what `pair --qr` prints, drawn as a terminal draws it, in a
    /// light theme and a dark one, so both ways round, from a pairing string to a symbol at
    /// version 10's capacity. Gaps between lines are not modelled: see `terminalText`.
    func testCoreImageReadsTheTerminalText() throws {
        let messages = [
            "latch://vps.example.ts.net:7428?token=\(Self.token)",
            "latch://[fd7a:115c:a1e0::1]:7428?token=\(Self.token)",
            "latch://" + String(repeating: "x", count: 213 - 8),
        ]
        for message in messages {
            let symbol = try QRCode(message)
            for darkModules in [false, true] {
                let drawn = try drawnCells(fromTerminalText: symbol.terminalText(darkModules: darkModules))
                for darkTheme in [false, true] {
                    XCTAssertEqual(try decode(drawn, drawnDark: !darkTheme), [message],
                                   "version \(symbol.version), dark modules \(darkModules), dark theme \(darkTheme)")
                }
            }
        }
    }

    private func coreImageModules(_ data: Data) -> [Bool]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let width = Int(image.extent.width)
        var pixels = [UInt8](repeating: 0, count: width * width * 4)
        CIContext().render(
            image, toBitmap: &pixels, rowBytes: width * 4, bounds: image.extent, format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let dark = pixels.indices.filter { $0 % 4 == 0 }.map { pixels[$0] < 128 }
        // Its quiet zone is as wide as the gap to the first dark module on the top row.
        guard let firstDark = dark.firstIndex(of: true) else { return nil }
        let margin = firstDark / width
        let size = width - 2 * margin
        return (0..<size).flatMap { y in (0..<size).map { x in dark[(y + margin) * width + x + margin] } }
    }

    /// Draws the cells at eight pixels each, black on white or white on black, and returns
    /// what CIDetector reads.
    private func decode(_ cells: [[Bool]], drawnDark: Bool) throws -> [String] {
        let scale = 8
        let extent = cells.count * scale
        let (ink, paper): (UInt8, UInt8) = drawnDark ? (0, 255) : (255, 0)
        var pixels = [UInt8](repeating: paper, count: extent * extent)
        for y in 0..<extent {
            for x in 0..<extent where cells[y / scale][x / scale] { pixels[y * extent + x] = ink }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: extent, height: extent, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: extent,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        return detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
    #endif
}
