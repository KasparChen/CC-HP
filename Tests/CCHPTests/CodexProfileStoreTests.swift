import XCTest
@testable import CCHP

final class CodexProfileStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cchp-profile-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        suiteName = "CCHPTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        if let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func testDiscoverProfilesIncludesDefaultPlusAccountSubdirs() throws {
        let defaultHome = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        let accountsRoot = tempRoot.appendingPathComponent(".codex-accounts", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: accountsRoot.appendingPathComponent("work", isDirectory: true),
            withIntermediateDirectories: true
        )

        defaults.set("Personal", forKey: "codexProfileName.\(defaultHome.path)")
        defaults.set("Work", forKey: "codexProfileName.\(accountsRoot.appendingPathComponent("work").path)")

        let store = CodexProfileStore(
            defaultHome: defaultHome,
            accountsRoot: accountsRoot,
            defaults: defaults
        )

        let profiles = store.discoverProfiles()
        XCTAssertEqual(profiles.map(\.displayName), ["Personal", "Work"])
        XCTAssertTrue(profiles[0].isDefaultHome)
        XCTAssertFalse(profiles[1].isDefaultHome)
    }

    func testDiscoverProfilesHidesLegacyDefaultBackupDirectory() throws {
        let defaultHome = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        let accountsRoot = tempRoot.appendingPathComponent(".codex-accounts", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: accountsRoot.appendingPathComponent("__default__", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: accountsRoot.appendingPathComponent("profile-1", isDirectory: true),
            withIntermediateDirectories: true
        )

        let store = CodexProfileStore(
            defaultHome: defaultHome,
            accountsRoot: accountsRoot,
            defaults: defaults
        )

        let names = store.discoverProfiles().map(\.homePath)
        XCTAssertEqual(names, [
            defaultHome.path,
            accountsRoot.appendingPathComponent("profile-1").path
        ], "Legacy __default__ leftover from earlier versions must not surface as a profile tab")
    }

    func testDefaultHomeIsDiscoveredEvenIfMissingOnDisk() {
        let defaultHome = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        let accountsRoot = tempRoot.appendingPathComponent(".codex-accounts", isDirectory: true)

        let store = CodexProfileStore(
            defaultHome: defaultHome,
            accountsRoot: accountsRoot,
            defaults: defaults
        )

        let profiles = store.discoverProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertTrue(profiles[0].isDefaultHome)
        XCTAssertEqual(profiles[0].displayName, "Default")
    }

    func testCreateProfilePicksNextNumberedSlot() throws {
        let defaultHome = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        let accountsRoot = tempRoot.appendingPathComponent(".codex-accounts", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: accountsRoot.appendingPathComponent("profile-1", isDirectory: true),
            withIntermediateDirectories: true
        )

        let store = CodexProfileStore(
            defaultHome: defaultHome,
            accountsRoot: accountsRoot,
            defaults: defaults
        )

        let profile = try store.createProfile()
        XCTAssertEqual(profile.displayName, "Profile 2")
        XCTAssertEqual(profile.homePath, accountsRoot.appendingPathComponent("profile-2").path)
        XCTAssertEqual(defaults.string(forKey: CodexProfileStore.selectedProfilePathKey), profile.homePath)
    }

    func testActivateProfileOnlyUpdatesDefaultsAndNeverTouchesAuthFiles() throws {
        let defaultHome = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        let accountsRoot = tempRoot.appendingPathComponent(".codex-accounts", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultHome, withIntermediateDirectories: true)
        try writeAuth("live-auth", to: defaultHome)
        let workHome = accountsRoot.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: workHome, withIntermediateDirectories: true)

        let store = CodexProfileStore(
            defaultHome: defaultHome,
            accountsRoot: accountsRoot,
            defaults: defaults
        )

        store.setActiveProfile(homePath: workHome.path)

        XCTAssertEqual(defaults.string(forKey: CodexProfileStore.activeProfilePathKey), workHome.path)
        XCTAssertEqual(defaults.string(forKey: CodexProfileStore.selectedProfilePathKey), workHome.path)
        XCTAssertEqual(
            try String(contentsOf: defaultHome.appendingPathComponent("auth.json")),
            "live-auth",
            "Switching profiles must never modify ~/.codex/auth.json"
        )
    }

    func testSnapshotRoundTripPreservesContent() throws {
        let defaultHome = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        let accountsRoot = tempRoot.appendingPathComponent(".codex-accounts", isDirectory: true)
        let store = CodexProfileStore(
            defaultHome: defaultHome,
            accountsRoot: accountsRoot,
            defaults: defaults
        )

        let snapshot = CodexProfileSnapshot(
            email: "work@example.com",
            planType: "team",
            accountId: "acct-1",
            orgTitle: "Work Org",
            primary: .init(usedPercent: 42.5, windowMinutes: 300, resetsAt: 1_700_000_000),
            secondary: .init(usedPercent: 18.0, windowMinutes: 10_080, resetsAt: 1_700_500_000),
            last30DaysTokens: 1_234_567,
            monthTokens: 800_000,
            days: [.init(date: "2026-05-21", tokens: 12_345)],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        store.saveSnapshot(homePath: "/tmp/codex-test-profile", snapshot: snapshot)
        let restored = store.loadSnapshot(homePath: "/tmp/codex-test-profile")

        XCTAssertEqual(restored?.email, "work@example.com")
        XCTAssertEqual(restored?.planType, "team")
        XCTAssertEqual(restored?.primary?.usedPercent, 42.5)
        XCTAssertEqual(restored?.secondary?.windowMinutes, 10_080)
        XCTAssertEqual(restored?.last30DaysTokens, 1_234_567)
        XCTAssertEqual(restored?.days.first?.tokens, 12_345)
    }

    func testDeleteProfileClearsAssociatedDefaultsAndDir() throws {
        let defaultHome = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        let accountsRoot = tempRoot.appendingPathComponent(".codex-accounts", isDirectory: true)
        let workHome = accountsRoot.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workHome, withIntermediateDirectories: true)

        let store = CodexProfileStore(
            defaultHome: defaultHome,
            accountsRoot: accountsRoot,
            defaults: defaults
        )
        store.renameProfile(homePath: workHome.path, displayName: "Work")
        store.setActiveProfile(homePath: workHome.path)
        store.saveSnapshot(homePath: workHome.path, snapshot: .init(
            email: nil, planType: nil, accountId: nil, orgTitle: nil,
            primary: nil, secondary: nil, last30DaysTokens: 0, monthTokens: 0,
            days: [], capturedAt: Date()
        ))

        store.deleteProfile(homePath: workHome.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: workHome.path))
        XCTAssertNil(defaults.string(forKey: "codexProfileName.\(workHome.path)"))
        XCTAssertNil(defaults.data(forKey: "codexProfileSnapshot.\(workHome.path)"))
        XCTAssertEqual(defaults.string(forKey: CodexProfileStore.activeProfilePathKey), defaultHome.path)
    }

    func testActiveProfilePathFallsBackToDefaultWhenSavedValueGone() throws {
        let defaultHome = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        let accountsRoot = tempRoot.appendingPathComponent(".codex-accounts", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultHome, withIntermediateDirectories: true)

        defaults.set("/some/path/that/no/longer/exists", forKey: CodexProfileStore.activeProfilePathKey)

        let store = CodexProfileStore(
            defaultHome: defaultHome,
            accountsRoot: accountsRoot,
            defaults: defaults
        )

        XCTAssertEqual(store.activeProfilePath(profiles: store.discoverProfiles()), defaultHome.path)
    }

    func testSavedProfileOrderControlsDiscoveryOrder() throws {
        let defaultHome = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        let accountsRoot = tempRoot.appendingPathComponent(".codex-accounts", isDirectory: true)
        let alphaHome = accountsRoot.appendingPathComponent("alpha", isDirectory: true)
        let betaHome = accountsRoot.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alphaHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaHome, withIntermediateDirectories: true)

        let store = CodexProfileStore(
            defaultHome: defaultHome,
            accountsRoot: accountsRoot,
            defaults: defaults
        )

        store.saveProfileOrder([betaHome.path, defaultHome.path, alphaHome.path])

        XCTAssertEqual(store.discoverProfiles().map(\.homePath), [betaHome.path, defaultHome.path, alphaHome.path])
    }

    func testCodexLoginShellSnippetLogsOutBeforeLoggingIn() {
        let snippet = CodexLoginCommand.shellSnippet
        XCTAssertTrue(snippet.contains("codex logout"))
        XCTAssertTrue(snippet.contains("codex login"))
        // logout must come before login so stale refresh tokens get
        // invalidated before the new OAuth flow starts.
        let logoutIndex = snippet.range(of: "codex logout")?.lowerBound
        let loginIndex = snippet.range(of: "codex login")?.lowerBound
        XCTAssertNotNil(logoutIndex)
        XCTAssertNotNil(loginIndex)
        if let logoutIndex, let loginIndex {
            XCTAssertLessThan(logoutIndex, loginIndex)
        }
    }

    private func writeAuth(_ content: String, to home: URL) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try content.write(to: home.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
    }
}
