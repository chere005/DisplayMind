import XCTest
@testable import DisplayMindCore
@testable import DisplayMind

private final class ReconnectCastState: @unchecked Sendable {
    let lock = NSLock()
    private var connected = false
    func setConnected() { lock.lock(); connected = true; lock.unlock() }
    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connected }
}

extension StoreTests {
    private var panelIdentity: DisplayIdentity { DisplayIdentity(vendor: 101, model: 202, serial: 303) }

    @MainActor private func identityStore(_ backend: DisplayBackend, current: [DisplaySetting]) -> Store {
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let devices = current.map { Device(id: "display:\($0.id)", name: $0.name, kind: .display) }
        let hardware = HardwareProvider(devices: { devices }, connectedDisplayIDs: { Set(current.map(\.id)) }, nameDisplays: { input in
            input.map { display in
                var copy = display
                if let known = byID[display.id] { copy.setting.identity = known.identity; copy.setting.name = known.name }
                return copy
            }
        })
        let airPlay = AirPlayActions(authorized: { false }, requireAccess: { XCTFail("No AirPlay operation expected") },
                                    requestAccess: {}, receivers: { [] }, setConnected: { _, _, _ in XCTFail("No AirPlay operation expected") })
        let sound = self.sound
        return Store(directory: data, backend: backend, hardware: hardware, airPlay: airPlay, audio: sound.actions,
                     notifier: .none, launchWatchdog: { directory in
                         Thread.detachNewThread { RecoveryController(directory: directory).watch(backend: backend, disconnectAirPlay: { _ in }, audio: sound.actions) }
                     }, background: false)
    }

    @MainActor func testRefreshSeedsIdentityWithoutChangingConfirmationOrRunningHelper() async throws {
        let preset = Preset(name: "Desk", displays: previous, confirmed: true)
        try save(presets: [preset])
        var current = previous; current[1].identity = panelIdentity
        let backend = try backend(current: current)
        let store = identityStore(backend, current: current)
        await store.refresh()
        XCTAssertEqual(store.settings.presets[0].displays[1].identity, panelIdentity)
        XCTAssertTrue(store.settings.presets[0].confirmed)
        XCTAssertEqual(try SettingsFile(directory: data).load().presets[0].displays[1].identity, panelIdentity)
        XCTAssertEqual(applyCalls(), 0)
    }

    @MainActor func testReconnectDuringRefreshUpdatesAvailabilityMirrorsAndRuleReferences() async throws {
        var saved = previous
        saved[1].identity = panelIdentity
        saved[0].mirrorOf = displayB; saved[1].x = 0
        let preset = Preset(name: "Mirror", displays: saved, confirmed: true)
        let rule = ConnectionRule(name: "Panel", presetID: preset.id,
                                  requiredDevices: [Device(id: "display:\(displayB)", name: "Panel", kind: .display)])
        try save(presets: [preset], rules: [rule])
        var current = previous; current[1].id = displayC; current[1].identity = panelIdentity
        let backend = try backend(current: current)
        let store = identityStore(backend, current: current)
        await store.refresh()
        let repaired = store.settings.presets[0]
        XCTAssertNil(store.unavailable(repaired))
        XCTAssertEqual(repaired.displays[1].id, displayC)
        XCTAssertEqual(repaired.displays[0].mirrorOf, displayC)
        XCTAssertEqual(store.settings.rules[0].requiredDevices[0].id, "display:\(displayC)")
        XCTAssertTrue(repaired.confirmed)
        XCTAssertEqual(applyCalls(), 0)
    }

    @MainActor func testApplyReconcilesFreshHardwareWithoutWaitingForRefresh() async throws {
        var saved = target; saved[1].identity = panelIdentity
        let preset = Preset(name: "Portrait", displays: saved, confirmed: true)
        try save(presets: [preset])
        var current = previous; current[1].id = displayC; current[1].identity = panelIdentity
        var applied = saved; applied[1].id = displayC
        let backend = try backend(current: current, steps: [1: applied])
        let store = identityStore(backend, current: current)
        await store.apply(preset)
        XCTAssertNotNil(store.pending)
        XCTAssertNil(store.error); XCTAssertNil(store.menuError)
        XCTAssertEqual(store.settings.presets[0].displays[1].id, displayC)
        let arguments = try String(contentsOf: dir.appendingPathComponent("applied.txt"))
        XCTAssertTrue(arguments.contains(displayC))
        XCTAssertFalse(arguments.contains(displayB))
        store.keep()
        XCTAssertFalse(journalExists())
    }

    @MainActor func testStaleEditorSaveUsesReconnectedIdentityAndPreservesLayoutEdits() async throws {
        var saved = previous; saved[1].identity = panelIdentity
        let preset = Preset(name: "Desk", displays: saved, confirmed: true)
        try save(presets: [preset])
        var current = saved; current[1].id = displayC
        let backend = try backend(current: current)
        let store = identityStore(backend, current: current)
        var draft = preset; draft.displays[1].rotation = 270
        await store.refresh()
        store.save(draft)
        XCTAssertEqual(store.settings.presets[0].displays[1].id, displayC)
        XCTAssertEqual(store.settings.presets[0].displays[1].rotation, 270)
        XCTAssertEqual(store.settings.presets[0].displays[1].identity, panelIdentity)
        XCTAssertFalse(store.settings.presets[0].confirmed)
        XCTAssertEqual(applyCalls(), 0)
    }

