import Foundation

struct CodexProfile: Identifiable, Equatable {
    let id: String
    let displayName: String
    let homePath: String
    let isDefaultHome: Bool
}

/// CC-HP intentionally does not own codex's auth files. `~/.codex/` is always
/// the live home and codex CLI is the sole writer of `auth.json`, `sessions/`,
/// etc. CC-HP only tracks: which profile labels exist, what the user named
/// them, and a JSON snapshot per profile capturing what that profile saw the
/// last time it was active. Switching profiles is purely a relabel plus a
/// `codex login` re-auth flow; no files inside `~/.codex/` are read or moved.
struct CodexProfileStore {
    static let activeProfilePathKey = "codexActiveProfilePath"
    static let selectedProfilePathKey = "codexSelectedProfilePath"
    static let profileOrderKey = "codexProfileOrder"

    /// Reserved subdirectory name left behind by an earlier version of CC-HP
    /// that used `~/.codex-accounts/__default__/` as a backup slot. Current
    /// code no longer reads or writes it, but it must be hidden from the
    /// profile list so it doesn't surface as a phantom tab.
    static let legacyReservedDirNames: Set<String> = ["__default__"]

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
        var homes: [URL] = [defaultHome]

        if let children = try? fileManager.contentsOfDirectory(
            at: accountsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let extras = children.filter { url in
                guard ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) else {
                    return false
                }
                return !Self.legacyReservedDirNames.contains(url.lastPathComponent)
            }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            homes.append(contentsOf: extras)
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

    /// Allocate an ID for a new profile. The directory is created only as an
    /// ID slot so the profile survives across CC-HP launches; codex CLI
    /// itself never sees this path.
    func createProfile() throws -> CodexProfile {
        try fileManager.createDirectory(at: accountsRoot, withIntermediateDirectories: true)

        var index = 1
        var home = accountsRoot.appendingPathComponent("profile-\(index)", isDirectory: true)
        while fileManager.fileExists(atPath: home.path) {
            index += 1
            home = accountsRoot.appendingPathComponent("profile-\(index)", isDirectory: true)
        }

        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        renameProfile(homePath: home.path, displayName: "Profile \(index)")
        setSelectedProfile(homePath: home.path)
        return profile(for: home)
    }

    func deleteProfile(homePath: String) {
        let normalized = normalizedPath(homePath)
        guard normalized != defaultHome.path else { return }
        let url = URL(fileURLWithPath: normalized, isDirectory: true)
        try? fileManager.removeItem(at: url)
        defaults.removeObject(forKey: nameKey(homePath: normalized))
        defaults.removeObject(forKey: snapshotKey(homePath: normalized))
        if defaults.string(forKey: Self.activeProfilePathKey) == normalized {
            defaults.set(defaultHome.path, forKey: Self.activeProfilePathKey)
        }
        if defaults.string(forKey: Self.selectedProfilePathKey) == normalized {
            defaults.set(defaultHome.path, forKey: Self.selectedProfilePathKey)
        }
        if var order = defaults.stringArray(forKey: Self.profileOrderKey) {
            order.removeAll { normalizedPath($0) == normalized }
            defaults.set(order, forKey: Self.profileOrderKey)
        }
    }

    func activeProfilePath(profiles: [CodexProfile]) -> String? {
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

    func setActiveProfile(homePath: String) {
        let normalized = normalizedPath(homePath)
        defaults.set(normalized, forKey: Self.activeProfilePathKey)
        defaults.set(normalized, forKey: Self.selectedProfilePathKey)
    }

    func saveProfileOrder(_ homePaths: [String]) {
        defaults.set(homePaths.map(normalizedPath), forKey: Self.profileOrderKey)
    }

    func loadSnapshot(homePath: String) -> CodexProfileSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey(homePath: normalizedPath(homePath))) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodexProfileSnapshot.self, from: data)
    }

    func saveSnapshot(homePath: String, snapshot: CodexProfileSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey(homePath: normalizedPath(homePath)))
    }

    private func profile(for home: URL) -> CodexProfile {
        let path = home.standardizedFileURL.path
        return CodexProfile(
            id: path,
            displayName: defaults.string(forKey: nameKey(homePath: path)) ?? defaultDisplayName(for: home),
            homePath: path,
            isDefaultHome: path == defaultHome.path
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

    private func snapshotKey(homePath: String) -> String {
        "codexProfileSnapshot.\(homePath)"
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}
