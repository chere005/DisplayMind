import XCTest
@testable import DisplayMindCore
@testable import DisplayMind

final class EditorStateTests: XCTestCase {
    private let oldID = "00000000-0000-0000-0000-000000000011"
    private let newID = "00000000-0000-0000-0000-000000000012"

    func testUnsavedDeviceConditionsStayVisibleAfterDisconnect() {
        let usb = Device(id: "usb:unsaved", name: "Drawing tablet", kind: .usb)
        var draft = ConnectionRule(name: "Drawing", presetID: UUID(), requiredDevices: [usb])
        XCTAssertEqual(RuleEditorDevices.choices(draft: draft, known: [], aliases: [:]), [usb])
        RuleEditorDevices.setCondition(2, for: usb, in: &draft, aliases: [:])
        XCTAssertEqual(RuleEditorDevices.condition(usb, in: draft, aliases: [:]), 2)
        RuleEditorDevices.setCondition(0, for: usb, in: &draft, aliases: [:])
        XCTAssertTrue(RuleEditorDevices.choices(draft: draft, known: [], aliases: [:]).isEmpty)
    }

    func testReconnectedDraftConditionsCanBeChangedAndRemovedThroughTheCurrentDevice() {
        let old = Device(id: "display:\(oldID)", name: "Old monitor name", kind: .display)
        let current = Device(id: "display:\(newID)", name: "Drawing display", kind: .display)
        let aliases = [oldID: newID]
        var draft = ConnectionRule(name: "Drawing", presetID: UUID(), requiredDevices: [], absentDevices: [old])
        XCTAssertEqual(RuleEditorDevices.choices(draft: draft, known: [current], aliases: aliases), [current])
        XCTAssertEqual(RuleEditorDevices.condition(current, in: draft, aliases: aliases), 2)
        RuleEditorDevices.setCondition(1, for: current, in: &draft, aliases: aliases)
        XCTAssertEqual(draft.requiredDevices, [current])
        XCTAssertTrue(draft.absentDevices.isEmpty)
        RuleEditorDevices.setCondition(0, for: current, in: &draft, aliases: aliases)
        XCTAssertTrue(draft.requiredDevices.isEmpty)
        XCTAssertTrue(draft.absentDevices.isEmpty)
    }

    func testChangingAnAliasedConditionRemovesBothOldAndNewReferences() {
        let old = Device(id: "display:\(oldID)", name: "Monitor", kind: .display)
        let current = Device(id: "display:\(newID)", name: "Monitor", kind: .display)
        var draft = ConnectionRule(name: "Drawing", presetID: UUID(), requiredDevices: [old, current], absentDevices: [old])
        RuleEditorDevices.setCondition(2, for: current, in: &draft, aliases: [oldID: newID])
        XCTAssertTrue(draft.requiredDevices.isEmpty)
        XCTAssertEqual(draft.absentDevices, [current])
    }

    func testReconnectedPresetEditorKeepsCurrentModesAndBuiltInIdentity() {
        var draft = DisplaySetting(id: oldID, name: "Built-in display", mode: DisplayMode(width: 1080, height: 1920), rotation: 90)
        var actual = draft
        actual.id = newID; actual.rotation = 0; actual.mode = DisplayMode(width: 1920, height: 1080)
        let lower = DisplayMode(width: 1280, height: 720)
        let current = ConnectedDisplay(setting: actual, modes: [actual.mode, lower], builtIn: true)
        let connected = PresetEditorDisplays.connected(draft, among: [current], aliases: [oldID: newID])
        XCTAssertEqual(connected?.id, newID)
        XCTAssertEqual(connected?.builtIn, true)
        XCTAssertTrue(PresetEditorDisplays.modes(for: draft, connected: [current], aliases: [oldID: newID]).contains(DisplayMode(width: 720, height: 1280)))
        draft.id = "00000000-0000-0000-0000-000000000099"
        XCTAssertEqual(PresetEditorDisplays.modes(for: draft, connected: [current], aliases: [oldID: newID]), [draft.mode])
    }
}
