import EmberHelperKit
import Foundation
import XCTest

/// The helper's shared pieces (spec 2026-10-17 "The helper"): the names and
/// requirements both sides use, the restore rule, and the two root commands
/// run against fake tools.
final class HelperKitTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("helperkit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: Names

    func testTheRequirementsNameTheTeamAndEachIdentifier() {
        XCTAssertEqual(HelperNames.appRequirement, #"anchor apple generic and identifier "app.chargingpixels.ember" and certificate leaf[subject.OU] = "4UA742BB8G""#)
        XCTAssertEqual(HelperNames.helperRequirement, #"anchor apple generic and identifier "app.chargingpixels.ember.helper" and certificate leaf[subject.OU] = "4UA742BB8G""#)
        for text in [HelperNames.appRequirement, HelperNames.helperRequirement] {
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess, text)
        }
    }

    /// The daemon plist SMAppService registers says what the app and the
    /// helper use: label, Mach service, program path, and the app it
    /// belongs to.
    func testTheDaemonPlistMatchesTheNames() throws {
        let url = Self.repoRoot.appendingPathComponent("Resources/\(HelperNames.daemonPlistName)")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, HelperNames.helperIdentifier)
        XCTAssertEqual(plist["BundleProgram"] as? String, HelperNames.bundleProgram)
        XCTAssertEqual(plist["MachServices"] as? [String: Bool], [HelperNames.machService: true])
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], [HelperNames.appIdentifier])
        XCTAssertEqual(Set(plist.keys), ["Label", "BundleProgram", "MachServices", "AssociatedBundleIdentifiers"])
    }

    // MARK: Restore rule

    func testTheRuleHoldsOnlyTheThreeRestoreCommands() {
        let text = RestoreRule.text(user: "liviu")
        let rules = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(rules, [
            "liviu ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0",
            "liviu ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1",
            "liviu ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0",
        ])
        XCTAssertFalse(text.contains("disablesleep 1"), "turning sleep off is the helper's alone")
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    /// The rule is the same three lines install.sh writes (it writes a
    /// fourth, the passwordless disable), so backstop.sh keeps working.
    func testTheRuleLinesAreInstallShsRestoreLines() throws {
        let install = try String(contentsOf: Self.repoRoot.appendingPathComponent("scripts/install.sh"), encoding: .utf8)
        for args in RestoreRule.commands {
            XCTAssertTrue(install.contains("$USER ALL=(root) NOPASSWD: /usr/bin/pmset \(args.joined(separator: " "))"), args.joined(separator: " "))
        }
    }

    func testUserNamesThatSudoersCouldReadAsSyntaxAreRefused() {
        for good in ["liviu", "_spotify", "a.b-c_1"] { XCTAssertTrue(RestoreRule.isValidUserName(good), good) }
        for bad in ["", "Root", "a b", "a,b", "ALL", "x\nroot ALL=(ALL) ALL", "%admin", "a:b", String(repeating: "a", count: 40)] {
            XCTAssertFalse(RestoreRule.isValidUserName(bad), bad)
        }
        XCTAssertEqual(RestoreRule.userName(forUID: getuid()), NSUserName())
    }

    // MARK: Commands

    private func script(_ name: String, _ body: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try TestScripts.write("#!/bin/bash\n" + body, to: url)
        return url.path
    }

    private var log: URL { dir.appendingPathComponent("log") }
    private func logged() throws -> [String] {
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        return try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// pmset gets the lock descriptor as standard input: while it runs, the
    /// lock is not free even though the caller's copy was closed.
    func testDisableSleepRunsPmsetWithTheLockAsStandardInput() throws {
        let lockFile = dir.appendingPathComponent(".recovery.lock")
        FileManager.default.createFile(atPath: lockFile.path, contents: nil)
        let inode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: lockFile.path)[.systemFileNumber] as? Int)
        let pmset = try script("pmset", """
        printf 'pmset %s\\n' "$*" >> "\(log.path)"
        printf 'stdin %s\\n' "$(/usr/bin/stat -f %i)" >> "\(log.path)"
        echo done
        """)
        let handle = try FileHandle(forReadingFrom: lockFile)
        let r = HelperCommands(pmset: pmset).disableSleep(lock: handle)
        XCTAssertEqual(r.status, 0, r.message)
        XCTAssertEqual(r.message, "done")
        XCTAssertEqual(try logged(), ["pmset -a disablesleep 1", "stdin \(inode)"])
    }

    /// Past the limit pmset gets SIGTERM, and the answer still waits for its
    /// exit; it is never killed.
    func testDisableSleepWaitsForAPmsetThatOutlivesItsLimit() throws {
        let pmset = try script("pmset", """
        trap 'echo term >> "\(log.path)"; sleep 0.5; echo exited >> "\(log.path)"; exit 0' TERM
        echo started >> "\(log.path)"
        while :; do sleep 0.05; done
        """)
        let started = Date()
        let r = HelperCommands(pmset: pmset, pmsetTimeout: 0.5).disableSleep(lock: nil)
        XCTAssertNotEqual(r.status, 0, "a pmset stopped at its limit is a failure even when it exits 0")
        XCTAssertTrue(r.message.contains("SIGTERM"), r.message)
        XCTAssertEqual(try logged(), ["started", "term", "exited"], "answered only after pmset exited")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9)
    }

    func testDisableSleepReportsAPmsetThatCannotStart() {
        let r = HelperCommands(pmset: dir.appendingPathComponent("missing").path).disableSleep(lock: nil)
        XCTAssertEqual(r.status, HelperStatus.notRun)
    }

    private func ruleTools(visudoExit: Int = 0) throws -> HelperCommands {
        let visudo = try script("visudo", """
        printf 'visudo %s\\n' "$*" >> "\(log.path)"
        exit \(visudoExit)
        """)
        // install -m 0440 -o root -g wheel <src> <dst>: copy, as root would.
        let install = try script("install", """
        printf 'install %s\\n' "${*:1:6}" >> "\(log.path)"
        /bin/cp "$7" "$8"
        """)
        let sudoers = dir.appendingPathComponent("sudoers.d", isDirectory: true)
        try FileManager.default.createDirectory(at: sudoers, withIntermediateDirectories: true)
        return HelperCommands(visudo: visudo, install: install, sudoersDirectory: sudoers.path, temporaryDirectory: dir)
    }

    func testTheRuleIsCheckedWithVisudoThenInstalledRootOwned() throws {
        let tools = try ruleTools()
        let r = tools.installRestoreRule(user: "liviu", uid: 501)
        XCTAssertEqual(r.status, 0, r.message)
        XCTAssertEqual(tools.rulePath(forUID: 501), dir.appendingPathComponent("sudoers.d/ember-501").path, "one file per uid, no dot in the name")
        XCTAssertEqual(try String(contentsOfFile: tools.rulePath(forUID: 501), encoding: .utf8), RestoreRule.text(user: "liviu"))
        let calls = try logged()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[0].hasPrefix("visudo -cf \(dir.path)/ember-sudoers-"), calls[0])
        XCTAssertEqual(calls[1], "install -m 0440 -o root -g wheel")
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("ember-sudoers-") }
        XCTAssertEqual(left, [], "the temp file is removed")
    }

    /// A changed rule is replaced; the same rule is left alone without
    /// running anything.
    func testAnUnchangedRuleIsNotRewritten() throws {
        let tools = try ruleTools()
        try "older text\n".write(toFile: tools.rulePath(forUID: 501), atomically: true, encoding: .utf8)
        XCTAssertEqual(tools.installRestoreRule(user: "liviu", uid: 501).status, 0)
        try FileManager.default.removeItem(at: log)
        let again = tools.installRestoreRule(user: "liviu", uid: 501)
        XCTAssertEqual(again.status, 0)
        XCTAssertTrue(again.message.contains("already"), again.message)
        XCTAssertEqual(try logged(), [], "no tool ran")
    }

    func testARuleVisudoRefusesIsNeverInstalled() throws {
        let tools = try ruleTools(visudoExit: 1)
        let r = tools.installRestoreRule(user: "liviu", uid: 501)
        XCTAssertEqual(r.status, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tools.rulePath(forUID: 501)))
        XCTAssertEqual(try logged().filter { $0.hasPrefix("install") }, [])
    }

    func testAnInvalidUserNameRunsNothing() throws {
        let tools = try ruleTools()
        XCTAssertEqual(tools.installRestoreRule(user: "a b", uid: 501).status, HelperStatus.notRun)
        XCTAssertEqual(try logged(), [])
    }

    /// Two accounts each keep their own lines.
    func testASecondUserDoesNotReplaceTheFirstUsersRule() throws {
        let tools = try ruleTools()
        XCTAssertEqual(tools.installRestoreRule(user: "alice", uid: 501).status, 0)
        XCTAssertEqual(tools.installRestoreRule(user: "bob", uid: 502).status, 0)
        XCTAssertEqual(try String(contentsOfFile: tools.rulePath(forUID: 501), encoding: .utf8), RestoreRule.text(user: "alice"))
        XCTAssertEqual(try String(contentsOfFile: tools.rulePath(forUID: 502), encoding: .utf8), RestoreRule.text(user: "bob"))
    }

    /// install.sh's file, with its passwordless disablesleep 1 line, goes
    /// once the user's own rule is in place, but only when it is theirs.
    func testInstallShsRuleIsRemovedOnlyWhenItIsTheCallersOnly() throws {
        let tools = try ruleTools()
        let legacy = "# Installed by Ember install.sh.\nliviu ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1\nliviu ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0\n"
        try legacy.write(toFile: tools.legacyPath, atomically: true, encoding: .utf8)
        let r = tools.installRestoreRule(user: "liviu", uid: 501)
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.message.contains("removed"), r.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tools.legacyPath))

        try (legacy + "other ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0\n").write(toFile: tools.legacyPath, atomically: true, encoding: .utf8)
        let kept = tools.installRestoreRule(user: "liviu", uid: 501)
        XCTAssertEqual(kept.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tools.legacyPath), "another account's lines stay")
    }

    func testAFailedWriteLeavesInstallShsRuleInPlace() throws {
        let tools = try ruleTools(visudoExit: 1)
        try "liviu ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0\n".write(toFile: tools.legacyPath, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(tools.installRestoreRule(user: "liviu", uid: 501).status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tools.legacyPath), "the only restore lines there are")
    }

    // MARK: Listener

    func testTheHelperExitsOnlyAfterBeingIdleForItsDelay() async throws {
        let exited = ExitFlag()
        let delegate = HelperListenerDelegate(version: "1", idleExit: 0.2, exitProcess: { exited.set() }, log: { _ in })
        delegate.scheduleIdleExit()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(exited.value)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(exited.value)
    }
}

private final class ExitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
