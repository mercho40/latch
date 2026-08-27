import Foundation

/// Decodes ACP's newline-delimited JSON transport without interpreting JSON.
public struct ACPFrameDecoder: Sendable {
    public static let defaultMaximumFrameSize = 8 * 1024 * 1024

    public enum Event: Equatable, Sendable {
        case frame(Data)
        case oversizedFrame
    }

    private let maximumFrameSize: Int
    private var bufferedFrame = Data()
    private var discardingOversizedFrame = false

    public init(maximumFrameSize: Int = Self.defaultMaximumFrameSize) {
        precondition(maximumFrameSize > 0)
        self.maximumFrameSize = maximumFrameSize
    }

    /// Accepts an arbitrary stream fragment and returns every complete event it contains.
    /// Empty lines are ignored. An oversized frame is drained through its newline so the
    /// next valid frame can still be decoded.
    public mutating func append(_ data: Data) -> [Event] {
        var events: [Event] = []
        var start = data.startIndex

        while start < data.endIndex {
            if discardingOversizedFrame {
                guard let newline = data[start...].firstIndex(of: 0x0A) else {
                    return events
                }

                discardingOversizedFrame = false
                start = data.index(after: newline)
                continue
            }

            guard let newline = data[start...].firstIndex(of: 0x0A) else {
                appendFragment(data[start...], events: &events)
                return events
            }

            let fragment = data[start..<newline]
            if bufferedFrame.count + fragment.count > maximumFrameSize {
                bufferedFrame.removeAll(keepingCapacity: true)
                events.append(.oversizedFrame)
            } else {
                bufferedFrame.append(contentsOf: fragment)
                if !bufferedFrame.isEmpty {
                    events.append(.frame(bufferedFrame))
                    bufferedFrame.removeAll(keepingCapacity: true)
                }
            }

            start = data.index(after: newline)
        }

        return events
    }

    private mutating func appendFragment(
        _ fragment: Data.SubSequence,
        events: inout [Event]
    ) {
        guard bufferedFrame.count + fragment.count <= maximumFrameSize else {
            bufferedFrame.removeAll(keepingCapacity: true)
            discardingOversizedFrame = true
            events.append(.oversizedFrame)
            return
        }

        bufferedFrame.append(contentsOf: fragment)
    }
}
