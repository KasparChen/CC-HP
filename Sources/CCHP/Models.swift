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
