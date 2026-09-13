import Foundation
import LatchACP

/// Only RPC display text crosses this boundary, never arbitrary data, stderr, or native errors.
/// Redaction is defense in depth, not a guarantee that arbitrary agent prose contains no secrets.
enum AgentRPCFailureMessage {
    static let maximumLength = 512

    static func message(for error: ACPJSONRPCErrorObject) -> String {
        let fallback = "Agent reported an error."
        var text = error.localizedDescription
        // Reject oversized input rather than cutting a credential before redaction can recognize it.
        guard text.utf8.count <= 16_384 else { return fallback }
        let patterns = [
            // Drop entire URLs, including userinfo, query credentials, and fragments.
            #"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>]+"#,
            // Authorization may contain schemes other than Bearer/Basic; omit the whole line.
            #"(?im)\b(?:proxy[-_ ]?)?authorization\b[^\r\n]*"#,
            #"(?i)\b(?:bearer|basic)\s+[^\s,;]+"#,
            #"(?i)[\"']?\b(?:[a-z0-9]+[-_])*(?:token|api[-_]?key|secret|password|passwd|credential|cookie)(?:[-_][a-z0-9]+)*[\"']?\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            #"\b(?:sk-|gh[pousr]_|github_pat_)[A-Za-z0-9_-]+"#,
            #"\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        // Remove terminal/control and bidi formatting characters, then flatten whitespace.
        text = String(text.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value) {
                return " "
            }
            return Character(String(scalar))
        })
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { return fallback }
        let message = "Agent reported: " + text
        guard message.count > maximumLength else { return message }
        return String(message.prefix(maximumLength - 1)) + "…"
    }
}
