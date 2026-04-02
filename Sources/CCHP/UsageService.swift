import Foundation
import Security

let usageFilePath    = NSHomeDirectory() + "/.claude/cc-check-usage.json"
let settingsPath     = NSHomeDirectory() + "/.claude/settings.json"
let hookPath         = NSHomeDirectory() + "/.claude/cc-check-hook.sh"
let costCachePath    = NSHomeDirectory() + "/.claude/cc-hp-cost.json"
let claudeProjectDir = NSHomeDirectory() + "/.claude/projects"

@MainActor
class UsageService: ObservableObject {
    @Published var usage = UsageData()
    @Published var isLoading = false
    @Published var hookInstalled = false
    @Published var statusLineEnabled = false
    @Published var now = Date()
    @Published var costHistory = CostHistory.empty
    @Published var extraUsage: OAuthExtraUsage?

    private var fileMonitor: DispatchSourceFileSystemObject?
    private var cachedToken: String?
    private var tickTimer: Timer?

    init() {
        // Load cached cost data so the UI isn't empty on first open
        loadCachedCostHistory()
    }

    func refresh() async {
        // Prevent concurrent refreshes (e.g., button mash)
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let token = cachedToken ?? readKeychainToken()
        if let token {
            cachedToken = token
            await fetchProfile(token: token)
            await fetchUsage(token: token)
        } else {
            usage.error = "Cannot read auth token from Keychain.\nGrant access when prompted."
        }

        checkHookInstalled()
        readStatusLineEnabled()
        usage.lastUpdated = Date()

        // Scan JSONL logs in background (CPU-bound)
        await scanCostFromLogs()
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

    // MARK: - Profile

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
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                NSLog("[CC-HP] /oauth/profile returned %d", code)
                usage.error = "API error (\(code))"
            }
        } catch {
            usage.error = "Network: \(error.localizedDescription)"
        }
    }

    // MARK: - OAuth Usage (rate limits + extra usage from single endpoint)

    private func fetchUsage(token: String) async {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                NSLog("[CC-HP] /oauth/usage: no HTTP response")
                readRateLimitsFile()
                return
            }

            guard http.statusCode == 200 else {
                NSLog("[CC-HP] /oauth/usage returned %d", http.statusCode)
                if http.statusCode == 401 {
                    cachedToken = nil
                    usage.error = "Token expired. Reopen to re-authenticate."
                }
                readRateLimitsFile()
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[CC-HP] /oauth/usage: invalid JSON")
                readRateLimitsFile()
                return
            }

            // Handle both flat and nested response structures:
            //   Flat:   { "five_hour": {...}, "seven_day": {...}, "extra_usage": {...} }
            //   Nested: { "rate_limits": { "five_hour": {...}, "seven_day": {...} }, "extra_usage": {...} }
            let rateLimitsDict = json["rate_limits"] as? [String: Any]
            let fiveHourRaw = json["five_hour"] ?? rateLimitsDict?["five_hour"]
            let sevenDayRaw = json["seven_day"] ?? rateLimitsDict?["seven_day"]

            let fiveHour = parseRateWindow(fiveHourRaw)
            let sevenDay = parseRateWindow(sevenDayRaw)

            if fiveHour != nil || sevenDay != nil {
                usage.rateLimits = RateLimitsFile(
                    five_hour: fiveHour,
                    seven_day: sevenDay,
                    updated_at: Date().timeIntervalSince1970
                )
            } else {
                // Log the response keys for debugging
                NSLog("[CC-HP] /oauth/usage: could not parse rate windows. Top-level keys: %@", json.keys.sorted().description)
                if let rl = rateLimitsDict {
                    NSLog("[CC-HP]   rate_limits keys: %@", rl.keys.sorted().description)
                }
                // Fall back to cached file
                readRateLimitsFile()
            }

            // Parse extra_usage
            if let extraDict = json["extra_usage"] as? [String: Any] {
                extraUsage = OAuthExtraUsage(
                    isEnabled: extraDict["is_enabled"] as? Bool,
                    monthlyLimit: extraDict["monthly_limit"] as? Double,
                    usedCredits: extraDict["used_credits"] as? Double,
                    utilization: extraDict["utilization"] as? Double,
                    currency: extraDict["currency"] as? String
                )
            }
        } catch {
            NSLog("[CC-HP] /oauth/usage network error: %@", error.localizedDescription)
            readRateLimitsFile()
        }
    }

    /// Parse a rate window dict. Handles both field naming conventions:
    ///   API:  {"utilization": 16.0, "resets_at": "2026-04-02T18:00:00+00:00"}
    ///   Hook: {"used_percentage": 16.0, "resets_at": 1743609600}
    private func parseRateWindow(_ obj: Any?) -> RateWindow? {
        guard let dict = obj as? [String: Any] else { return nil }

        // Accept both "utilization" (API) and "used_percentage" (hook file)
        guard let pct = (dict["utilization"] as? Double)
                     ?? (dict["used_percentage"] as? Double) else {
            NSLog("[CC-HP] parseRateWindow: missing utilization/used_percentage in %@", dict.keys.sorted().description)
            return nil
        }

        // Parse resets_at — could be ISO8601 string or epoch number
        let epoch: Double
        if let resetsAtStr = dict["resets_at"] as? String {
            let fmts = [ISO8601DateFormatter(), ISO8601DateFormatter()]
            fmts[0].formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            fmts[1].formatOptions = [.withInternetDateTime]
            guard let date = fmts[0].date(from: resetsAtStr) ?? fmts[1].date(from: resetsAtStr) else {
                NSLog("[CC-HP] parseRateWindow: failed to parse resets_at string: %@", resetsAtStr)
                return nil
            }
            epoch = date.timeIntervalSince1970
        } else if let resetsAtNum = dict["resets_at"] as? Double {
            epoch = resetsAtNum
        } else if let resetsAtInt = dict["resets_at"] as? Int {
            epoch = Double(resetsAtInt)
        } else {
            NSLog("[CC-HP] parseRateWindow: missing resets_at")
            return nil
        }

        return RateWindow(used_percentage: pct, resets_at: epoch)
    }

    // MARK: - Keychain

    private func readKeychainToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            NSLog("[CC-HP] Keychain read failed: %d", status)
            return nil
        }
        guard let jsonStr = String(data: data, encoding: .utf8),
              let jsonData = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            NSLog("[CC-HP] Keychain: failed to parse token structure")
            return nil
        }
        return token
    }

    // MARK: - Rate Limits File

    func readRateLimitsFile() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: usageFilePath)),
              let limits = try? JSONDecoder().decode(RateLimitsFile.self, from: data) else { return }
        usage.rateLimits = limits
    }

    func startFileMonitor() {
        stopFileMonitor()
        let fd = open(usageFilePath, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[CC-HP] File monitor: cannot open %@", usageFilePath)
            return
        }
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

    // MARK: - Hook

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

    // MARK: - Cost: JSONL Log Scanner

    func scanCostFromLogs() async {
        let history = await Task.detached(priority: .userInitiated) {
            Self.scanAllJSONLLogs()
        }.value
        costHistory = history
        saveCostHistory()
    }

    /// Scans all ~/.claude/projects/**/*.jsonl for assistant messages with usage data.
    /// Groups by LOCAL day (system timezone) + model, calculates cost using known pricing.
    private nonisolated static func scanAllJSONLLogs() -> CostHistory {
        let fm = FileManager.default
        let baseURL = URL(fileURLWithPath: claudeProjectDir)
        guard let enumerator = fm.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return .empty }

        // Only scan files from last 30 days
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()

        // ISO8601 parser for UTC timestamps in logs
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFmtFallback = ISO8601DateFormatter()
        isoFmtFallback.formatOptions = [.withInternetDateTime]

        // Local day formatter (system timezone)
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        dayFmt.timeZone = .current

        // dayKey -> modelKey -> (input, output, cacheRead, cacheCreate)
        var accum: [String: [String: (Int64, Int64, Int64, Int64)]] = [:]
        var seenIds = Set<String>()

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }

            // Skip files not modified in last 30 days
            if let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               modDate < cutoff { continue }

            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { continue }
            defer { handle.closeFile() }

            let data = handle.readDataToEndOfFile()
            guard let content = String(data: data, encoding: .utf8) else { continue }

            for line in content.split(separator: "\n") where line.contains("\"usage\"") && line.contains("\"assistant\"") {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      json["type"] as? String == "assistant",
                      let message = json["message"] as? [String: Any],
                      let model = message["model"] as? String,
                      let usageObj = message["usage"] as? [String: Any],
                      let timestamp = json["timestamp"] as? String else { continue }

                // Skip synthetic / empty models
                if model.hasPrefix("<") { continue }

                // Deduplicate by message ID + requestId
                let msgId = message["id"] as? String ?? ""
                let reqId = json["requestId"] as? String ?? ""
                let dedupKey = "\(msgId)|\(reqId)"
                guard !dedupKey.isEmpty, !seenIds.contains(dedupKey) else { continue }
                seenIds.insert(dedupKey)

                // Parse UTC timestamp → local day string
                guard let utcDate = isoFmt.date(from: timestamp) ?? isoFmtFallback.date(from: timestamp) else { continue }
                let dayKey = dayFmt.string(from: utcDate)

                let input      = (usageObj["input_tokens"] as? Int64)
                                 ?? Int64(usageObj["input_tokens"] as? Int ?? 0)
                let output     = (usageObj["output_tokens"] as? Int64)
                                 ?? Int64(usageObj["output_tokens"] as? Int ?? 0)
                let cacheRead  = (usageObj["cache_read_input_tokens"] as? Int64)
                                 ?? Int64(usageObj["cache_read_input_tokens"] as? Int ?? 0)
                let cacheCreate = (usageObj["cache_creation_input_tokens"] as? Int64)
                                  ?? Int64(usageObj["cache_creation_input_tokens"] as? Int ?? 0)

                var modelMap = accum[dayKey] ?? [:]
                let prev = modelMap[model] ?? (0, 0, 0, 0)
                modelMap[model] = (prev.0 + input, prev.1 + output, prev.2 + cacheRead, prev.3 + cacheCreate)
                accum[dayKey] = modelMap
            }
        }

        // Convert to CostHistory
        var days: [DailyCost] = []
        for (dayKey, modelMap) in accum {
            var totalCost = 0.0
            var totalTokens: Int64 = 0
            var models: [ModelCost] = []

            for (model, (inp, out, cr, cc)) in modelMap {
                let pricing = ModelPricing.forModel(model)
                let cost = pricing.cost(input: inp, output: out, cacheRead: cr, cacheCreate: cc)
                let tokens = inp + out + cr + cc
                totalCost += cost
                totalTokens += tokens
                models.append(ModelCost(model: model, cost: cost, tokens: tokens))
            }

            models.sort { $0.cost > $1.cost }
            days.append(DailyCost(
                date: dayKey, cost: totalCost, tokens: totalTokens,
                api_cost: 0, api_tokens: 0, models: models
            ))
        }

        days.sort { $0.date < $1.date }
        return CostHistory(days: days, updated_at: Date().timeIntervalSince1970)
    }

    private func saveCostHistory() {
        guard let data = try? JSONEncoder().encode(costHistory) else { return }
        try? data.write(to: URL(fileURLWithPath: costCachePath))
    }

    private func loadCachedCostHistory() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: costCachePath)),
              let cached = try? JSONDecoder().decode(CostHistory.self, from: data) else { return }
        costHistory = cached
    }

    // MARK: - Cost Computed Properties

    var todayCost: DailyCost {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.timeZone = .current
        let today = fmt.string(from: Date())
        return costHistory.days.first { $0.date == today } ?? .zero(date: today)
    }

    var monthCost: (cost: Double, tokens: Int64) {
        let cal = Calendar.current
        let month = cal.component(.month, from: Date())
        let year  = cal.component(.year,  from: Date())
        let filtered = costHistory.days.filter { day in
            let p = day.date.split(separator: "-")
            guard p.count >= 2, let y = Int(p[0]), let m = Int(p[1]) else { return false }
            return y == year && m == month
        }
        return (
            filtered.reduce(0)       { $0 + $1.totalCost },
            filtered.reduce(Int64(0)) { $0 + $1.totalTokens }
        )
    }

    var last30DaysCost: (cost: Double, tokens: Int64) {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.timeZone = .current
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -30, to: Date()) else { return (0, 0) }
        let cutoffStr = fmt.string(from: cutoff)
        let filtered = costHistory.days.filter { $0.date >= cutoffStr }
        return (
            filtered.reduce(0)       { $0 + $1.totalCost },
            filtered.reduce(Int64(0)) { $0 + $1.totalTokens }
        )
    }

    var last14Days: [DailyCost] {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.timeZone = .current
        let cal = Calendar.current
        return (0..<14).reversed().map { i in
            let date = cal.date(byAdding: .day, value: -i, to: Date())!
            let ds = fmt.string(from: date)
            return costHistory.days.first { $0.date == ds } ?? .zero(date: ds)
        }
    }

    // MARK: - Settings

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
