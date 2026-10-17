import Foundation
import XCTest

/// scripts/release.sh in a private copy whose every tool is a fake that
/// records its call (spec 2026-10-17 "Releasing"): nothing is signed,
/// notarized or published.
final class ReleaseScriptTests: XCTestCase {
    private var root: URL!
    private var checkout: URL { root.appendingPathComponent("checkout", isDirectory: true) }
    private var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
    private var calls: URL { root.appendingPathComponent("calls.log") }
    private var script: URL { checkout.appendingPathComponent("scripts/release.sh") }

    private static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("release-\(UUID().uuidString)", isDirectory: true)
        for dir in [checkout.appendingPathComponent("scripts"), checkout.appendingPathComponent("Resources"), bin] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try writeInfo(short: "0.2.0", build: "2000")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeInfo(short: String, build: String) throws {
        let info: [String: Any] = ["CFBundleShortVersionString": short, "CFBundleVersion": build]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: checkout.appendingPathComponent("Resources/Info.plist"))
    }

    private func fake(_ name: String, _ body: String) throws -> String {
        let url = bin.appendingPathComponent(name)
        try TestScripts.write("#!/bin/bash\nprintf '\(name) %s\\n' \"$*\" >> \"\(calls.path)\"\n" + body, to: url)
        return url.path
    }

    /// Writes the patched copy. `branch` is what the fake git reports;
    /// `notary` the status notarytool answers.
    private func writeScript(branch: String = "main", notary: String = "Accepted") throws {
        let tools: [String: String] = [
            "ROOT": checkout.path,
            "BUILD_APP": try fake("build-app", """
            out="$2"
            /bin/mkdir -p "$out/Ember.app/Contents/MacOS"
            echo app > "$out/Ember.app/Contents/MacOS/Ember"
            echo helper > "$out/Ember.app/Contents/MacOS/EmberHelper"
            """),
            "SIGN_UPDATE": try fake("sign_update", #"echo 'sparkle:edSignature="SIGNATURE==" length="4242"'"#),
            // Like the real one, -dv prints more after the flags line: a
            // check that stops reading at the match must not fail the run
            // (it did under pipefail, in the first real dry run).
            "CODESIGN": try fake("codesign", #"[[ "$1" == -dv ]] && { echo 'CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1'; for i in $(seq 1 5000); do echo "Info line $i"; done; } >&2; exit 0"#),
            "XCRUN": try fake("xcrun", """
            if [[ "$1 $2" == "notarytool submit" ]]; then echo '{"id":"sub-1","status":"\(notary)"}'; fi
            exit 0
            """),
            "HDIUTIL": try fake("hdiutil", #"echo dmg > "${@: -1}""#),
            "SPCTL": try fake("spctl", "exit 0"),
            "SECURITY": try fake("security", #"echo '  1) ABC "Developer ID Application: CHARGING PIXELS S.R.L. (4UA742BB8G)"'"#),
            "GIT": try fake("git", """
            case "$*" in
              "status --porcelain") ;;
              "rev-parse --abbrev-ref HEAD") echo \(branch) ;;
              "rev-parse HEAD") echo 0123456789abcdef0123456789abcdef01234567 ;;
              rev-parse\\ -q\\ --verify*) exit 1 ;;
            esac
            """),
            "GH": try fake("gh", "exit 0"),
        ]
        var lines = try String(contentsOf: Self.repoRoot.appendingPathComponent("scripts/release.sh"), encoding: .utf8).components(separatedBy: "\n")
        for (name, value) in tools {
            let hits = lines.indices.filter { lines[$0].hasPrefix("\(name)=") }
            XCTAssertEqual(hits.count, 1, "release.sh must have exactly one \(name)= line")
            lines[hits[0]] = "\(name)='\(value)'"
        }
        try TestScripts.write(lines.joined(separator: "\n"), to: script)
    }

    private func run(_ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + args
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func recorded() throws -> [String] {
        guard FileManager.default.fileExists(atPath: calls.path) else { return [] }
        return try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private var out: URL { checkout.appendingPathComponent("dist/0.2.0", isDirectory: true) }

    func testADryRunBuildsNotarizesAndWritesTheAppcastWithoutPublishing() throws {
        try writeScript(branch: "feature")
        let r = try run(["0.2.0", "--dry-run"])
        XCTAssertEqual(r.status, 0, r.output)
        let calls = try recorded()
        let identity = "Developer ID Application: CHARGING PIXELS S.R.L. (4UA742BB8G)"
        XCTAssertTrue(calls.contains("build-app --output \(out.path) --sign \(identity)"), "\(calls)")
        XCTAssertEqual(calls.filter { $0.hasPrefix("xcrun notarytool submit") }.count, 2, "the app, then the DMG")
        XCTAssertTrue(calls.contains("xcrun stapler staple \(out.path)/Ember.app"), "\(calls)")
        let dmg = out.appendingPathComponent("Ember-0.2.0.dmg").path
        XCTAssertTrue(calls.contains("codesign --force --sign \(identity) --timestamp \(dmg)"), "\(calls)")
        XCTAssertTrue(calls.contains("xcrun stapler staple \(dmg)"), "\(calls)")
        XCTAssertTrue(calls.contains("sign_update --account ember \(dmg)"), "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("gh ") }, "a dry run publishes nothing")

        let appcast = try XMLDocument(contentsOf: out.appendingPathComponent("appcast.xml"))
        func value(_ path: String) throws -> String? { try appcast.nodes(forXPath: path).first?.stringValue }
        XCTAssertEqual(try value("/rss/channel/item/sparkle:version"), "2000")
        XCTAssertEqual(try value("/rss/channel/item/sparkle:shortVersionString"), "0.2.0")
        XCTAssertEqual(try value("/rss/channel/item/sparkle:minimumSystemVersion"), "26.0")
        XCTAssertEqual(try value("/rss/channel/item/enclosure/@url"), "https://github.com/liviulica/ember/releases/download/v0.2.0/Ember-0.2.0.dmg")
        XCTAssertEqual(try value("/rss/channel/item/enclosure/@sparkle:edSignature"), "SIGNATURE==")
        XCTAssertEqual(try value("/rss/channel/item/enclosure/@length"), "4242")
        XCTAssertEqual(try appcast.nodes(forXPath: "/rss/channel/item").count, 1)
    }

    func testPublishingCreatesTheReleaseWithTheDmgAndTheAppcast() throws {
        try writeScript()
        let r = try run(["0.2.0", "--yes"])
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(try recorded().filter { $0.hasPrefix("gh release") }, [
            "gh release create v0.2.0 \(out.path)/Ember-0.2.0.dmg \(out.path)/Ember.dmg \(out.path)/appcast.xml --repo liviulica/ember --target 0123456789abcdef0123456789abcdef01234567 --title Ember 0.2.0 --generate-notes",
        ])
    }

    /// Without --yes it asks; no answer (standard input is empty) publishes nothing.
    func testPublishingAsksFirst() throws {
        try writeScript()
        let r = try run(["0.2.0"])
        XCTAssertEqual(r.status, 1, r.output)
        XCTAssertTrue(r.output.contains("not published"), r.output)
        XCTAssertFalse(try recorded().contains { $0.hasPrefix("gh release") })
    }

    func testAVersionInfoPlistDoesNotSayIsRefusedBeforeAnythingRuns() throws {
        try writeScript()
        for (version, short, build) in [("0.2.1", "0.2.0", "2000"), ("0.2.0", "0.2.0", "2"), ("1.2", "0.2.0", "2000")] {
            try? FileManager.default.removeItem(at: calls)
            try writeInfo(short: short, build: build)
            let r = try run([version, "--dry-run"])
            XCTAssertEqual(r.status, 1, "\(version) vs \(short) (\(build)): \(r.output)")
            XCTAssertFalse(try recorded().contains { $0.hasPrefix("build-app") }, "\(version): nothing built")
        }
    }

    func testAReleaseIsMadeFromMainOnly() throws {
        try writeScript(branch: "feature")
        let r = try run(["0.2.0", "--yes"])
        XCTAssertEqual(r.status, 1, r.output)
        XCTAssertTrue(r.output.contains("from main"), r.output)
        XCTAssertFalse(try recorded().contains { $0.hasPrefix("build-app") })
    }

    /// notarytool can give up on a slow upload; the next attempt goes on.
    func testAFailedUploadIsTriedAgain() throws {
        try writeScript()
        let xcrun = bin.appendingPathComponent("xcrun")
        let count = root.appendingPathComponent("submits")
        try TestScripts.write("""
        #!/bin/bash
        printf 'xcrun %s\\n' "$*" >> "\(calls.path)"
        if [[ "$1 $2" == "notarytool submit" ]]; then
          n=$(( $(/bin/cat "\(count.path)" 2>/dev/null || echo 0) + 1 )); echo "$n" > "\(count.path)"
          (( n == 1 )) && { echo 'Error: HTTPClientError.deadlineExceeded' >&2; exit 1; }
          echo '{"id":"sub-2","status":"Accepted"}'
        fi
        exit 0
        """, to: xcrun)
        let r = try run(["0.2.0", "--dry-run"])
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertTrue(r.output.contains("attempt 1 of 3"), r.output)
        XCTAssertEqual(try recorded().filter { $0.hasPrefix("xcrun notarytool submit") }.count, 3, "app twice, then the DMG")
    }

    func testARejectedNotarizationStopsWithApplesLog() throws {
        try writeScript(notary: "Invalid")
        let r = try run(["0.2.0", "--dry-run"])
        XCTAssertEqual(r.status, 1, r.output)
        XCTAssertTrue(r.output.contains("Invalid (submission sub-1)"), r.output)
        let calls = try recorded()
        XCTAssertTrue(calls.contains { $0.hasPrefix("xcrun notarytool log sub-1") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("hdiutil") }, "no DMG after a rejected app")
    }
}
