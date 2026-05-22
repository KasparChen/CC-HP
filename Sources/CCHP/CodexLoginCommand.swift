import Foundation

enum CodexLoginCommand {
    static func terminalCommand(homePath: String) -> String {
        """
        CODEX_HOME=\(shellQuoted(homePath)) codex login; printf '\\nCodex login finished. You can close this window.\\n'
        """
    }

    static func appleScriptLiteral(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
