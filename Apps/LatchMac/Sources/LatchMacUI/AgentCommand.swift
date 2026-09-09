import Foundation

/// Small argv parser, not a shell: quotes and backslash escaping only. No expansion,
/// pipelines, redirection, or command substitution. The executable must be absolute.
struct AgentCommand {
    let executable: String
    let arguments: [String]

    init(_ input: String) throws {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in input {
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
                started = true
            } else if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started { words.append(word); word = ""; started = false }
            } else {
                word.append(character)
                started = true
            }
        }
        guard quote == nil, !escaped else { throw CommandError.unfinishedQuote }
        if started { words.append(word) }
        guard let executable = words.first, executable.hasPrefix("/") else {
            throw CommandError.absoluteExecutableRequired
        }
        self.executable = executable
        self.arguments = Array(words.dropFirst())
    }
}

enum CommandError: LocalizedError {
    case unfinishedQuote, absoluteExecutableRequired, executableNotFound, workspaceRequired
    var errorDescription: String? {
        switch self {
        case .unfinishedQuote: "Finish the quoted argument or trailing backslash."
        case .absoluteExecutableRequired: "Use an absolute executable path, such as /usr/bin/env agent acp."
        case .executableNotFound: "The executable does not exist or is not executable."
        case .workspaceRequired: "Choose an existing workspace folder first."
        }
    }
}
