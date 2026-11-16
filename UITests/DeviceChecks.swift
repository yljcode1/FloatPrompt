import XCTest

final class DeviceChecks: XCTestCase {
    func testCameraOverlayCapture() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--validate-pip"]
        app.launch()
        let enabled = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "悬浮已开启")).firstMatch
        XCTAssertTrue(enabled.waitForExistence(timeout: 20))
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "before-camera"; before.lifetime = .keepAlways; add(before)
        let camera = XCUIApplication(bundleIdentifier: "com.apple.camera")
        camera.activate()
        XCTAssertTrue(camera.wait(for: .runningForeground, timeout: 15))
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "native-camera-overlay"; after.lifetime = .keepAlways; add(after)
    }

    func testDeviceInterfaceAndPiP() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["开启悬浮"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["编辑稿件"].exists)
        let initial = XCTAttachment(screenshot: app.screenshot()); initial.name = "01-提词器首页"; initial.lifetime = .keepAlways; add(initial)
        app.buttons["下一句"].tap()
        XCTAssertTrue(app.staticTexts["第 2 / 4 句"].waitForExistence(timeout: 3))
        app.buttons["上一句"].tap()
        app.buttons["开启悬浮"].tap()
        let enabled = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "悬浮已开启")).firstMatch
        XCTAssertTrue(enabled.waitForExistence(timeout: 12), "PiP did not start: \(app.debugDescription)")
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let screenshot = XCTAttachment(screenshot: springboard.screenshot()); screenshot.name = "02-切到桌面后的悬浮窗"; screenshot.lifetime = .keepAlways; add(screenshot)
        print("SPRINGBOARD_TREE_BEGIN\n\(springboard.debugDescription)\nSPRINGBOARD_TREE_END")
        app.activate()
    }
}
