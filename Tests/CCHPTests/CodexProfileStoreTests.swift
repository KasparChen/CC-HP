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

    func testDiscoverProfilesIncludesDefaultHomeAndAccountHomes() throws {
        let defaultHome = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        let accountsRoot = tempRoot.appendingPathComponent(".codex-accounts", isDirectory: true)
        let orgHome = accountsRoot.appendingPathComponent("org", isDirectory: true)
        try writeAuth("default-auth", to: defaultHome)
        try writeAuth("org-auth", to: orgHome)

        defaults.set("Personal", forKey: "codexProfileName.\(defaultHome.path)")
        defaults.set("Work", forKey: "codexProfileName.\(orgHome.path)")

        let store = CodexProfileStore(
            defaultHome: defaultHome,
            accountsRoot: accountsRoot,
            defaults: defaults
        )

        let profiles = store.discoverProfiles()

        XCTAssertEqual(profiles.map(\.displayName), ["Personal", "Work"])
        XCTAssertEqual(profiles.map(\.homePath), [defaultHome.path, orgHome.path])
        XCTAssertEqual(profiles.map(\.hasAuth), [true, true])
        XCTAssertTrue(profiles[0].isDefaultHome)
        XCTAssertFalse(profiles[1].isDefaultHome)
    }

    func testRenameProfilePersistsDisplayNameByPath() throws {
        let defaultHome = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        let accountsRoot = tempRoot.appendingPathComponent(".codex-accounts", isDirectory: true)
        try writeAuth("default-auth", to: defaultHome)

        let store = CodexProfileStore(
            defaultHome: defaultHome,
            accountsRoot: accountsRoot,
            defaults: defaults
        )

        store.renameProfile(homePath: defaultHome.path, displayName: "Personal")

        XCTAssertEqual(store.discoverProfiles().first?.displayName, "Personal")
    }

    func testCreateProfileCreatesNextAccountHomeAndPersistsName() throws {
        let defaultHome = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        let accountsRoot = tempRoot.appendingPathComponent(".codex-accounts", isDirectory: true)
        try writeAuth("default-auth", to: defaultHome)
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
        XCTAssertEqual(profile.homePath, accountsRoot.appendingPathComponent("profile-2", isDirectory: true).path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.homePath))
        XCTAssertEqual(defaults.string(forKey: CodexProfileStore.selectedProfilePathKey), profile.homePath)
        XCTAssertEqual(store.discoverProfiles().map(\.displayName), ["Default", "Profile 1", "Profile 2"])
    }

    func testActivateProfileCopiesSelectedAuthIntoDefaultHome() throws {
        let defaultHome = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        let accountsRoot = tempRoot.appendingPathComponent(".codex-accounts", isDirectory: true)
        let orgHome = accountsRoot.appendingPathComponent("org", isDirectory: true)
        try writeAuth("default-auth", to: defaultHome)
        try writeAuth("org-auth", to: orgHome)

        let store = CodexProfileStore(
            defaultHome: defaultHome,
            accountsRoot: accountsRoot,
            defaults: defaults
        )

        try store.activateProfile(homePath: orgHome.path)

        let activeAuth = try String(contentsOf: defaultHome.appendingPathComponent("auth.json"))
        XCTAssertEqual(activeAuth, "org-auth")
        XCTAssertEqual(defaults.string(forKey: CodexProfileStore.activeProfilePathKey), orgHome.path)
    }

    func testActiveProfilePrefersCurrentDefaultAuthOverStaleSavedPath() throws {
        let defaultHome = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        let accountsRoot = tempRoot.appendingPathComponent(".codex-accounts", isDirectory: true)
        let personalHome = accountsRoot.appendingPathComponent("personal", isDirectory: true)
        let teamHome = accountsRoot.appendingPathComponent("team", isDirectory: true)
        try writeAuth("team-auth", to: defaultHome)
        try writeAuth("personal-auth", to: personalHome)
        try writeAuth("team-auth", to: teamHome)

        defaults.set(personalHome.path, forKey: CodexProfileStore.activeProfilePathKey)

        let store = CodexProfileStore(
            defaultHome: defaultHome,
            accountsRoot: accountsRoot,
            defaults: defaults
        )

        let activePath = store.activeProfilePath(profiles: store.discoverProfiles())

        XCTAssertEqual(activePath, teamHome.path)
    }

    func testCodexLoginCommandQuotesProfilePath() {
        let command = CodexLoginCommand.terminalCommand(homePath: "/tmp/codex accounts/work's")

        XCTAssertTrue(command.contains("CODEX_HOME='/tmp/codex accounts/work'\\''s' codex login"))
    }

    private func writeAuth(_ content: String, to home: URL) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try content.write(to: home.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
    }
}
