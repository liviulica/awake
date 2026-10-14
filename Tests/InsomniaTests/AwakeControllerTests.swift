import XCTest
@testable import Insomnia

@MainActor
final class AwakeControllerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testToggleHoldsThenReleases() {
        let a = FakeAwakeAssertion()
        let c = AwakeController(assertion: a, clock: { [t0] in t0 })
        c.toggle()
        XCTAssertEqual(c.state, .on(until: nil))
        XCTAssertTrue(a.isHeld)
        c.toggle()
        XCTAssertEqual(c.state, .off)
        XCTAssertEqual(a.calls, ["hold", "release"])
    }

    func testTimedModeEndsWhenDue() {
        let a = FakeAwakeAssertion()
        let clock = FakeClock(t0)
        let c = AwakeController(assertion: a, clock: { clock.now })
        c.turnOn(for: 3600)
        XCTAssertEqual(c.endsAt, t0.addingTimeInterval(3600))
        clock.advance(3599)
        c.expireIfDue()
        XCTAssertTrue(c.isOn)
        clock.advance(1)
        c.expireIfDue()
        XCTAssertEqual(c.state, .off)
        XCTAssertFalse(a.isHeld)
    }

    func testHoldFailureStaysOffAndSaysWhy() {
        let a = FakeAwakeAssertion()
        a.failHold = true
        let c = AwakeController(assertion: a, clock: { [t0] in t0 })
        c.turnOn(for: nil)
        XCTAssertEqual(c.state, .off)
        XCTAssertNotNil(c.lastError)
    }

    func testLidSessionFoldsAwakeModeIn() {
        let a = FakeAwakeAssertion()
        let c = AwakeController(assertion: a, clock: { [t0] in t0 })
        var seen: [AwakeController.State] = []
        c.onChange = { seen.append($0) }
        c.turnOn(for: nil)
        c.lidSessionChanged(active: true, lidOpen: true)
        XCTAssertEqual(c.state, .off, "screen mode is part of lid mode now")
        XCTAssertTrue(c.lidHoldActive)
        XCTAssertTrue(a.isHeld, "the screen stays on while the lid is open")
        XCTAssertEqual(seen, [.on(until: nil), .off])
    }

    func testLidSessionHoldsOnlyWhileTheLidIsOpen() {
        let a = FakeAwakeAssertion()
        let c = AwakeController(assertion: a, clock: { [t0] in t0 })
        c.lidSessionChanged(active: true, lidOpen: true)
        XCTAssertTrue(a.isHeld)
        c.lidSessionChanged(active: true, lidOpen: false)
        XCTAssertFalse(a.isHeld, "released so LidActions can sleep the panel")
        c.lidSessionChanged(active: true, lidOpen: true)
        XCTAssertTrue(a.isHeld)
        c.lidSessionChanged(active: false, lidOpen: true)
        XCTAssertFalse(a.isHeld, "nothing held once the lid session ends")
        XCTAssertFalse(c.lidHoldActive)
        XCTAssertEqual(c.state, .off)
    }

    func testTurningOnAgainReplacesTheDeadline() {
        let a = FakeAwakeAssertion()
        let c = AwakeController(assertion: a, clock: { [t0] in t0 })
        c.turnOn(for: 3600)
        c.turnOn(for: nil)
        XCTAssertEqual(c.state, .on(until: nil))
        XCTAssertEqual(a.calls, ["hold", "hold"], "hold is idempotent in the live assertion")
    }

    func testAwakeModeCannotStartOrReleaseTheLidHold() {
        let a = FakeAwakeAssertion()
        let c = AwakeController(assertion: a, clock: { [t0] in t0 })
        c.lidSessionChanged(active: true, lidOpen: true)
        XCTAssertTrue(a.isHeld)
        c.toggle()
        XCTAssertEqual(c.state, .off, "screen mode is part of lid mode")
        XCTAssertTrue(a.isHeld, "the lid hold keeps the assertion")
        c.turnOff(reason: "test")
        XCTAssertTrue(a.isHeld, "turning off must not release the lid's hold")
        XCTAssertTrue(c.lidHoldActive)
    }

    func testLidClosedDuringASessionDoesNotTakeTheAssertionForAwakeMode() {
        let a = FakeAwakeAssertion()
        let c = AwakeController(assertion: a, clock: { [t0] in t0 })
        c.lidSessionChanged(active: true, lidOpen: false)
        c.turnOn(for: nil)
        XCTAssertEqual(c.state, .off)
        XCTAssertFalse(a.isHeld)
        XCTAssertEqual(a.calls, [], "no hold is attempted while a lid session is active")
    }
}
