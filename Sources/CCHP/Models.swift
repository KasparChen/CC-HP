import Foundation

struct ProfileResponse: Codable {
    let account: AccountInfo?
    let organization: OrgInfo?
    let application: AppInfo?
}

struct AccountInfo: Codable {
    let uuid: String?
    let full_name: String?
    let display_name: String?
    let email: String?
    let has_claude_max: Bool?
    let has_claude_pro: Bool?
    let created_at: String?
}

struct OrgInfo: Codable {
    let uuid: String?
    let name: String?
    let organization_type: String?
    let billing_type: String?
    let rate_limit_tier: String?
    let has_extra_usage_enabled: Bool?
    let subscription_status: String?
    let subscription_created_at: String?
}

struct AppInfo: Codable {
    let uuid: String?
    let name: String?
    let slug: String?
}

struct RateLimitsFile: Codable {
    let five_hour: RateWindow?
    let seven_day: RateWindow?
    let updated_at: Double?
}

struct RateWindow: Codable {
    let used_percentage: Double
    let resets_at: Double
}

// MARK: - Cost Tracking

struct CostHistory: Codable {
    var days: [DailyCost]
    var updated_at: Double?

    static let empty = CostHistory(days: [], updated_at: nil)
}

struct DailyCost: Codable {
    let date: String            // "2026-04-02"
    var cost: Double            // Estimated cost (USD)
    var tokens: Int64           // Total tokens
    var api_cost: Double        // API / extra-usage cost
    var api_tokens: Int64       // API / extra-usage tokens
    var models: [ModelCost]     // Per-model breakdown

    var totalCost: Double  { cost + api_cost }
    var totalTokens: Int64 { tokens + api_tokens }

    static func zero(date: String) -> DailyCost {
        DailyCost(date: date, cost: 0, tokens: 0, api_cost: 0, api_tokens: 0, models: [])
    }
}

struct ModelCost: Codable {
    var model: String
    var cost: Double
    var tokens: Int64
}

// MARK: - OAuth Extra Usage Response

struct OAuthUsageResponse: Codable {
    let extraUsage: OAuthExtraUsage?

    enum CodingKeys: String, CodingKey {
        case extraUsage = "extra_usage"
    }
}

struct OAuthExtraUsage: Codable {
    let isEnabled: Bool?
    let monthlyLimit: Double?   // cents
    let usedCredits: Double?    // cents
    let utilization: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
    }
}

// MARK: - Model Pricing (per-token USD)

// Pricing from CodexBar (matches Anthropic published rates).
// Sonnet 4/4.5 have tiered pricing above 200K token threshold.
struct ModelPricing {
    let inputPerToken: Double
    let outputPerToken: Double
    let cacheReadPerToken: Double
    let cacheCreatePerToken: Double
    // Tiered pricing (Sonnet only)
    let inputAbove: Double?
    let outputAbove: Double?
    let cacheReadAbove: Double?
    let cacheCreateAbove: Double?
    let threshold: Int64?

    static func forModel(_ model: String) -> ModelPricing {
        let m = model.lowercased()

        // Opus 4.5 / 4.6: $5 input, $25 output
        if m.contains("opus-4-5") || m.contains("opus-4-6") {
            return ModelPricing(
                inputPerToken: 5e-6, outputPerToken: 2.5e-5,
                cacheReadPerToken: 5e-7, cacheCreatePerToken: 6.25e-6,
                inputAbove: nil, outputAbove: nil,
                cacheReadAbove: nil, cacheCreateAbove: nil, threshold: nil)
        }
        // Opus 4.0 (legacy): $15 input, $75 output
        if m.contains("opus") {
            return ModelPricing(
                inputPerToken: 1.5e-5, outputPerToken: 7.5e-5,
                cacheReadPerToken: 1.5e-6, cacheCreatePerToken: 1.875e-5,
                inputAbove: nil, outputAbove: nil,
                cacheReadAbove: nil, cacheCreateAbove: nil, threshold: nil)
        }
        // Haiku 4.5: $1 input, $5 output
        if m.contains("haiku") {
            return ModelPricing(
                inputPerToken: 1e-6, outputPerToken: 5e-6,
                cacheReadPerToken: 1e-7, cacheCreatePerToken: 1.25e-6,
                inputAbove: nil, outputAbove: nil,
                cacheReadAbove: nil, cacheCreateAbove: nil, threshold: nil)
        }
        // Sonnet 4 / 4.5 / 4.6: $3 input, $15 output, tiered at 200K
        return ModelPricing(
            inputPerToken: 3e-6, outputPerToken: 1.5e-5,
            cacheReadPerToken: 3e-7, cacheCreatePerToken: 3.75e-6,
            inputAbove: 6e-6, outputAbove: 2.25e-5,
            cacheReadAbove: 6e-7, cacheCreateAbove: 7.5e-6, threshold: 200_000)
    }

    func cost(input: Int64, output: Int64, cacheRead: Int64, cacheCreate: Int64) -> Double {
        tiered(input, base: inputPerToken, above: inputAbove) +
        tiered(output, base: outputPerToken, above: outputAbove) +
        tiered(cacheRead, base: cacheReadPerToken, above: cacheReadAbove) +
        tiered(cacheCreate, base: cacheCreatePerToken, above: cacheCreateAbove)
    }

    private func tiered(_ tokens: Int64, base: Double, above: Double?) -> Double {
        guard let threshold, let above else { return Double(tokens) * base }
        let below = min(tokens, threshold)
        let over  = max(tokens - threshold, 0)
        return Double(below) * base + Double(over) * above
    }
}

// MARK: - Aggregated state

struct UsageData {
    var profile: ProfileResponse?
    var rateLimits: RateLimitsFile?
    var lastUpdated: Date = Date()
    var error: String?

    var planDisplay: String {
        guard let org = profile?.organization else { return "Unknown" }
        let type = org.organization_type ?? "unknown"
        switch type {
        case "claude_team": return "Team"
        case "claude_max": return "Max"
        case "claude_pro": return "Pro"
        case "claude_enterprise": return "Enterprise"
        default: return type.capitalized
        }
    }

    var tierDisplay: String {
        guard let tier = profile?.organization?.rate_limit_tier else { return "-" }
        return tier
            .replacingOccurrences(of: "default_claude_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
