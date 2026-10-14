import XCTest
@testable import Insomnia

final class DurationParserTests: XCTestCase {
    func testParserUnits() {
        XCTAssertEqual(DurationParser.seconds(from: "30m"), 1_800)
        XCTAssertEqual(DurationParser.seconds(from: "2h"), 7_200)
        XCTAssertEqual(DurationParser.seconds(from: "3d"), 3 * 86_400)
        XCTAssertEqual(DurationParser.seconds(from: "1h30m"), 5_400)
        XCTAssertEqual(DurationParser.seconds(from: " 1d 2h 3m "), 86_400 + 7_200 + 180)
        XCTAssertEqual(DurationParser.seconds(from: "45"), 45 * 60, "bare numbers are minutes")
        XCTAssertEqual(DurationParser.seconds(from: "2H"), 7_200)
    }

    func testParserRejectsGarbage() {
        XCTAssertNil(DurationParser.seconds(from: ""))
        XCTAssertNil(DurationParser.seconds(from: "abc"))
        XCTAssertNil(DurationParser.seconds(from: "0m"))
        XCTAssertNil(DurationParser.seconds(from: "0"))
        XCTAssertNil(DurationParser.seconds(from: "2x"))
        XCTAssertNil(DurationParser.seconds(from: "h"))
        XCTAssertNil(DurationParser.seconds(from: "2h5"))
    }

    func testParserRejectsOverflowInsteadOfTrapping() {
        let huge = String(Int.max)
        XCTAssertNil(DurationParser.seconds(from: huge))          // bare minutes × 60
        XCTAssertNil(DurationParser.seconds(from: huge + "d"))    // unit multiply
        XCTAssertNil(DurationParser.seconds(from: "9223372036854775d 1d")) // addition
        XCTAssertNil(DurationParser.seconds(from: "99999999999999999999h")) // Int(...) fails
        XCTAssertEqual(DurationParser.seconds(from: "1d 2h"), 93_600)
    }
}
