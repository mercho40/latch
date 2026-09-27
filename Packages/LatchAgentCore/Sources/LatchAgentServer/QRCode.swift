/// A QR Code symbol (ISO/IEC 18004) of some bytes, for showing a pairing string to a phone's
/// camera. It covers only what that needs: byte mode, error-correction level M and versions 1
/// to 10, which hold up to 213 bytes. The smallest version that fits is used, with the mask
/// the standard's penalty rules score lowest.
struct QRCode: Equatable, Sendable {
    static let versions = 1...10

    let version: Int
    let mask: Int
    /// Modules on a side, without the quiet zone.
    let size: Int
    /// Row by row; `true` is dark.
    private(set) var modules: [Bool]

    init(_ text: String) throws(QRCodeError) {
        try self.init(bytes: Array(text.utf8))
    }

    init(bytes: [UInt8]) throws(QRCodeError) {
        guard let version = Self.versions.first(where: { bytes.count <= Self.byteCapacity($0) }) else {
            throw QRCodeError(byteCount: bytes.count)
        }
        let codewords = Self.dataCodewords(bytes, version: version)
        var best: QRCode?
        var bestPenalty = Int.max
        for mask in 0..<8 {
            let symbol = QRCode(version: version, dataCodewords: codewords, mask: mask)
            let penalty = symbol.penalty
            if penalty < bestPenalty {
                best = symbol
                bestPenalty = penalty
            }
        }
        self = best!
    }

    /// The symbol for data codewords already encoded to fill `version`, with a given mask.
    init(version: Int, dataCodewords: [UInt8], mask: Int) {
        precondition(Self.versions.contains(version) && (0..<8).contains(mask))
        precondition(dataCodewords.count == Self.dataCodewordCount(version))
        self.version = version
        self.mask = mask
        size = 4 * version + 17
        modules = Array(repeating: false, count: size * size)
        var function = FunctionPatterns(size: size)
        drawFunctionPatterns(&function)
        let codewords = Self.interleaved(dataCodewords, version: version)
        drawCodewords(codewords, avoiding: function)
        applyMask(avoiding: function)
        drawFormatBits(&function)
    }

    /// Whether the module in column `x`, row `y` is dark.
    private(set) subscript(x: Int, y: Int) -> Bool {
        get { modules[y * size + x] }
        set { modules[y * size + x] = newValue }
    }

    // MARK: Capacity

    /// Error-correction codewords per block and blocks, level M, by version.
    private static let ecCodewordsPerBlock = [10, 16, 26, 18, 24, 16, 18, 22, 22, 26]
    private static let blockCount = [1, 1, 1, 2, 2, 4, 4, 4, 5, 5]

    /// Centres of alignment patterns along each axis, by version.
    private static let alignmentCentres: [[Int]] = [
        [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50],
    ]

    /// Every codeword in the symbol: modules outside the function patterns, over eight, less
    /// the remainder bits.
    static func totalCodewordCount(_ version: Int) -> Int {
        let size = 4 * version + 17
        var modules = size * size - 3 * 64 - 2 * (size - 16) - 31
        let alignments = alignmentCentres[version - 1].count
        if alignments > 0 {
            // Those on the timing patterns overlap them by five modules; three sit on finders.
            let drawn = alignments * alignments - 3
            modules -= drawn * 25 - 2 * (alignments - 2) * 5
        }
        if version >= 7 { modules -= 36 }
        return modules / 8
    }

    static func dataCodewordCount(_ version: Int) -> Int {
        totalCodewordCount(version) - ecCodewordsPerBlock[version - 1] * blockCount[version - 1]
    }

    /// Four bits of mode, the count, then the bytes.
    static func byteCapacity(_ version: Int) -> Int {
        (dataCodewordCount(version) * 8 - 4 - countBits(version)) / 8
    }

    private static func countBits(_ version: Int) -> Int {
        version < 10 ? 8 : 16
    }

    // MARK: Codewords

