import XCTest
@testable import DisplayMindCore
@testable import DisplayMind

/// Holds one fake read so a test can exercise commands while an apply or restore is genuinely in flight.
private final class FirstReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func waitUntilStarted(timeout: TimeInterval = 5) -> Bool {
        started.wait(timeout: .now() + timeout) == .success
    }

    func identify(_ displays: [ConnectedDisplay]) -> [ConnectedDisplay] {
        lock.lock()
        let shouldWait = !held
        held = true
        lock.unlock()
        if shouldWait {
            started.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        return displays
    }
}

private enum BlockingReadFixture {
    static func waitForFile(_ url: URL, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

extension StoreTests {
    @MainActor func testEditorCannotReplaceTheVerifiedLayoutDuringItsRevertWindow() async throws {
        let backend = try backend(current: previous, steps: [1: target])
        let preset = Preset(name: "Portrait", displays: target)
        try save(presets: [preset])
        let store = makeStore(backend)
        store.editorPreset = preset
        var draft = preset
        draft.displays[1].mode.width += 100

        await store.apply(preset) // The menu bar and connection rules can apply while an editor is open.
        XCTAssertNotNil(store.pending)
        XCTAssertFalse(store.canEditSavedSettings)
        let before = store.settings
        store.save(draft)
        XCTAssertEqual(store.settings, before)
        XCTAssertEqual(store.editorPreset, preset, "the draft remains open until saving is safe")

        store.keep()
        XCTAssertTrue(store.canEditSavedSettings)
        XCTAssertTrue(store.settings.presets[0].confirmed)
        XCTAssertEqual(store.settings.presets[0].displays, target, "only the layout that actually verified may be confirmed")
        store.save(draft)
        XCTAssertEqual(store.settings.presets[0].displays, draft.displays)
        XCTAssertFalse(store.settings.presets[0].confirmed, "the edited layout requires its own successful apply")
        XCTAssertNil(store.editorPreset)
    }

    @MainActor func testSavedCommandsCannotMutatePresetsOrRulesDuringAnApply() async throws {
        var backend = try backend(current: previous, steps: [1: target])
        let gate = FirstReadGate()
        backend.identify = { gate.identify($0) }
        let preset = Preset(name: "Portrait", displays: target)
        let other = Preset(name: "Laptop", displays: previous)
        let rule = ConnectionRule(name: "Dock", presetID: preset.id, requiredDevices: [bothDisplays[0]])
        let secondRule = ConnectionRule(name: "Other dock", presetID: other.id, requiredDevices: [bothDisplays[1]])
        try save(presets: [preset, other], rules: [rule, secondRule])
        let store = makeStore(backend)
        store.editorRule = rule
        let operation = Task { await store.apply(preset) }
        let started = await Task.detached { gate.waitUntilStarted() }.value
        XCTAssertTrue(started)
        XCTAssertTrue(store.busy)
        XCTAssertFalse(store.canEditSavedSettings)
        let before = store.settings
        var draft = preset; draft.name = "Changed"
        var ruleDraft = rule; ruleDraft.name = " \nChanged rule\t "

        store.save(draft)
        XCTAssertFalse(store.rename(preset, to: "Renamed"))
        store.duplicate(preset)
        store.delete(other)
        store.saveRule(ruleDraft)
        store.deleteRule(rule)
        store.moveRule(rule, by: 1)
        XCTAssertEqual(store.settings, before)
        XCTAssertNil(store.editorPreset)
        XCTAssertEqual(store.editorRule, rule)

        gate.release.signal()
        await operation.value
        store.keep()
        XCTAssertTrue(store.canEditSavedSettings)
        store.saveRule(ruleDraft)
        XCTAssertEqual(store.settings.rules[0].name, "Changed rule")
        XCTAssertNil(store.editorRule)
    }

    @MainActor func testDeletingAnotherPresetKeepsTheSelectedPresetAndItsRules() throws {
        let backend = try backend(current: previous)
        let first = Preset(name: "First", displays: previous)
        let selected = Preset(name: "Selected", displays: target)
        let removed = Preset(name: "Remove", displays: previous)
        let keptRule = ConnectionRule(name: "Keep rule", presetID: selected.id, requiredDevices: [bothDisplays[0]])
        let removedRule = ConnectionRule(name: "Remove rule", presetID: removed.id, requiredDevices: [bothDisplays[1]])
        try save(presets: [first, selected, removed], rules: [keptRule, removedRule])
        let store = makeStore(backend)
        store.selectedPresetID = selected.id

        store.delete(removed)
        XCTAssertEqual(store.selectedPresetID, selected.id)
        XCTAssertEqual(store.settings.presets.map(\.id), [first.id, selected.id])
        XCTAssertEqual(store.settings.rules, [keptRule])
        store.delete(selected)
        XCTAssertEqual(store.selectedPresetID, first.id, "deleting the selected preset still chooses a valid fallback")
        XCTAssertTrue(store.settings.rules.isEmpty)
        XCTAssertEqual(applyCalls(), 0)
    }

    @MainActor func testNewerRefreshCannotBeOverwrittenByAnOlderDelayedRead() async throws {
        var backend = try backend(current: previous)
        let gate = FirstReadGate()
        backend.identify = { gate.identify($0) }
        let store = makeStore(backend)
        let older = Task { await store.refresh() }
        let started = await Task.detached { gate.waitUntilStarted() }.value
        XCTAssertTrue(started)

        try fixture(target).write(to: dir.appendingPathComponent("current.txt"), atomically: true, encoding: .utf8)
        await store.refresh()
        let current = store.displays
        XCTAssertTrue(Configuration.matches(target, actual: current.map(\.setting)))
        gate.release.signal()
        await older.value
        XCTAssertEqual(store.displays, current)
        XCTAssertEqual(applyCalls(), 0)
    }

    @MainActor func testApplySupersedesAnOlderRefreshAndRejectsRefreshWhilePending() async throws {
        var backend = try backend(current: previous, steps: [1: target])
        let gate = FirstReadGate()
        backend.identify = { gate.identify($0) }
        let preset = Preset(name: "Portrait", displays: target)
        try save(presets: [preset])
        let store = makeStore(backend)
        let older = Task { await store.refresh() }
        let started = await Task.detached { gate.waitUntilStarted() }.value
        XCTAssertTrue(started)

        await store.apply(preset)
        XCTAssertNotNil(store.pending)
        let applied = store.displays
        XCTAssertTrue(Configuration.matches(target, actual: applied.map(\.setting)))
        gate.release.signal()
        await older.value
        XCTAssertEqual(store.displays, applied)

        // A direct refresh during the Revert window must not replace the verified snapshot either.
        try fixture(previous).write(to: dir.appendingPathComponent("current.txt"), atomically: true, encoding: .utf8)
        await store.refresh()
        XCTAssertEqual(store.displays, applied)
        store.keep()
        XCTAssertTrue(store.settings.presets[0].confirmed)
		XCTAssertTrue(store.canRefreshDisplays)
    }

    @MainActor func testCaptureSupersedesAnOlderRefresh() async throws {
        var backend = try backend(current: previous)
        let gate = FirstReadGate()
        backend.identify = { gate.identify($0) }
        let store = makeStore(backend)
        let older = Task { await store.refresh() }
        let started = await Task.detached { gate.waitUntilStarted() }.value
        XCTAssertTrue(started)

        try fixture(target).write(to: dir.appendingPathComponent("current.txt"), atomically: true, encoding: .utf8)
        await store.capture()
        let captured = store.displays
        XCTAssertTrue(Configuration.matches(target, actual: captured.map(\.setting)))
        XCTAssertTrue(Configuration.matches(target, actual: store.editorPreset?.displays ?? []))
        gate.release.signal()
        await older.value
        XCTAssertEqual(store.displays, captured)
		XCTAssertTrue(store.canRefreshDisplays)
        XCTAssertEqual(applyCalls(), 0)
    }

    @MainActor func testCaptureDoesNotDiscardAnOpenDraftOrInterruptReceiverScanning() async throws {
        var backend = try backend(current: previous)
        let gate = FirstReadGate()
        gate.release.signal() // A regression must fail without blocking a helper thread.
        backend.identify = { gate.identify($0) }
        let store = makeStore(backend)
        let presetDraft = Preset(name: "Edits not saved yet", displays: target)
        store.editorPreset = presetDraft
        await store.capture()
        XCTAssertEqual(store.editorPreset, presetDraft)

        store.editorPreset = nil
        let ruleDraft = ConnectionRule(name: "Unsaved rule", presetID: presetDraft.id, requiredDevices: [bothDisplays[0]])
        store.editorRule = ruleDraft
        await store.capture()
        XCTAssertEqual(store.editorRule, ruleDraft)
        XCTAssertNil(store.editorPreset)

        store.editorRule = nil
        store.airPlayScanning = true
        await store.capture()
        XCTAssertNil(store.editorPreset)
        XCTAssertFalse(gate.waitUntilStarted(timeout: 0), "refused captures must not start a display read")
    }

    @MainActor func testFailureFromAnOlderRefreshDoesNotReplaceANewerSuccessfulRead() async throws {
        try fixture(target).write(to: dir.appendingPathComponent("current.txt"), atomically: true, encoding: .utf8)
        let executable = dir.appendingPathComponent("delayed-failure-displayplacer")
        let script = """
        #!/bin/sh
        cd "$(dirname "$0")"
        if mkdir first-read 2>/dev/null; then
            touch read-started
            while [ ! -f read-release ]; do sleep 0.01; done
            echo 'stale read failed' >&2
            exit 1
        fi
        cat current.txt
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let store = makeStore(DisplayBackend(helper: executable))
        let older = Task { await store.refresh() }
        let marker = dir.appendingPathComponent("read-started")
        let began = await Task.detached { BlockingReadFixture.waitForFile(marker) }.value
        XCTAssertTrue(began)
        await store.refresh()
        let current = store.displays
        XCTAssertTrue(Configuration.matches(target, actual: current.map(\.setting)))
        try Data().write(to: dir.appendingPathComponent("read-release"))
        await older.value
        XCTAssertEqual(store.displays, current)
        XCTAssertNil(store.error)
        XCTAssertNil(store.menuError)
        XCTAssertTrue(posts.items.isEmpty)
    }
}

extension RecoveryTests {
    func testKeepRefusesAnInFlightRestoreBeforeItsResultIsWritten() throws {
        let previous = layout()
        var changed = previous; changed[1].rotation = 270
        var backend = try fakeBackend(current: changed, restored: previous)
        let gate = FirstReadGate()
        backend.identify = { gate.identify($0) }
        let journal = RecoveryJournal(deadline: .distantPast, previous: previous)
        try writeJournal(journal)
        let recovery = RecoveryController(directory: dir)
        let finished = DispatchSemaphore(value: 0)
        let restoringBackend = backend
        Thread.detachNewThread {
            recovery.watch(backend: restoringBackend)
            finished.signal()
        }
        XCTAssertTrue(gate.waitUntilStarted())
        XCTAssertNil(recovery.read(), "the watchdog has claimed the journal")
        XCTAssertNil(recovery.result(), "the restore has not finished yet")
        XCTAssertThrowsError(try recovery.keep(id: journal.id))
        gate.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(recovery.result()?.id, journal.id)
        XCTAssertNil(recovery.result()?.error)
        XCTAssertThrowsError(try recovery.keep(id: journal.id), "a completed restore also cannot be kept")
    }
}
