import Foundation

/// Small argv parser, not a shell: quotes and backslash escaping only. No expansion,
/// pipelines, redirection, or command substitution. Executable lookup is separate.
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
        guard let executable = words.first, !executable.isEmpty else {
            throw CommandError.executableRequired
        }
        guard executable.hasPrefix("/") || executable.hasPrefix("~/") || !executable.contains("/") else {
            throw CommandError.relativeExecutableNotAllowed
        }
        self.executable = executable
        self.arguments = Array(words.dropFirst())
    }

    static func quotedArgument(_ argument: String) -> String {
        "\"" + argument.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

enum CommandError: LocalizedError {
    case unfinishedQuote, executableRequired, relativeExecutableNotAllowed, executableNotFound, workspaceRequired
    var errorDescription: String? {
        switch self {
        case .unfinishedQuote: "Finish the quoted argument or trailing backslash."
        case .executableRequired: "Enter an executable name or path."
        case .relativeExecutableNotAllowed: "Use an executable name, an absolute path, or a ~/ path."
        case .executableNotFound: "The executable does not exist or is not executable."
        case .workspaceRequired: "Choose an existing workspace folder first."
        }
    }
}
