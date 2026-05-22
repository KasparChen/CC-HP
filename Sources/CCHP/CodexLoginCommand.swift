import Foundation

enum CodexLoginCommand {
    /// Shell snippet that is fed to `sh -c` when CC-HP wants to re-authenticate
    /// a profile. The defensive `codex logout` first drops whatever refresh
    /// token is currently on disk so the subsequent `codex login` always
    /// starts a fresh OAuth flow instead of attempting to refresh a possibly
    /// invalidated token.
    static let shellSnippet = "codex logout >/dev/null 2>&1; exec codex login"
}
