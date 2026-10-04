import LatchACP

/// How much of its context window the agent has used, and what the conversation has cost, from
/// its `usage_update`. Claude Code sends one as each message starts, and the cost at a turn's end.
public struct ContextUsage: Equatable, Sendable {
    /// Tokens in the context now.
    public let used: Int
    /// The context window's size in tokens.
    public let size: Int
    /// What the conversation has cost so far, when the agent says.
    public let cost: Double?
    public let currency: String?

    public init(used: Int, size: Int, cost: Double? = nil, currency: String? = nil) {
        self.used = used
        self.size = size
        self.cost = cost
        self.currency = currency
    }

    init?(_ update: ACPJSONValue) {
        // Agent numbers: one past what an Int holds would trap, on every attach that replays it.
        guard case let .object(fields) = update, let used = Self.number(fields["used"]), let size = Self.number(fields["size"]),
              used >= 0, size > 0, used < 1e15, size < 1e15 else { return nil }
        var cost: Double?
        var currency: String?
        if case let .object(amount)? = fields["cost"] {
            cost = Self.number(amount["amount"]).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            if case let .string(code)? = amount["currency"] { currency = code }
        }
        self.init(used: Int(used), size: Int(size), cost: cost, currency: currency)
    }

    /// The share of the window in use, from 0 to 1.
    public var fraction: Double { min(1, Double(used) / Double(size)) }

    private static func number(_ value: ACPJSONValue?) -> Double? {
        switch value {
        case let .integer(number)?: Double(number)
        case let .double(number)?: number
        default: nil
        }
    }
}
