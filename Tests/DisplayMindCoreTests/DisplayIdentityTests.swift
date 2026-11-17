import XCTest
@testable import DisplayMindCore

final class DisplayIdentityTests: XCTestCase {
    private let old = "00000000-0000-0000-0000-000000000011"
    private let new = "00000000-0000-0000-0000-000000000012"
    private let other = "00000000-0000-0000-0000-000000000013"
    private let later = "00000000-0000-0000-0000-000000000014"
    private let wacom = DisplayIdentity(vendor: 100, model: 200, serial: 300)
    private func display(_ id: String, identity: DisplayIdentity? = nil, name: String = "Pen display") -> DisplaySetting {
        DisplaySetting(id: id, name: name, mode: DisplayMode(width: 1920, height: 1080, hertz: 60), identity: identity)
    }
    private func connected(_ display: DisplaySetting) -> ConnectedDisplay {
        ConnectedDisplay(setting: display, modes: [display.mode])
    }
    private func settings(_ displays: [DisplaySetting]) -> AppSettings {
        var settings = AppSettings()
        settings.presets = [Preset(name: "Desk", displays: displays, confirmed: true)]
        return settings
    }

    func testOldJSONStillDecodesAndExactUUIDLearnsIdentityWithoutChangingLayout() throws {
        let original = settings([display(old)])
        let encoded = try JSONEncoder().encode(original)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("\"identity\""))
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertNil(decoded.presets[0].displays[0].identity)
        let updated = DisplayReconciliation.reconcile(settings: decoded, connected: [connected(display(old, identity: wacom))])
        XCTAssertEqual(updated.presets[0].displays[0].identity, wacom)
        XCTAssertTrue(Configuration.sameLayout(original.presets[0].displays, updated.presets[0].displays))
        XCTAssertTrue(updated.presets[0].confirmed)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(updated)), updated)
    }

    func testChangedUUIDRebindsByFullHardwareTupleAndKeepsPresetDetails() {
        var saved = settings([display(old, identity: wacom)])
        let folder = PresetFolder(name: "Desk")
        saved.presetFolders = [folder]; saved.presets[0].folderID = folder.id
        saved.presets[0].audio = AudioSelection(output: AudioDevice(uid: "speakers", name: "Speakers"))
        let updated = DisplayReconciliation.reconcile(settings: saved, connected: [connected(display(new, identity: wacom, name: "Changed label"))])
        var wanted = saved; wanted.presets[0].displays[0].id = new
        XCTAssertEqual(updated, wanted)
        XCTAssertNil(Configuration.availability(updated.presets[0], connected: [new]))
    }

    func testSameModelMonitorsAreDistinguishedBySerial() {
        let left = DisplayIdentity(vendor: 10, model: 20, serial: 1)
        let right = DisplayIdentity(vendor: 10, model: 20, serial: 2)
        var second = display(other, identity: right, name: "LG"); second.x = 1920
        let saved = settings([display(old, identity: left, name: "LG"), second])
        let live = [connected(display(new, identity: left, name: "LG")), connected(display(later, identity: right, name: "LG"))]
        XCTAssertEqual(DisplayReconciliation.mapping(settings: saved, connected: live), [old: new, other: later])
    }

    func testMatchingOnlySerialOrOnlyNameCannotRebind() {
        let saved = settings([display(old, identity: wacom)])
        for wrong in [DisplayIdentity(vendor: 101, model: 200, serial: 300), DisplayIdentity(vendor: 100, model: 201, serial: 300)] {
            XCTAssertTrue(DisplayReconciliation.mapping(settings: saved, connected: [connected(display(new, identity: wrong))]).isEmpty)
        }
        let legacy = settings([display(old)])
        XCTAssertEqual(DisplayReconciliation.reconcile(settings: legacy, connected: [connected(display(new, identity: wacom))]), legacy, "a name alone is not hardware identity")
    }

    func testDuplicateConnectedIdentityAndDuplicateUUIDAreRefused() {
        let saved = settings([display(old, identity: wacom)])
        XCTAssertTrue(DisplayReconciliation.mapping(settings: saved, connected: [connected(display(new, identity: wacom)), connected(display(other, identity: wacom))]).isEmpty)
        XCTAssertTrue(DisplayReconciliation.mapping(settings: saved, connected: [connected(display(new, identity: wacom)), connected(display(new, identity: wacom))]).isEmpty)
    }

    func testDuplicateSavedHardwareIdentityAndCooccurringTargetCannotCollapse() {
        var second = display(other, identity: wacom); second.x = 1920
        let duplicated = settings([display(old, identity: wacom), second])
        XCTAssertTrue(DisplayReconciliation.mapping(settings: duplicated, connected: [connected(display(new, identity: wacom))]).isEmpty)
        var occupiedTarget = display(new); occupiedTarget.x = 1920
        let occupied = settings([display(old, identity: wacom), occupiedTarget])
        XCTAssertTrue(DisplayReconciliation.mapping(settings: occupied, connected: [connected(display(new, identity: wacom))]).isEmpty)
    }

    func testRuleReferencesCannotCollapseTwoRequiredOrOpposingConditions() {
        var saved = settings([display(old, identity: wacom)])
        let a = Device(id: "display:" + old, name: "Old", kind: .display)
        let b = Device(id: "display:" + new, name: "New", kind: .display)
        for requiredTogether in [true, false] {
            saved.rules = [ConnectionRule(name: "Desk", presetID: saved.presets[0].id, requiredDevices: requiredTogether ? [a, b] : [a], absentDevices: requiredTogether ? [] : [b])]
            XCTAssertTrue(DisplayReconciliation.mapping(settings: saved, connected: [connected(display(new, identity: wacom))]).isEmpty)
        }
    }

    func testZeroHardwareIdentifiersAndConflictingStoredIdentitiesAreRefused() {
        for identity in [DisplayIdentity(vendor: 0, model: 200, serial: 300), DisplayIdentity(vendor: 100, model: 0, serial: 300), DisplayIdentity(vendor: 100, model: 200, serial: 0)] {
            XCTAssertFalse(identity.isUsable)
            XCTAssertTrue(DisplayReconciliation.mapping(settings: settings([display(old, identity: identity)]), connected: [connected(display(new, identity: identity))]).isEmpty)
        }
        var saved = settings([display(old, identity: wacom)])
        saved.presets.append(Preset(name: "Other", displays: [display(old, identity: DisplayIdentity(vendor: 1, model: 2, serial: 3))]))
        XCTAssertTrue(DisplayReconciliation.mapping(settings: saved, connected: [connected(display(new, identity: wacom))]).isEmpty)
    }

    func testExactUUIDWinsAndMismatchedIdentityIsNeverOverwritten() {
        let wrong = DisplayIdentity(vendor: 1, model: 2, serial: 3)
        var saved = settings([display(old, identity: wacom)])
        saved.presets.append(Preset(name: "Legacy", displays: [display(old)]))
        let live = [connected(display(old, identity: wrong)), connected(display(new, identity: wacom))]
        XCTAssertTrue(DisplayReconciliation.mapping(settings: saved, connected: live).isEmpty)
        XCTAssertEqual(DisplayReconciliation.reconcile(settings: saved, connected: live), saved)
    }

    func testAirPlaySavedAndLiveExclusionsAreNotReboundOrEnriched() {
        var saved = settings([display(old, identity: wacom)])
        saved.presets[0].airPlay = AirPlayDestination(receiverName: "Receiver", displayID: old)
        XCTAssertEqual(DisplayReconciliation.reconcile(settings: saved, connected: [connected(display(new, identity: wacom))]), saved)
        let physical = settings([display(old, identity: wacom)])
        XCTAssertEqual(DisplayReconciliation.reconcile(settings: physical, connected: [connected(display(new, identity: wacom))], excluded: [new]), physical)
        let legacy = settings([display(old)])
        XCTAssertEqual(DisplayReconciliation.reconcile(settings: legacy, connected: [connected(display(old, identity: wacom))], excluded: [old]), legacy)
    }

    func testMirrorParentsAndRequiredAndAbsentRulesFollowTheReboundDisplay() {
        var mirror = display(other); mirror.mirrorOf = old
        var saved = settings([display(old, identity: wacom), mirror])
        saved.rules = [
            ConnectionRule(name: "Present", presetID: saved.presets[0].id,
                requiredDevices: [Device(id: "display:" + old, name: "Display", kind: .display), Device(id: "usb:unchanged", name: "Dock", kind: .usb)]),
            ConnectionRule(name: "Absent", presetID: saved.presets[0].id, requiredDevices: [],
                absentDevices: [Device(id: "display:" + old, name: "Display", kind: .display)])
        ]
        var liveMirror = mirror; liveMirror.mirrorOf = new
        let updated = DisplayReconciliation.reconcile(settings: saved, connected: [connected(display(new, identity: wacom)), connected(liveMirror)])
        XCTAssertEqual(updated.presets[0].displays.map(\.id), [new, other])
        XCTAssertEqual(updated.presets[0].displays[1].mirrorOf, new)
        XCTAssertEqual(updated.rules[0].requiredDevices.map(\.id), ["display:" + new, "usb:unchanged"])
        XCTAssertEqual(updated.rules[1].absentDevices.map(\.id), ["display:" + new])
        XCTAssertTrue(updated.presets[0].confirmed)
        XCTAssertNoThrow(try Configuration.validate(updated.presets[0]))
    }

    func testAliasChainsForStaleDraftsAndCycles() {
        var mirror = display(other); mirror.mirrorOf = old
        let draft = Preset(name: "Draft", displays: [display(old), mirror], confirmed: true)
        let rebound = DisplayReconciliation.remap(preset: draft, using: [old: new, new: later])
        XCTAssertEqual(rebound.displays[0].id, later)
        XCTAssertEqual(rebound.displays[1].mirrorOf, later)
        XCTAssertEqual(DisplayReconciliation.resolvedID(old, using: [old: new, new: old]), old)
    }
}
