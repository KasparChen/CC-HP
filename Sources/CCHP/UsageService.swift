import Foundation
import Security

let usageFilePath = NSHomeDirectory() + "/.claude/cc-check-usage.json"
let settingsPath  = NSHomeDirectory() + "/.claude/settings.json"
let hookPath      = NSHomeDirectory() + "/.claude/cc-check-hook.sh"

@MainActor
class UsageService: ObservableObject {
    @Published var usage = UsageData()
    @Published var isLoading = false
    @Published var hookInstalled = false
    @Published var statusLineEnabled = false
    @Published var now = Date()

    private var fileMonitor: DispatchSourceFileSystemObject?
    private var cachedToken: String?
    private var tickTimer: Timer?

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let token = cachedToken ?? readKeychainToken()
        if let token {
            cachedToken = token
            await fetchProfile(token: token)
        } else {
            usage.error = "Cannot read auth token from Keychain.\nGrant access when prompted."
        }

        readRateLimitsFile()
        checkHookInstalled()
        readStatusLineEnabled()
        usage.lastUpdated = Date()
    }

    func startTick() {
        stopTick()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func fetchProfile(token: String) async {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/profile") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                usage.profile = try JSONDecoder().decode(ProfileResponse.self, from: data)
                usage.error = nil
            } else if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                cachedToken = nil
                usage.error = "Token expired. Reopen to re-authenticate."
            } else {
                usage.error = "API error"
            }
        } catch {
            usage.error = "Network: \(error.localizedDescription)"
        }
    }

    private func readKeychainToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        guard let jsonStr = String(data: data, encoding: .utf8),
              let jsonData = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return token
    }

    func readRateLimitsFile() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: usageFilePath)),
              let limits = try? JSONDecoder().decode(RateLimitsFile.self, from: data) else { return }
        usage.rateLimits = limits
    }

    func startFileMonitor() {
        stopFileMonitor()
        let fd = open(usageFilePath, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in self?.readRateLimitsFile() }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileMonitor = source
    }

    func stopFileMonitor() {
        fileMonitor?.cancel()
        fileMonitor = nil
    }

    func checkHookInstalled() {
        hookInstalled = FileManager.default.fileExists(atPath: hookPath)
    }

    func installHook() {
        let hookScript = """
        #!/bin/bash
        # CC-HP - writes rate_limits from statusLine for the CC-HP menu bar app
        input=$(cat)
        five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
        five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
        week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
        week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
        ts=$(date +%s)

        if [ -n "$five_pct" ] || [ -n "$week_pct" ]; then
          jq -n \\
            --argjson five_pct "${five_pct:-null}" \\
            --argjson five_reset "${five_reset:-null}" \\
            --argjson week_pct "${week_pct:-null}" \\
            --argjson week_reset "${week_reset:-null}" \\
            --argjson ts "$ts" \\
            '{
              five_hour: (if $five_pct then {used_percentage: $five_pct, resets_at: $five_reset} else null end),
              seven_day: (if $week_pct then {used_percentage: $week_pct, resets_at: $week_reset} else null end),
              updated_at: $ts
            }' > ~/.claude/cc-check-usage.json
        fi

        if [ -n "$five_pct" ]; then
          out="5h:$(printf '%.0f' "$five_pct")%"
          [ -n "$week_pct" ] && out="$out 7d:$(printf '%.0f' "$week_pct")%"
          echo "$out"
        fi
        """

        try? hookScript.write(toFile: hookPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)
        hookInstalled = true
    }

    func readStatusLineEnabled() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            statusLineEnabled = false
            return
        }
        statusLineEnabled = json["statusLine"] != nil
    }

    func setStatusLineEnabled(_ enabled: Bool) {
        if !hookInstalled { installHook() }

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        if enabled {
            settings["statusLine"] = [
                "type": "command",
                "command": "~/.claude/cc-check-hook.sh"
            ] as [String: Any]
        } else {
            settings.removeValue(forKey: "statusLine")
        }

        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: settingsPath))
        }
        statusLineEnabled = enabled
    }
}
