import Foundation

struct CodexProfile: Identifiable, Equatable {
    let id: String
    let displayName: String
    let homePath: String
    let isDefaultHome: Bool
    let hasAuth: Bool
}

struct CodexProfileStore {
    static let activeProfilePathKey = "codexActiveProfilePath"
    static let selectedProfilePathKey = "codexSelectedProfilePath"
    static let profileOrderKey = "codexProfileOrder"

    let defaultHome: URL
    let accountsRoot: URL
    let defaults: UserDefaults
    private let fileManager: FileManager

    init(
        defaultHome: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex", isDirectory: true),
        accountsRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex-accounts", isDirectory: true),
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaultHome = defaultHome.standardizedFileURL
        self.accountsRoot = accountsRoot.standardizedFileURL
        self.defaults = defaults
        self.fileManager = fileManager
    }

    func discoverProfiles() -> [CodexProfile] {
        var homes: [URL] = []
        if fileManager.fileExists(atPath: defaultHome.path) {
            homes.append(defaultHome)
        }

        if let children = try? fileManager.contentsOfDirectory(
            at: accountsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            homes.append(contentsOf: children.filter { url in
                ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
            }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending })
        }

        return orderedProfiles(homes.map { profile(for: $0) })
    }

    func renameProfile(homePath: String, displayName: String) {
        let key = nameKey(homePath: normalizedPath(homePath))
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }

    func createProfile() throws -> CodexProfile {
        try fileManager.createDirectory(at: accountsRoot, withIntermediateDirectories: true)

        var index = 1
        var home = accountsRoot.appendingPathComponent("profile-\(index)", isDirectory: true)
        while fileManager.fileExists(atPath: home.path) {
            index += 1
            home = accountsRoot.appendingPathComponent("profile-\(index)", isDirectory: true)
        }

        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        let displayName = "Profile \(index)"
        renameProfile(homePath: home.path, displayName: displayName)
        setSelectedProfile(homePath: home.path)
        return profile(for: home)
    }

    func activeProfilePath(profiles: [CodexProfile]) -> String? {
        let defaultAuth = try? Data(contentsOf: defaultHome.appendingPathComponent("auth.json"))
        if let defaultAuth,
           let match = profiles.first(where: { profile in
               guard !profile.isDefaultHome else { return false }
               let auth = try? Data(contentsOf: URL(fileURLWithPath: profile.homePath).appendingPathComponent("auth.json"))
               return auth == defaultAuth
           }) {
            return match.homePath
        }

        if let saved = defaults.string(forKey: Self.activeProfilePathKey),
           profiles.contains(where: { $0.homePath == saved }) {
            return saved
        }

        return profiles.first(where: \.isDefaultHome)?.homePath ?? profiles.first?.homePath
    }

    func selectedProfilePath(profiles: [CodexProfile]) -> String? {
        if let saved = defaults.string(forKey: Self.selectedProfilePathKey),
           profiles.contains(where: { $0.homePath == saved }) {
            return saved
        }
        return activeProfilePath(profiles: profiles)
    }

    func setSelectedProfile(homePath: String) {
        defaults.set(normalizedPath(homePath), forKey: Self.selectedProfilePathKey)
    }

    func saveProfileOrder(_ homePaths: [String]) {
        defaults.set(homePaths.map(normalizedPath), forKey: Self.profileOrderKey)
    }

    func activateProfile(homePath: String) throws {
        let targetHome = URL(fileURLWithPath: normalizedPath(homePath), isDirectory: true)
        let targetAuth = targetHome.appendingPathComponent("auth.json")
        guard fileManager.fileExists(atPath: targetAuth.path) else {
            throw CodexProfileStoreError.missingAuth(targetHome.path)
        }

        try fileManager.createDirectory(at: defaultHome, withIntermediateDirectories: true)

        if let currentActivePath = defaults.string(forKey: Self.activeProfilePathKey),
           currentActivePath != defaultHome.path,
           currentActivePath != targetHome.path {
            let currentActiveHome = URL(fileURLWithPath: currentActivePath, isDirectory: true)
            try? fileManager.createDirectory(at: currentActiveHome, withIntermediateDirectories: true)
            try? replaceFile(
                at: currentActiveHome.appendingPathComponent("auth.json"),
                with: defaultHome.appendingPathComponent("auth.json")
            )
        }

        if targetHome.path != defaultHome.path {
            try replaceFile(at: defaultHome.appendingPathComponent("auth.json"), with: targetAuth)
        }

        defaults.set(targetHome.path, forKey: Self.activeProfilePathKey)
        defaults.set(targetHome.path, forKey: Self.selectedProfilePathKey)
    }

    private func profile(for home: URL) -> CodexProfile {
        let path = home.standardizedFileURL.path
        return CodexProfile(
            id: path,
            displayName: defaults.string(forKey: nameKey(homePath: path)) ?? defaultDisplayName(for: home),
            homePath: path,
            isDefaultHome: path == defaultHome.path,
            hasAuth: fileManager.fileExists(atPath: home.appendingPathComponent("auth.json").path)
        )
    }

    private func orderedProfiles(_ profiles: [CodexProfile]) -> [CodexProfile] {
        guard let savedOrder = defaults.stringArray(forKey: Self.profileOrderKey), !savedOrder.isEmpty else {
            return profiles
        }

        var remaining = Dictionary(uniqueKeysWithValues: profiles.map { ($0.homePath, $0) })
        var ordered: [CodexProfile] = []
        for path in savedOrder.map(normalizedPath) {
            if let profile = remaining.removeValue(forKey: path) {
                ordered.append(profile)
            }
        }

        ordered.append(contentsOf: profiles.filter { remaining[$0.homePath] != nil })
        return ordered
    }

    private func defaultDisplayName(for home: URL) -> String {
        if home.standardizedFileURL.path == defaultHome.path {
            return "Default"
        }
        return home.lastPathComponent
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func nameKey(homePath: String) -> String {
        "codexProfileName.\(homePath)"
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private func replaceFile(at destination: URL, with source: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

enum CodexProfileStoreError: LocalizedError {
    case missingAuth(String)

    var errorDescription: String? {
        switch self {
        case .missingAuth(let path):
            return "No Codex auth.json found in \(path)"
        }
    }
}