    /// Byte-mode segment, terminator and padding, as codewords filling `version`.
    static func dataCodewords(_ bytes: [UInt8], version: Int) -> [UInt8] {
        let capacity = dataCodewordCount(version) * 8
        var bits = BitBuffer()
        bits.append(0b0100, count: 4)
        bits.append(bytes.count, count: countBits(version))
        for byte in bytes { bits.append(Int(byte), count: 8) }
        bits.append(0, count: min(4, capacity - bits.count))
        bits.append(0, count: (8 - bits.count % 8) % 8)
        var codewords = bits.bytes
        var pad: UInt8 = 0xEC
        while codewords.count < capacity / 8 {
            codewords.append(pad)
            pad ^= 0xEC ^ 0x11
        }
        return codewords
    }

    /// Splits the data into blocks, appends each block's error correction, and interleaves
    /// data then error correction a codeword from each block at a time. Where blocks differ
    /// in length the shorter ones come first.
    static func interleaved(_ data: [UInt8], version: Int) -> [UInt8] {
        let blocks = blockCount[version - 1]
        let ecLength = ecCodewordsPerBlock[version - 1]
        let generator = ReedSolomon.generator(degree: ecLength)
        let shortLength = data.count / blocks
        let longBlocks = data.count % blocks
        var dataBlocks: [ArraySlice<UInt8>] = []
        var start = 0
        for index in 0..<blocks {
            let length = shortLength + (index >= blocks - longBlocks ? 1 : 0)
            dataBlocks.append(data[start..<start + length])
            start += length
        }
        var result: [UInt8] = []
        result.reserveCapacity(totalCodewordCount(version))
        for column in 0...shortLength {
            for block in dataBlocks where column < block.count {
                result.append(block[block.startIndex + column])
            }
        }
        let ecBlocks = dataBlocks.map { ReedSolomon.remainder(Array($0), generator: generator) }
        for column in 0..<ecLength {
            for block in ecBlocks { result.append(block[column]) }
        }
        return result
    }

    // MARK: Drawing

    /// Which modules belong to function patterns, which data never overwrites or masks.
    private struct FunctionPatterns {
        let size: Int
        private var reserved: [Bool]

        init(size: Int) {
            self.size = size
            reserved = Array(repeating: false, count: size * size)
        }

        subscript(x: Int, y: Int) -> Bool {
            get { reserved[y * size + x] }
            set { reserved[y * size + x] = newValue }
        }
    }

    private mutating func drawFunctionPatterns(_ function: inout FunctionPatterns) {
        func set(_ x: Int, _ y: Int, _ dark: Bool) {
            self[x, y] = dark
            function[x, y] = true
        }
        for i in 0..<size {
            set(6, i, i % 2 == 0)
            set(i, 6, i % 2 == 0)
        }
        // Finders with their separators, clipped at the symbol's edge.
        for (centreX, centreY) in [(3, 3), (size - 4, 3), (3, size - 4)] {
            for dy in -4...4 {
                for dx in -4...4 {
                    let x = centreX + dx, y = centreY + dy
                    guard (0..<size).contains(x), (0..<size).contains(y) else { continue }
                    let ring = max(abs(dx), abs(dy))
                    set(x, y, ring != 2 && ring != 4)
                }
            }
        }
        let centres = Self.alignmentCentres[version - 1]
        for (i, centreY) in centres.enumerated() {
            for (j, centreX) in centres.enumerated() {
                // Not over the three finders.
                if (i == 0 && j == 0) || (i == 0 && j == centres.count - 1) || (i == centres.count - 1 && j == 0) {
                    continue
                }
                for dy in -2...2 {
                    for dx in -2...2 {
                        set(centreX + dx, centreY + dy, max(abs(dx), abs(dy)) != 1)
                    }
                }
            }
        }
        // Reserve the format areas now; drawFormatBits fills them after masking.
        drawFormatBits(&function)
        if version >= 7 {
            let bits = Self.versionBits(version)
            for i in 0..<18 {
                let dark = (bits >> i) & 1 == 1
                let a = size - 11 + i % 3, b = i / 3
                set(a, b, dark)
                set(b, a, dark)
            }
        }
    }

