import XCTest
@testable import DisplayMindCore
@testable import DisplayMind

final class RulesAndStorageTests: XCTestCase {
    let dock = Device(id: "usb:1:2:serial:fixture", name: "Desk dock", kind: .usb)
    var screens: [Device] { layout().map { Device(id: "display:\($0.id)", name: $0.name, kind: .display) } }
    func state() -> AppSettings {
        var settings = AppSettings()
        let preset = Preset(name: "Desk", displays: layout(), confirmed: true)
        settings.presets = [preset]
        settings.rules = [ConnectionRule(name: "Docked", presetID: preset.id, requiredDevices: [dock])]
        return settings
    }
    func testDockRuleNeedsAllDisplaysAndConfirmedPreset() {
        var settings = state()
        XCTAssertNotNil(RuleEngine.match(settings: settings, devices: screens + [dock]))
        XCTAssertNil(RuleEngine.match(settings: settings, devices: screens))
        XCTAssertNil(RuleEngine.match(settings: settings, devices: [screens[0], dock]))
        settings.presets[0].confirmed = false
        XCTAssertNil(RuleEngine.match(settings: settings, devices: screens + [dock]))
    }
    func testAbsentDeviceRuleAndExactDisplaySet() {
        var settings = state()
        settings.rules[0].requiredDevices = [screens[0]]
        settings.rules[0].absentDevices = [dock]
        XCTAssertNotNil(RuleEngine.match(settings: settings, devices: screens))
        XCTAssertNil(RuleEngine.match(settings: settings, devices: screens + [dock]))
        let extra = Device(id: "display:\(displayC)", name: "Extra", kind: .display)
        XCTAssertNil(RuleEngine.match(settings: settings, devices: screens + [extra]))
        settings.rules[0].exactDisplays = false
        XCTAssertNotNil(RuleEngine.match(settings: settings, devices: screens + [extra]))
    }
    func testPriorityPauseDisabledAndEmptyRules() {
        var settings = state()
        let second = ConnectionRule(name: "Second", presetID: settings.presets[0].id, requiredDevices: [dock])
        settings.rules.append(second)
        XCTAssertEqual(RuleEngine.match(settings: settings, devices: screens + [dock])?.id, settings.rules[0].id)
        settings.rules[0].enabled = false
        XCTAssertEqual(RuleEngine.match(settings: settings, devices: screens + [dock])?.id, second.id)
        settings.automationEnabled = false
        XCTAssertNil(RuleEngine.match(settings: settings, devices: screens + [dock]))
        settings.automationEnabled = true; settings.rules[1].requiredDevices = []
        XCTAssertNil(RuleEngine.match(settings: settings, devices: screens + [dock]))
    }
    func testConnectionsSettleAndDoNotReapplyAfterManualSwitching() {
        var gate = ConnectionGate(); let start = Date()
        XCTAssertFalse(gate.shouldEvaluate(screens, now: start))
        XCTAssertFalse(gate.shouldEvaluate(screens + [dock], now: start.addingTimeInterval(2)))
        XCTAssertFalse(gate.shouldEvaluate(screens + [dock], now: start.addingTimeInterval(4)))
        XCTAssertTrue(gate.shouldEvaluate(screens + [dock], now: start.addingTimeInterval(5)))
        XCTAssertFalse(gate.shouldEvaluate(screens + [dock], now: start.addingTimeInterval(100)))
        XCTAssertFalse(gate.shouldEvaluate(screens, now: start.addingTimeInterval(101)))
        XCTAssertTrue(gate.shouldEvaluate(screens, now: start.addingTimeInterval(104)))
        gate.reset()
        XCTAssertFalse(gate.shouldEvaluate(screens, now: start.addingTimeInterval(105)))
        XCTAssertTrue(gate.shouldEvaluate(screens, now: start.addingTimeInterval(108)))
    }
    func testAtomicPersistenceAndCorruptionPreserved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = SettingsFile(directory: dir)
        XCTAssertEqual(try file.load(), AppSettings())
        let expected = state(); try file.save(expected); XCTAssertEqual(try file.load(), expected)
        let broken = Data("broken json".utf8); try broken.write(to: file.url)
        XCTAssertThrowsError(try file.load())
        XCTAssertEqual(try Data(contentsOf: file.url), broken)
    }
    func testNewerSettingsAreNotSilentlyReset() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = SettingsFile(directory: dir); var settings = state(); settings.schemaVersion = 2
        try file.save(settings)
        XCTAssertThrowsError(try file.load())
    }
    @MainActor func testEditingCapturedPresetRequiresConfirmationAndDeletionRemovesRules() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir, demo: true)
        var copy = store.settings.presets[0]; copy.displays[1].rotation = 270
        store.save(copy)
        XCTAssertFalse(store.settings.presets[0].confirmed)
        XCTAssertEqual(store.settings.rules.count, 1)
        store.delete(copy)
        XCTAssertTrue(store.settings.rules.isEmpty)
    }
}
