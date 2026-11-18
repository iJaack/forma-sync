import XCTest
@testable import FormaSync

final class SleepSourceTests: XCTestCase {
    func testDefaultPrefixesAllowAppleAndWHOOP() {
        for extra: String? in [nil, "", " , , \n\t "] {
            let prefixes = SleepAggregator.sourcePrefixes(extraSources: extra)
            XCTAssertEqual(prefixes, ["com.apple.", "com.whoop."])
            XCTAssertTrue(SleepAggregator.isAllowedSource("com.apple.health.watch", prefixes: prefixes))
            XCTAssertTrue(SleepAggregator.isAllowedSource("com.whoop.app", prefixes: prefixes))
            XCTAssertFalse(SleepAggregator.isAllowedSource("com.example.sleep", prefixes: prefixes))
        }
    }

    func testExtraPrefixesAreTrimmedAndEmptyEntriesIgnored() {
        let prefixes = SleepAggregator.sourcePrefixes(
            extraSources: " , com.example.sleep,\n org.example.tracker. \t, ,"
        )
        XCTAssertEqual(prefixes, ["com.apple.", "com.whoop.", "com.example.sleep", "org.example.tracker."])
        for source in ["com.example.sleep", "com.example.sleep.extension", "org.example.tracker.app"] {
            XCTAssertTrue(SleepAggregator.isAllowedSource(source, prefixes: prefixes), source)
        }
        XCTAssertFalse(SleepAggregator.isAllowedSource("org.example.other", prefixes: prefixes))
    }

    func testMatchingUsesCaseSensitivePrefixes() {
        let prefixes = SleepAggregator.sourcePrefixes(extraSources: nil)
        for source in ["", "com.apple", "com.appleish.sleep", "com.whoopish.app",
                       "org.example.com.apple.health", "COM.APPLE.health"] {
            XCTAssertFalse(SleepAggregator.isAllowedSource(source, prefixes: prefixes), source)
        }
    }

    func testEmptyPrefixNeverAllowsAllSources() {
        XCTAssertFalse(SleepAggregator.isAllowedSource("com.example.sleep", prefixes: [""]))
        XCTAssertFalse(SleepAggregator.isAllowedSource("com.apple.health", prefixes: []))
    }
}