    /// Format information, both copies, and the dark module beside the lower-left finder.
    private mutating func drawFormatBits(_ function: inout FunctionPatterns) {
        func set(_ x: Int, _ y: Int, _ dark: Bool) {
            self[x, y] = dark
            function[x, y] = true
        }
        let bits = Self.formatBits(mask: mask)
        func bit(_ i: Int) -> Bool { (bits >> i) & 1 == 1 }
        for i in 0...5 { set(8, i, bit(i)) }
        set(8, 7, bit(6))
        set(8, 8, bit(7))
        set(7, 8, bit(8))
        for i in 9..<15 { set(14 - i, 8, bit(i)) }
        for i in 0..<8 { set(size - 1 - i, 8, bit(i)) }
        for i in 8..<15 { set(8, size - 15 + i, bit(i)) }
        set(8, size - 8, true)
    }

    /// Level M's indicator 00 and the mask, BCH(15,5) coded and XORed with 101010000010010.
    static func formatBits(mask: Int) -> Int {
        let data = mask
        var remainder = data
        for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
        return (data << 10 | remainder) ^ 0x5412
    }

    /// The version, BCH(18,6) coded.
    static func versionBits(_ version: Int) -> Int {
        var remainder = version
        for _ in 0..<12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
        return version << 12 | remainder
    }

    /// Two columns at a time from the right, upward then downward, skipping the vertical
    /// timing pattern. Remainder bits are left light.
    private mutating func drawCodewords(_ codewords: [UInt8], avoiding function: FunctionPatterns) {
        var index = 0
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            let upward = (right + 1) & 2 == 0
            for step in 0..<size {
                let y = upward ? size - 1 - step : step
                for x in [right, right - 1] where !function[x, y] && index < codewords.count * 8 {
                    self[x, y] = (codewords[index >> 3] >> (7 - index & 7)) & 1 == 1
                    index += 1
                }
            }
            right -= 2
        }
    }

    private mutating func applyMask(avoiding function: FunctionPatterns) {
        for y in 0..<size {
            for x in 0..<size where !function[x, y] && Self.masked(x: x, y: y, mask: mask) {
                self[x, y].toggle()
            }
        }
    }

    /// Whether `mask` inverts the module in column `x`, row `y`.
    static func masked(x: Int, y: Int, mask: Int) -> Bool {
        switch mask {
        case 0: (x + y) % 2 == 0
        case 1: y % 2 == 0
        case 2: x % 3 == 0
        case 3: (x + y) % 3 == 0
        case 4: (x / 3 + y / 2) % 2 == 0
        case 5: x * y % 2 + x * y % 3 == 0
        case 6: (x * y % 2 + x * y % 3) % 2 == 0
        default: ((x + y) % 2 + x * y % 3) % 2 == 0
        }
    }

    // MARK: Penalty

    /// The standard's four penalty rules: runs of five or more of a colour, 2×2 blocks of one
    /// colour, finder-like 1:1:3:1:1 patterns with four light modules on one side, and a
    /// proportion of dark modules away from half.
    var penalty: Int {
        var total = 0
        for line in 0..<size {
            let row = (0..<size).map { self[$0, line] }
            let column = (0..<size).map { self[line, $0] }
            total += Self.runPenalty(row) + Self.finderPenalty(row)
            total += Self.runPenalty(column) + Self.finderPenalty(column)
        }
        for y in 0..<size - 1 {
            for x in 0..<size - 1 {
                let colour = self[x, y]
                if self[x + 1, y] == colour, self[x, y + 1] == colour, self[x + 1, y + 1] == colour { total += 3 }
            }
        }
        let dark = modules.count(where: \.self)
        // 10 for every whole 5% the dark proportion is away from 50%.
        total += abs(dark * 20 - modules.count * 10) / modules.count * 10
        return total
    }

    private static func runPenalty(_ line: [Bool]) -> Int {
        var total = 0
        var run = 0
        for (index, module) in line.enumerated() {
            run = index > 0 && line[index - 1] == module ? run + 1 : 1
            if run == 5 { total += 3 } else if run > 5 { total += 1 }
        }
        return total
    }

    /// 1011101 with 0000 before or after it, within the symbol.
    private static func finderPenalty(_ line: [Bool]) -> Int {
        let core: [Bool] = [true, false, true, true, true, false, true]
        let light = [Bool](repeating: false, count: 4)
        let before = light + core, after = core + light
        var total = 0
        for start in 0...(line.count - 11) {
            let window = line[start..<start + 11]
            if window.elementsEqual(before) { total += 40 }
            if window.elementsEqual(after) { total += 40 }
        }
        return total
    }

    // MARK: Terminal

    /// The symbol inside a quiet zone of four modules, two rows to a line in half blocks.
    /// The light modules are drawn, quiet zone included, and the dark ones left as the
    /// background, as qrencode draws for a dark theme; `darkModules` draws the dark ones
    /// instead. With `colors` each line sets its own, white on black or black on white, so the
    /// code is the same in every theme.
    ///
    /// A terminal that draws the blocks from its font, rather than filling their cells, can
    /// leave a gap between lines in the background's colour. Across light modules on black, as
    /// by default, Apple's detectors still read the code; across dark modules on white they
    /// often do not.
    func terminalText(darkModules: Bool = false, colors: Bool = false) -> String {
        let quiet = 4
        let extent = size + 2 * quiet
        func drawn(_ x: Int, _ y: Int) -> Bool {
            guard y < extent else { return false }
            let (column, row) = (x - quiet, y - quiet)
            let dark = (0..<size).contains(column) && (0..<size).contains(row) && self[column, row]
            return dark == darkModules
        }
        // Colours 16 and 231 of the 256, which themes leave alone, unlike the first 16.
        let (start, end) = colors ? ("\u{1B}[38;5;\(darkModules ? 16 : 231);48;5;\(darkModules ? 231 : 16)m", "\u{1B}[0m") : ("", "")
        var text = ""
        for y in stride(from: 0, to: extent, by: 2) {
            text += start
            for x in 0..<extent {
                switch (drawn(x, y), drawn(x, y + 1)) {
                case (true, true): text += "█"
                case (true, false): text += "▀"
                case (false, true): text += "▄"
                case (false, false): text += " "
                }
            }
            text += end + "\n"
        }
        return text
    }
}