    @MainActor func testStaleRuleDraftUsesReconnectedDisplayReference() async throws {
        var saved = previous; saved[1].identity = panelIdentity
        let preset = Preset(name: "Desk", displays: saved, confirmed: true)
        let rule = ConnectionRule(name: "Panel absent", presetID: preset.id, requiredDevices: [],
                                  absentDevices: [Device(id: "display:\(displayB)", name: "Panel", kind: .display)])
        try save(presets: [preset], rules: [rule])
        var current = saved; current[1].id = displayC
        let backend = try backend(current: current)
        let store = identityStore(backend, current: current)
        await store.refresh()
        store.saveRule(rule)
        XCTAssertEqual(store.settings.rules[0].absentDevices[0].id, "display:\(displayC)")
        XCTAssertEqual(applyCalls(), 0)
    }

    @MainActor func testUUIDChangeDuringAirPlaySetupIsAppliedAndSavedOnlyAfterKeep() async throws {
        let castID = "00000000-0000-0000-0000-000000000004"
        let destination = AirPlayDestination(receiverName: "Fixture receiver", displayID: castID)
        var saved = target; saved[1].identity = panelIdentity
        let cast = DisplaySetting(id: castID, name: "Fixture receiver", mode: saved[0].mode, mirrorOf: displayA)
        saved.append(cast)
        let preset = Preset(name: "Desk and cast", displays: saved, airPlay: destination)
        try save(presets: [preset])
        var before = previous; before[1].identity = panelIdentity
        var after = before; after[1].id = displayC; after.append(cast)
        var applied = saved; applied[1].id = displayC
        let backend = try backend(current: before, steps: [1: applied])
        let state = ReconnectCastState()
        let output = dir.appendingPathComponent("current.txt")
        let afterFixture = try fixture(after)
        let identity = panelIdentity
        let hardware = HardwareProvider(devices: { [] }, connectedDisplayIDs: {
            state.isConnected ? Set([displayA, displayC, castID]) : Set([displayA, displayB])
        }, nameDisplays: { input in
            input.map { display in
                var copy = display
                if display.id == displayB || display.id == displayC { copy.setting.identity = identity }
                return copy
            }
        }, airPlayDisplays: { state.isConnected ? [castID: "Fixture receiver"] : [:] })
        let airPlay = AirPlayActions(authorized: { true }, requireAccess: {}, requestAccess: {}, receivers: { [] },
                                    setConnected: { _, connecting, record in
            XCTAssertTrue(connecting)
            try record()
            try afterFixture.write(to: output, atomically: true, encoding: .utf8)
            state.setConnected()
        })
        let store = Store(directory: data, backend: backend, hardware: hardware, airPlay: airPlay,
                          audio: sound.actions, notifier: .none, launchWatchdog: { _ in }, background: false)
        await store.apply(preset)
        XCTAssertNotNil(store.pending)
        XCTAssertNil(store.error); XCTAssertNil(store.menuError)
        XCTAssertEqual(store.pending?.preset.displays[1].id, displayC)
        XCTAssertEqual(store.settings.presets[0].displays[1].id, displayB, "saved references remain untouched during the pending change")
        XCTAssertEqual(RecoveryController(directory: data).read()?.previous[1].id, displayB, "the recovery journal is not rewritten")
        store.keep()
        XCTAssertEqual(store.settings.presets[0].displays[1].id, displayC)
        XCTAssertEqual(store.currentDisplayID(displayB), displayC)
        XCTAssertTrue(store.settings.presets[0].confirmed)
        XCTAssertFalse(journalExists())
    }

    @MainActor func testRepeatedReconnectsAndReturningUUIDKeepStaleDraftsOnTheSameMonitor() async throws {
        let lastID = "00000000-0000-0000-0000-000000000004"
        var saved = previous; saved[1].identity = panelIdentity
        let folder = PresetFolder(name: "Drawing")
        var preset = Preset(name: "Desk", displays: saved, confirmed: true, audio: AudioSelection(output: speakers))
        preset.folderID = folder.id
        var settings = AppSettings(); settings.presets = [preset]; settings.presetFolders = [folder]
        try SettingsFile(directory: data).save(settings)
        let backend = try backend(current: saved)
        var middle = saved[1]; middle.id = displayC
        var last = saved[1]; last.id = lastID
        let store = identityStore(backend, current: saved + [middle, last])
        for id in [displayC, displayB, lastID] {
            var connected = saved; connected[1].id = id
            try fixture(connected).write(to: dir.appendingPathComponent("current.txt"), atomically: true, encoding: .utf8)
            await store.refresh()
            XCTAssertEqual(store.settings.presets[0].displays[1].id, id)
            XCTAssertTrue(store.settings.presets[0].confirmed)
            if id == displayB { XCTAssertEqual(store.currentDisplayID(displayB), displayB, "a present UUID wins over earlier aliases") }
        }
        var staleDraft = preset; staleDraft.displays[1].rotation = 270
        store.save(staleDraft)
        XCTAssertEqual(store.settings.presets[0].displays[1].id, lastID)
        XCTAssertEqual(store.settings.presets[0].folderID, folder.id)
        XCTAssertEqual(store.settings.presets[0].audio, preset.audio)
        XCTAssertEqual(store.settings.presetFolders, [folder])
        XCTAssertEqual(applyCalls(), 0)
    }
}
