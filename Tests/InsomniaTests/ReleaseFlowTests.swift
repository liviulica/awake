import EmberHelperKit
import Foundation
import XCTest
@testable import Insomnia

/// A helper double: a state, a recorded call list, and answers to give.
final class FakeHelper: PrivilegedHelping, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: HelperState
    private var _calls: [String] = []
    var disableAnswer: Result<HelperCommands.Result, HelperConnectionError> = .success(.init(status: 0, message: ""))
    var ruleAnswer: Result<HelperCommands.Result, HelperConnectionError> = .success(.init(status: 0, message: "wrote"))
    /// Runs when the rule is asked for, before the answer (makes a fake sudo allow it).
    var onRule: @Sendable () -> Void = {}
    /// What `register()` moves the state to.
    var stateAfterRegister: HelperState = .requiresApproval

    init(_ state: HelperState) { _state = state }

    var calls: [String] { lock.withLock { _calls } }
    var state: HelperState {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    func register() throws {
        record("register")
        state = stateAfterRegister
    }
    func unregister() async throws { record("unregister") }
    func openApprovalSettings() { record("open") }
    func disableSleep(holding lock: RecoveryLockHandle) async throws -> HelperCommands.Result {
        record("disableSleep")
        return try disableAnswer.get()
    }
    func installRestoreRule() async throws -> HelperCommands.Result {
        record("installRestoreRule")
        onRule()
        return try ruleAnswer.get()
    }
}

