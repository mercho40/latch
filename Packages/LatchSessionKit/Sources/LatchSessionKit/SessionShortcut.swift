/// ⌘1 to ⌘8 go to the listed sessions in order, and ⌘9 to the last, as Safari's tabs do.
public enum SessionShortcut {
    /// The index in a list of `count` sessions that ⌘`number` goes to; nil where there is none.
    public static func index(forNumber number: Int, count: Int) -> Int? {
        guard (1...9).contains(number), count > 0 else { return nil }
        if number == 9 { return count - 1 }
        return number <= count ? number - 1 : nil
    }
}
