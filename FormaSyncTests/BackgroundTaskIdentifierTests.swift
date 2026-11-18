import XCTest
@testable import FormaSync

final class BackgroundTaskIdentifierTests: XCTestCase {
    func testRefreshIdentifierFollowsAppBundleAndMatchesPermittedIdentifier() throws {
        let bundleID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertEqual(AppDelegate.refreshTaskID, bundleID + ".refresh")
        let permitted = try XCTUnwrap(Bundle.main.object(
            forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
        ) as? [String])
        XCTAssertEqual(permitted, [AppDelegate.refreshTaskID])
    }
}
