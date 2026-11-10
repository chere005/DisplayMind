import XCTest
@testable import DisplayMindCore
@testable import DisplayMind

final class AirPlayTests: XCTestCase {
    let target = AirPlayDestination(receiverName: "Living Room TV", displayID: displayB)
    func preset() -> Preset { Preset(name: "TV", displays: layout(), confirmed: true, airPlay: target) }

    func testLegacyPresetDecodesWithoutAirPlayAndNewSettingsRoundTrip() throws {
        let old = Preset(name: "Desk", displays: layout(), confirmed: true)
        let encoded = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("airPlay"))
        XCTAssertNil(try JSONDecoder().decode(Preset.self, from: encoded).airPlay)
        let updated = preset()
        XCTAssertEqual(try JSONDecoder().decode(Preset.self, from: JSONEncoder().encode(updated)), updated)
    }
    func testOfflineAirPlayDoesNotDisableApplyButWiredDisplayStillRequired() {
        XCTAssertNil(Configuration.availability(preset(), connected: [displayA]))
        XCTAssertNotNil(Configuration.availability(preset(), connected: [displayA], allowAirPlayConnection: false))
        XCTAssertNotNil(Configuration.availability(preset(), connected: [displayB]))
    }
    func testInvalidAirPlayConfigurationRejected() {
        var p = preset(); p.airPlay?.displayID = displayC
        XCTAssertThrowsError(try Configuration.validate(p))
        p = preset(); p.airPlay?.receiverName = "  \n"
        XCTAssertThrowsError(try Configuration.validate(p))
        p = preset(); p.displays[1].enabled = false
        XCTAssertThrowsError(try Configuration.validate(p))
    }
    func testDockRuleCanStartAirPlayAndExactMatchingStillRejectsExtraDisplays() {
        var settings = AppSettings(); let p = preset(); settings.presets = [p]
        let dock = Device(id: "usb:dock", name: "Dock", kind: .usb)
        let builtIn = Device(id: "display:\(displayA)", name: "Laptop", kind: .display)
        let wireless = Device(id: "display:\(displayB)", name: "TV", kind: .display)
        settings.rules = [ConnectionRule(name: "Dock to TV", presetID: p.id, requiredDevices: [dock])]
        XCTAssertNotNil(RuleEngine.match(settings: settings, devices: [builtIn, dock]))
        XCTAssertNotNil(RuleEngine.match(settings: settings, devices: [builtIn, dock, wireless]))
        XCTAssertNil(RuleEngine.match(settings: settings, devices: [dock, wireless]))
        XCTAssertNil(RuleEngine.match(settings: settings, devices: [builtIn, dock, Device(id: "display:\(displayC)", name: "Extra", kind: .display)]))
        settings.rules[0].requiredDevices.append(wireless)
        XCTAssertNil(RuleEngine.match(settings: settings, devices: [builtIn, dock]))
    }
    func testSelectionRequiresExactNameOrObservedIdentifierAndRejectsAmbiguity() throws {
        let a = AirPlayReceiver(id: "screen-mirroring-device-AirPlay-A", name: "Living Room TV", selected: false)
        let b = AirPlayReceiver(id: "screen-mirroring-device-AirPlay-B", name: "Living Room TV upstairs", selected: false)
        XCTAssertEqual(try AirPlaySelection.receiver(for: target, in: [b,a]), a)
        XCTAssertNil(try AirPlaySelection.receiver(for: target, in: [b]))
        let duplicate = AirPlayReceiver(id: "screen-mirroring-device-AirPlay-C", name: a.name, selected: false)
        XCTAssertThrowsError(try AirPlaySelection.receiver(for: target, in: [a,duplicate]))
        var exact = target; exact.controlIdentifier = duplicate.id
        XCTAssertEqual(try AirPlaySelection.receiver(for: exact, in: [a,duplicate]), duplicate)
    }
    func testAlreadyConnectedReceiverNeverTogglesOffAndUnknownStateFailsClosed() throws {
        var receiver = AirPlayReceiver(id: "device", name: "TV", selected: true)
        XCTAssertFalse(try AirPlaySelection.shouldPress(receiver, connecting: true))
        XCTAssertTrue(try AirPlaySelection.shouldPress(receiver, connecting: false))
        receiver.selected = false
        XCTAssertTrue(try AirPlaySelection.shouldPress(receiver, connecting: true))
        XCTAssertFalse(try AirPlaySelection.shouldPress(receiver, connecting: false))
        receiver.selected = nil
        XCTAssertThrowsError(try AirPlaySelection.shouldPress(receiver, connecting: true))
        XCTAssertThrowsError(try AirPlaySelection.shouldPress(receiver, connecting: false))
    }
    func testConnectWaitsForTheSavedDisplayBeforeContinuing() throws {
        var now = Date(); var ids: Set<String> = [displayA]; var calls = 0; var waits = 0
        try AirPlayConnection.ensure(target, online: { ids }, start: { calls += 1 }, now: { now }, wait: { duration in
            now.addTimeInterval(duration); waits += 1
            if waits == 2 { ids.insert(displayB) }
        }, timeout: 2)
        XCTAssertEqual(calls, 1); XCTAssertEqual(waits, 2)
        try AirPlayConnection.ensure(target, online: { ids }, start: { XCTFail("Must reuse the existing connection") })
    }
    func testConnectionTimeoutDoesNotAcceptAnUnrelatedDisplay() {
        var now = Date(); var calls = 0
        XCTAssertThrowsError(try AirPlayConnection.ensure(target, online: { [displayA, displayC] }, start: { calls += 1 }, now: { now }, wait: { now.addTimeInterval($0) }, timeout: 0.5))
        XCTAssertEqual(calls, 1)
        XCTAssertThrowsError(try AirPlayConnection.ensure(target, online: { [displayA] }, start: { throw DisplayMindError("Denied") }, wait: { _ in XCTFail("Must not wait after a connection error") }))
    }
    func testInternalAirPlayConnectionDoesNotRetriggerRules() {
        var gate = ConnectionGate(); let now = Date()
        let local = Device(id: "display:\(displayA)", name: "Local", kind: .display)
        let remote = Device(id: "display:\(displayB)", name: "TV", kind: .display)
        gate.consume([local, remote], now: now)
        XCTAssertFalse(gate.shouldEvaluate([local,remote], now: now.addingTimeInterval(10)))
        XCTAssertFalse(gate.shouldEvaluate([local], now: now.addingTimeInterval(11)))
        XCTAssertTrue(gate.shouldEvaluate([local], now: now.addingTimeInterval(14)))
    }
    @MainActor func testAddingAirPlayRequiresConfirmationAndDefaultRuleExcludesWirelessDisplay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir, demo: true)
        var edited = store.settings.presets[0]; edited.airPlay = target
        store.save(edited)
        XCTAssertFalse(store.settings.presets[0].confirmed)
        XCTAssertFalse(store.defaultRuleDevices(for: edited).contains { $0.id == "display:\(displayB)" })
    }
}