/// The release build's paths through the sleep guard, the lid start gate,
/// the menu and the launch decisions (spec 2026-10-17).
final class ReleaseFlowTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("release-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var log: URL { dir.appendingPathComponent("sudo.log") }
    private var allowed: URL { dir.appendingPathComponent("allowed") }
    private func sudoCalls() throws -> [String] {
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        return try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// A sudo that records its arguments; the restore commands (run or
    /// listed) pass only while the `allowed` file exists, and anything else
    /// succeeds.
    private func fakeSudo() throws -> String {
        let url = dir.appendingPathComponent("sudo")
        try TestScripts.write("""
        #!/bin/bash
        printf '%s\\n' "$*" >> "\(log.path)"
        if [[ "$2" == -l || "$*" == *"disablesleep 0"* ]]; then [[ -e "\(allowed.path)" ]]; exit; fi
        exit 0
        """, to: url)
        return url.path
    }

    /// A pgrep that finds the orphaned pmset for its first `runs` calls.
    private func fakePgrep(runs: Int) throws -> String {
        let url = dir.appendingPathComponent("pgrep")
        let count = dir.appendingPathComponent("pgrep.count")
        try TestScripts.write("""
        #!/bin/bash
        n=$(( $(/bin/cat "\(count.path)" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "\(count.path)"
        printf 'pgrep %s\\n' "$*" >> "\(log.path)"
        (( n <= \(runs) )) && exit 0
        exit 1
        """, to: url)
        return url.path
    }

    private func sleepGuard(_ helper: FakeHelper, orphanRuns: Int = 0) throws -> PmsetSleepGuard {
        PmsetSleepGuard(sudo: try fakeSudo(), pmset: "/usr/bin/pmset", timeout: 5, stopGrace: 1, admin: FakeAdminRunner(pmset: "/usr/bin/false"),
                        helper: helper, pgrep: try fakePgrep(runs: orphanRuns), orphanPoll: .milliseconds(10))
    }

    private func locked<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        let lock = RecoveryLock(url: dir.appendingPathComponent(".recovery.lock"))
        let handle = try XCTUnwrap(try lock.tryAcquire())
        defer { handle.release() }
        return try await RecoveryLock.$held.withValue(handle) { try await body() }
    }

    private func disable(_ g: PmsetSleepGuard) async throws {
        try await locked { try await g.setSleepDisabled(true) }
    }

    private func restoreProblem(_ g: PmsetSleepGuard) async throws -> String? {
        try await locked { await g.restoreProblem() }
    }

    // MARK: Turning sleep off

    func testAnEnabledHelperTurnsSleepOffAndSudoIsNotUsed() async throws {
        let helper = FakeHelper(.enabled)
        try await disable(try sleepGuard(helper))
        XCTAssertEqual(helper.calls, ["disableSleep"])
        XCTAssertEqual(try sudoCalls(), [])
    }

    func testAHelperThatCannotBeReachedFallsBackToSudo() async throws {
        let helper = FakeHelper(.enabled)
        helper.disableAnswer = .failure(HelperConnectionError(reason: "gone"))
        try await disable(try sleepGuard(helper))
        XCTAssertEqual(helper.calls, ["disableSleep"])
        XCTAssertEqual(try sudoCalls(), ["pgrep -U 0 -f ^/usr/bin/pmset -a disablesleep 1$", "-n /usr/bin/pmset -a disablesleep 1"])
    }

    /// The helper died after starting pmset: nothing else runs until that
    /// pmset is gone, so a restore can never land before it.
    func testTheFallbackWaitsForAPmsetTheHelperLeftRunning() async throws {
        let helper = FakeHelper(.enabled)
        helper.disableAnswer = .failure(HelperConnectionError(reason: "interrupted"))
        try await disable(try sleepGuard(helper, orphanRuns: 3))
        let calls = try sudoCalls()
        XCTAssertEqual(calls.filter { $0.hasPrefix("pgrep") }.count, 4, "\(calls)")
        XCTAssertEqual(calls.last, "-n /usr/bin/pmset -a disablesleep 1", "sudo only after the orphan is gone")
    }

    /// pmset ran through the helper and failed: that is the answer, not a
    /// reason to try again another way.
    func testAPmsetFailureThroughTheHelperThrowsWithoutAFallback() async throws {
        let helper = FakeHelper(.enabled)
        helper.disableAnswer = .success(.init(status: 1, message: "pmset: nope"))
        do {
            try await disable(try sleepGuard(helper))
            XCTFail("expected a throw")
        } catch let error as SleepGuardError {
            XCTAssertEqual(error.status, 1)
            XCTAssertTrue(error.localizedDescription.contains("pmset: nope"), error.localizedDescription)
        }
        XCTAssertEqual(try sudoCalls(), [])
    }

    func testAHelperWaitingForApprovalIsNotAskedAtAll() async throws {
        let helper = FakeHelper(.requiresApproval)
        try await disable(try sleepGuard(helper))
        XCTAssertEqual(helper.calls, [])
        XCTAssertEqual(try sudoCalls(), ["-n /usr/bin/pmset -a disablesleep 1"])
    }

    // MARK: The restore rule check

    func testTheRestoreRuleInPlaceIsReady() async throws {
        FileManager.default.createFile(atPath: allowed.path, contents: nil)
        let problem = try await restoreProblem(try sleepGuard(FakeHelper(.unavailable)))
        XCTAssertNil(problem)
        XCTAssertEqual(try sudoCalls(), [
            "-k -n /usr/bin/pmset -a disablesleep 0",
            "-n -l /usr/bin/pmset -b lowpowermode 1",
            "-n -l /usr/bin/pmset -b lowpowermode 0",
        ], "giving sleep back is run for real: only that proves no password is needed")
    }

    func testASourceBuildWithoutTheRuleIsToldToRunInstallSh() async throws {
        let problem = try await restoreProblem(try sleepGuard(FakeHelper(.unavailable)))
        XCTAssertTrue(problem?.contains("scripts/install.sh") == true, problem ?? "nil")
    }

    func testAReleaseBuildWaitingForApprovalIsToldWhereToApprove() async throws {
        for state in [HelperState.requiresApproval, .notRegistered, .notFound] {
            let helper = FakeHelper(state)
            let problem = try await restoreProblem(try sleepGuard(helper))
            XCTAssertTrue(problem?.contains("Login Items") == true, "\(state): \(problem ?? "nil")")
            XCTAssertEqual(helper.calls, [], "\(state)")
        }
    }

    /// An enabled helper writes a missing rule on the spot, and the check
    /// runs again.
    func testAnEnabledHelperWritesAMissingRuleThenTheStartMayGo() async throws {
        let helper = FakeHelper(.enabled)
        let flag = allowed
        helper.onRule = { FileManager.default.createFile(atPath: flag.path, contents: nil) }
        let problem = try await restoreProblem(try sleepGuard(helper))
        XCTAssertNil(problem)
        XCTAssertEqual(helper.calls, ["installRestoreRule"])
    }

    func testAnEnabledHelperThatCannotWriteTheRuleBlocksTheStart() async throws {
        let helper = FakeHelper(.enabled)
        helper.ruleAnswer = .success(.init(status: 1, message: "visudo refused"))
        let problem = try await restoreProblem(try sleepGuard(helper))
        XCTAssertTrue(problem?.contains("could not write") == true, problem ?? "nil")
    }

    // MARK: The lid start gate

    @MainActor
    func testALidStartWithoutARestorableSleepChangesNothing() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        h.guardFake.restoreProblemAnswer = "Lid mode needs your approval"
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertNil(try h.store.loadState(), "no journal written")
        XCTAssertEqual(h.guardFake.calls, [])
        XCTAssertEqual(h.backstop.arms, 0)
        XCTAssertEqual(m.lastError, "Lid mode needs your approval")
    }

    // MARK: Updates

    @MainActor
    func testTheRelaunchWaitsForTheSessionAndRunsOnce() {
        let gate = RelaunchGate()
        var installs = 0
        XCTAssertFalse(gate.shouldPostpone(busy: false) { installs += 1 }, "nothing running: relaunch now")
        XCTAssertFalse(gate.isHolding)
        XCTAssertTrue(gate.shouldPostpone(busy: true) { installs += 1 })
        XCTAssertTrue(gate.isHolding)
        gate.update(busy: true)
        XCTAssertEqual(installs, 0)
        gate.update(busy: false)
        XCTAssertEqual(installs, 1)
        XCTAssertFalse(gate.isHolding)
        gate.update(busy: false)
        XCTAssertEqual(installs, 1, "only once")
    }

    @MainActor
    func testTheVersionReadsShortAndBuild() {
        XCTAssertEqual(SettingsView.versionText(["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2000"]), "0.2.0 (2000)")
    }

    /// The checked-in Info.plist: version and build number agree (X*1000000
    /// + Y*1000 + Z), and the feed and key are what releases are signed for.
    func testInfoPlistCarriesTheFeedTheKeyAndAMatchingBuildNumber() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(info["SUFeedURL"] as? String, "https://chargingpixels.com/ember/appcast.xml")
        XCTAssertEqual(info["SUPublicEDKey"] as? String, "4MBLACdNK/mfQMaTQNHt9YCvc+bLDXFkpI1oSjayeUA=")
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        let short = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        let parts = short.split(separator: ".").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(info["CFBundleVersion"] as? String, String(parts[0] * 1_000_000 + parts[1] * 1000 + parts[2]))
    }

    // MARK: The menu

    func testTheApprovalLineAndItsActionLeadTheWarnings() {
        let items = StatusMenu.items(sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: "boom", helperNeedsApproval: true)
        let titles = items.map(\.title)
        let line = try? XCTUnwrap(titles.firstIndex(of: StatusMenu.helperApprovalLine))
        XCTAssertEqual(line, 0)
        XCTAssertEqual(items[1].kind, .approveHelper)
        XCTAssertEqual(items[1].title, "Open Login Items\u{2026}")
        XCTAssertEqual(items[2].title, "boom")
    }

    func testCheckForUpdatesSitsAboveSettingsWithTheHeldBackLine() {
        let none = StatusMenu.items(sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: nil)
        XCTAssertFalse(none.contains { $0.kind == .checkForUpdates }, "a source build has no updater")
        let items = StatusMenu.items(sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: nil, canCheckForUpdates: true, updateHeldBack: true)
        XCTAssertEqual(items.map(\.title), [StatusMenu.updateHeldBackLine, StatusMenu.checkForUpdatesTitle, StatusMenu.settingsTitle, StatusMenu.quitTitle])
        let plain = StatusMenu.items(sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: nil, canCheckForUpdates: true)
        XCTAssertEqual(plain.map(\.title), [StatusMenu.checkForUpdatesTitle, StatusMenu.settingsTitle, StatusMenu.quitTitle])
    }

    // MARK: Launch decisions

    func testRunningFromTheDmgOrATranslocatedCopyIsRefused() {
        XCTAssertNil(InstallLocation.problem(bundlePath: "/Applications/Ember.app", onReadOnlyVolume: false))
        XCTAssertNotNil(InstallLocation.problem(bundlePath: "/Volumes/Ember/Ember.app", onReadOnlyVolume: true))
        XCTAssertNotNil(InstallLocation.problem(bundlePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Ember.app", onReadOnlyVolume: false))
    }

    func testTheOldSourceInstallIsOfferedOnlyWhenItIsAnotherCopyOfEmber() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let old = home.appendingPathComponent("Applications/Ember.app")
        let ember: (URL) -> String? = { _ in Paths.bundleIdentifier }
        XCTAssertEqual(LegacyInstall.oldCopy(running: URL(fileURLWithPath: "/Applications/Ember.app"), home: home, bundleIdentifier: ember)?.path, old.path)
        XCTAssertNil(LegacyInstall.oldCopy(running: old, home: home, bundleIdentifier: ember), "it is the running one")
        // Bundle.main.bundleURL ends in a slash.
        XCTAssertNil(LegacyInstall.oldCopy(running: URL(fileURLWithPath: old.path + "/", isDirectory: true), home: home, bundleIdentifier: ember), "it is the running one, written as a directory")
        XCTAssertNil(LegacyInstall.oldCopy(running: URL(fileURLWithPath: "/Applications/Ember.app"), home: home, bundleIdentifier: { _ in nil }), "nothing there")
        XCTAssertNil(LegacyInstall.oldCopy(running: URL(fileURLWithPath: "/Applications/Ember.app"), home: home, bundleIdentifier: { _ in "com.other" }), "not Ember")
    }

    @MainActor
    func testLaunchRegistersTheHelperAndTheMenuAsksForApproval() {
        let helper = FakeHelper(.notRegistered)
        let setup = ReleaseSetup(helper: helper, updater: nil)
        setup.refreshHelper(registerIfNeeded: true)
        XCTAssertEqual(helper.calls, ["register"])
        XCTAssertEqual(setup.helperState, .requiresApproval)
        XCTAssertTrue(setup.helperNeedsApproval)
        setup.openApproval()
        XCTAssertEqual(helper.calls, ["register", "open"])
    }

    /// macOS reports a daemon that was never registered as notFound: launch
    /// registers it all the same.
    @MainActor
    func testLaunchRegistersAHelperMacOSReportsAsNotFound() {
        let helper = FakeHelper(.notFound)
        let setup = ReleaseSetup(helper: helper, updater: nil)
        setup.refreshHelper(registerIfNeeded: true)
        XCTAssertEqual(helper.calls, ["register"])
        XCTAssertEqual(setup.helperState, .requiresApproval)
    }

    /// Approved in System Settings: the next look (the menu opening) sees it
    /// and has the helper write the restore rule.
    @MainActor
    func testAnApprovalSeenLaterWritesTheRestoreRule() async throws {
        let helper = FakeHelper(.requiresApproval)
        let setup = ReleaseSetup(helper: helper, updater: nil)
        helper.state = .enabled
        setup.refreshHelper()
        XCTAssertFalse(setup.helperNeedsApproval)
        for _ in 0..<200 where !helper.calls.contains("installRestoreRule") { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(helper.calls, ["installRestoreRule"])
        setup.refreshHelper()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(helper.calls, ["installRestoreRule"], "not again while it stays enabled")
    }

    func testASourceBuildNeverShowsTheApprovalLine() async {
        let setup = await ReleaseSetup(helper: NoHelper(), updater: nil)
        let needs = await setup.helperNeedsApproval
        XCTAssertFalse(needs)
    }
}
