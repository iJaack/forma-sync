import XCTest

@MainActor
final class FormaV2ReviewScreenshotTests: XCTestCase {
    func testMainLight() { capture(style: "Light") }
    func testMainDark() { capture(style: "Dark") }

    private func capture(style: String) {
        XCUIDevice.shared.appearance = (style == "Dark") ? .dark : .light
        let app = XCUIApplication()
        app.launchArguments = ["-AppleInterfaceStyle", style]
        app.launch()
        XCTAssertTrue(app.staticTexts["Forma Sync"].waitForExistence(timeout: 15), "Main status title should appear")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "formasync-main-\(style.lowercased())"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