struct QRCodeError: Error, Equatable, Sendable, CustomStringConvertible {
    var byteCount: Int

    var description: String {
        "\(byteCount) bytes do not fit in a QR code of version \(QRCode.versions.upperBound), which holds \(QRCode.byteCapacity(QRCode.versions.upperBound))"
    }
}

private struct BitBuffer {
    private(set) var bytes: [UInt8] = []
    private(set) var count = 0

    /// The low `count` bits of `value`, most significant first.
    mutating func append(_ value: Int, count bitCount: Int) {
        for shift in stride(from: bitCount - 1, through: 0, by: -1) {
            if count % 8 == 0 { bytes.append(0) }
            if (value >> shift) & 1 == 1 { bytes[bytes.count - 1] |= 0x80 >> UInt8(count % 8) }
            count += 1
        }
    }
}

/// Reed–Solomon error correction over GF(256) with the QR code's field polynomial
/// x⁸ + x⁴ + x³ + x² + 1 and generator roots α⁰ … αⁿ⁻¹.
enum ReedSolomon {
    static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var product = 0
        for shift in stride(from: 7, through: 0, by: -1) {
            product = (product << 1) ^ ((product >> 7) * 0x11D)
            if (y >> shift) & 1 == 1 { product ^= Int(x) }
        }
        return UInt8(product)
    }

    /// The generator polynomial of `degree`, coefficients from the highest power down, the
    /// leading 1 left out.
    static func generator(degree: Int) -> [UInt8] {
        var coefficients = [UInt8](repeating: 0, count: degree)
        coefficients[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            // Multiply by (x - root), where subtraction is XOR.
            for i in 0..<degree {
                coefficients[i] = multiply(coefficients[i], root)
                if i + 1 < degree { coefficients[i] ^= coefficients[i + 1] }
            }
            root = multiply(root, 2)
        }
        return coefficients
    }

    /// The error-correction codewords: `data` times xⁿ modulo the generator.
    static func remainder(_ data: [UInt8], generator: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: generator.count)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for i in result.indices { result[i] ^= multiply(generator[i], factor) }
        }
        return result
    }
}
