import XCTest
@testable import DisplayMindCore
@testable import DisplayMind

/// Drives `Store` against a fake displayplacer in a temp directory and an in-process stand-in for the watchdog process.
final class StoreTests: XCTestCase {
    final class Posts { var items: [String] = [] }
    var dir: URL!
    var data: URL!
    let posts = Posts()
    var previous: [DisplaySetting] { layout() }
    var target: [DisplaySetting] { var d = layout(); d[1].rotation = 270; return d }
    var partial: [DisplaySetting] { var d = layout(); d[1].rotation = 0; return d }
    let bothDisplays = [Device(id: "display:\(displayA)", name: "A", kind: .display), Device(id: "display:\(displayB)", name: "B", kind: .display)]

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DisplayMind-store-tests-\(UUID())")
        data = dir.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    /// `steps[n]` is the layout the helper leaves behind after its n-th apply call; a missing step leaves the layout unchanged.
    func backend(current: [DisplaySetting], steps: [Int: [DisplaySetting]] = [:]) throws -> DisplayBackend {
        try fixture(current).write(to: dir.appendingPathComponent("current.txt"), atomically: true, encoding: .utf8)
        for (n, layout) in steps { try fixture(layout).write(to: dir.appendingPathComponent("step\(n).txt"), atomically: true, encoding: .utf8) }
        let script = """
        #!/bin/sh
        cd "$(dirname "$0")"
        if [ "$1" = list ]; then cat current.txt; exit 0; fi
        echo call >> calls.txt
        n=$(wc -l < calls.txt | tr -d ' ')
        printf '%s\\n' "$@" >> applied.txt
        [ -f step$n.txt ] && cp step$n.txt current.txt
        exit 0
        """
        let executable = dir.appendingPathComponent("fake-displayplacer")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return DisplayBackend(helper: executable)
    }
    func applyCalls() -> Int { (try? String(contentsOf: dir.appendingPathComponent("calls.txt")).split(separator: "\n").count) ?? 0 }
    func journalExists() -> Bool { FileManager.default.fileExists(atPath: data.appendingPathComponent("pending-change.json").path) }
    func save(presets: [Preset], rules: [ConnectionRule] = []) throws {
        var s = AppSettings(); s.presets = presets; s.rules = rules
        try SettingsFile(directory: data).save(s)
    }
    @MainActor func makeStore(_ backend: DisplayBackend, devices: [Device] = [], windowVisible: Bool = false) -> Store {
        let ids = Set(devices.map { String($0.id.dropFirst("display:".count)) })
        let hardware = HardwareProvider(devices: { devices }, connectedDisplayIDs: { ids }, nameDisplays: { $0 })
        let airPlay = AirPlayActions(authorized: { true }, requireAccess: {}, requestAccess: {}, receivers: { [] },
                                     setConnected: { _, _, _ in XCTFail("AirPlay must not be touched") })
        let posts = self.posts
        let store = Store(directory: data, backend: backend, hardware: hardware, airPlay: airPlay,
                          notifier: Notifier { title, body in posts.items.append(body) },
                          launchWatchdog: { directory in
                              Thread.detachNewThread { RecoveryController(directory: directory).watch(backend: backend, disconnectAirPlay: { _ in }) }
                          }, windowVisible: { windowVisible }, background: false)
        store.settle = 0
        return store
    }
    @MainActor func tickUntil(_ store: Store, timeout: TimeInterval = 10, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { await store.tick(); try? await Task.sleep(nanoseconds: 100_000_000) }
    }
    func layoutMatches(_ backend: DisplayBackend, _ expected: [DisplaySetting]) throws -> Bool {
        Configuration.matches(expected, actual: try backend.read().map(\.setting))
    }

    @MainActor func testManualApplyThenKeepConfirmsPresetAndRemovesJournal() async throws {
        let backend = try backend(current: previous, steps: [1: target])
        let preset = Preset(name: "Wide", displays: target)
        try save(presets: [preset])
        let store = makeStore(backend)
        await store.apply(preset)
        XCTAssertNotNil(store.pending); XCTAssertFalse(store.busy); XCTAssertTrue(journalExists())
        XCTAssertFalse(store.settings.presets[0].confirmed)
        store.keep()
        XCTAssertNil(store.pending); XCTAssertFalse(journalExists())
        XCTAssertTrue(store.settings.presets[0].confirmed)
        XCTAssertTrue(try SettingsFile(directory: data).load().presets[0].confirmed)
        XCTAssertNil(store.error); XCTAssertNil(store.menuError)
    }
    @MainActor func testManualApplyThenRevertRestoresPreviousLayout() async throws {
        let backend = try backend(current: previous, steps: [1: target, 2: previous])
        let preset = Preset(name: "Wide", displays: target)
        try save(presets: [preset])
        let store = makeStore(backend)
        await store.apply(preset)
        XCTAssertNotNil(store.pending)
        XCTAssertTrue(try layoutMatches(backend, target))
        store.revert()
        XCTAssertTrue(store.busy)
        await tickUntil(store) { !store.busy }
        XCTAssertFalse(store.busy); XCTAssertNil(store.pending); XCTAssertFalse(journalExists())
        XCTAssertTrue(try layoutMatches(backend, previous))
        XCTAssertEqual(RecoveryController(directory: data).result()?.error, nil)
        XCTAssertNotNil(RecoveryController(directory: data).result())
        XCTAssertNil(store.menuError); XCTAssertFalse(store.settings.presets[0].confirmed)
    }
    @MainActor func testUnverifiedApplyRequestsRevertAndReportsRestoredLayout() async throws {
        let backend = try backend(current: previous, steps: [1: partial, 2: previous])
        let preset = Preset(name: "Wide", displays: target)
        try save(presets: [preset])
        let store = makeStore(backend)
        await store.apply(preset)
        XCTAssertNil(store.pending); XCTAssertTrue(store.busy)
        await tickUntil(store) { !store.busy }
        XCTAssertFalse(store.busy)
        XCTAssertTrue(store.menuError?.contains("macOS did not accept every setting") == true)
        XCTAssertTrue(store.menuError?.hasSuffix("The previous layout was restored.") == true)
        XCTAssertEqual(posts.items, [store.menuError])
        XCTAssertTrue(try layoutMatches(backend, previous))
        XCTAssertFalse(journalExists())
    }
    @MainActor func testErrorWithWindowOpenIsAnAlertNotAMenuLine() async throws {
        let backend = try backend(current: previous, steps: [1: partial, 2: previous])
        let preset = Preset(name: "Wide", displays: target)
        try save(presets: [preset])
        let store = makeStore(backend, windowVisible: true)
        await store.apply(preset)
        await tickUntil(store) { !store.busy }
        XCTAssertNotNil(store.error); XCTAssertNil(store.menuError); XCTAssertTrue(posts.items.isEmpty)
    }
    @MainActor func testAutomaticApplyKeepsImmediatelyAndDoesNotRetrigger() async throws {
        let backend = try backend(current: previous, steps: [1: target])
        let preset = Preset(name: "Wide", displays: target, confirmed: true)
        let rule = ConnectionRule(name: "Desk", presetID: preset.id, requiredDevices: [bothDisplays[0]])
        try save(presets: [preset], rules: [rule])
        let store = makeStore(backend, devices: bothDisplays)
        await store.refresh()
        await store.tick()
        XCTAssertNil(store.pending); XCTAssertFalse(store.busy); XCTAssertFalse(journalExists())
        XCTAssertEqual(store.status, "Automatically applied Wide")
        XCTAssertEqual(applyCalls(), 1)
        XCTAssertEqual(posts.items, ["Automatically applied Wide"])
        XCTAssertTrue(try layoutMatches(backend, target))
        await store.tick(); await store.tick()
        XCTAssertEqual(store.status, "Automatically applied Wide")
        XCTAssertEqual(applyCalls(), 1); XCTAssertEqual(posts.items.count, 1)
        XCTAssertNil(store.error); XCTAssertNil(store.menuError)
    }
    @MainActor func testPresetAlreadyMatchingIsConfirmedWithoutRunningTheHelper() async throws {
        let backend = try backend(current: target)
        let preset = Preset(name: "Wide", displays: target)
        try save(presets: [preset])
        let store = makeStore(backend)
        await store.apply(preset)
        XCTAssertEqual(applyCalls(), 0); XCTAssertNil(store.pending); XCTAssertFalse(store.busy); XCTAssertFalse(journalExists())
        XCTAssertTrue(store.settings.presets[0].confirmed)
        XCTAssertEqual(store.status, "Wide is active")
    }
    @MainActor func testUnconfirmedPresetIsNeverAppliedAutomatically() async throws {
        let backend = try backend(current: previous, steps: [1: target])
        let preset = Preset(name: "Wide", displays: target, confirmed: false)
        let rule = ConnectionRule(name: "Desk", presetID: preset.id, requiredDevices: [bothDisplays[0]])
        try save(presets: [preset], rules: [rule])
        let store = makeStore(backend, devices: bothDisplays)
        await store.refresh(); await store.tick(); await store.tick()
        XCTAssertEqual(applyCalls(), 0); XCTAssertNil(store.pending); XCTAssertFalse(journalExists()); XCTAssertTrue(posts.items.isEmpty)
        XCTAssertTrue(try layoutMatches(backend, previous))
    }

    // MARK: recovery while the UI was closed

    func writeSnapshot(_ journal: RecoveryJournal, age: TimeInterval = 0) throws {
        let url = data.appendingPathComponent("restoring-\(journal.id).json")
        try JSONEncoder().encode(journal).write(to: url)
        if age > 0 { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path) }
    }
    func writeResult(_ result: RecoveryResult) throws {
        try JSONEncoder().encode(result).write(to: data.appendingPathComponent("recovery-result.json"))
    }
    @MainActor func testFailedResultWrittenWhileClosedIsShownOnceAndSnapshotKept() throws {
        let backend = try backend(current: previous)
        let journal = RecoveryJournal(deadline: .distantPast, previous: previous)
        try writeSnapshot(journal)
        try writeResult(RecoveryResult(id: journal.id, error: "simulated failure"))
        let store = makeStore(backend)
        XCTAssertTrue(store.menuError?.contains("simulated failure") == true)
        XCTAssertEqual(posts.items.count, 1); XCTAssertEqual(store.status, "Display recovery needs attention")
        XCTAssertFalse(store.busy)
        XCTAssertEqual(RecoveryController(directory: data).result()?.acknowledged, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("restoring-\(journal.id).json").path))
        XCTAssertEqual(applyCalls(), 0)
        let second = makeStore(backend)
        XCTAssertNil(second.menuError); XCTAssertEqual(posts.items.count, 1); XCTAssertFalse(second.busy)
    }
    @MainActor func testOrphanedRestoreIsResumedVerifiedAndReported() async throws {
        let backend = try backend(current: target, steps: [1: previous])
        let journal = RecoveryJournal(deadline: .distantPast, previous: previous)
        try writeSnapshot(journal)
        let store = makeStore(backend)
        XCTAssertTrue(store.busy)
        await tickUntil(store) { !store.busy }
        XCTAssertTrue(try layoutMatches(backend, previous))
        XCTAssertEqual(RecoveryController(directory: data).result()?.id, journal.id)
        XCTAssertNil(RecoveryController(directory: data).result()?.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("restoring-\(journal.id).json").path))
        XCTAssertNil(store.menuError)
    }
    @MainActor func testFailedOrphanRestoreIsReportedAndNotRetriedNextLaunch() async throws {
        let backend = try backend(current: target)   // helper leaves the layout wrong
        let journal = RecoveryJournal(deadline: .distantPast, previous: previous)
        try writeSnapshot(journal)
        let store = makeStore(backend)
        await tickUntil(store) { !store.busy }
        XCTAssertTrue(store.menuError?.contains("macOS did not restore every display setting") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("restoring-\(journal.id).json").path))
        let calls = applyCalls()
        let second = makeStore(backend)
        XCTAssertFalse(second.busy); XCTAssertNil(second.menuError); XCTAssertEqual(applyCalls(), calls)
    }
    @MainActor func testStaleOrSupersededSnapshotsAreNotResumed() async throws {
        let backend = try backend(current: target, steps: [1: previous])
        try writeSnapshot(RecoveryJournal(deadline: .distantPast, previous: previous), age: 7200)
        XCTAssertFalse(makeStore(backend).busy)
        XCTAssertEqual(applyCalls(), 0)
        // A new armed change moves older snapshots aside.
        let recovery = RecoveryController(directory: data)
        let fresh = RecoveryJournal(deadline: .distantPast, previous: previous)
        try writeSnapshot(fresh)
        _ = try recovery.arm(previous: previous, launch: { _ in })
        XCTAssertNil(recovery.orphanedRestore())
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("superseded-\(fresh.id).json").path))
    }

    // MARK: saving

    @MainActor func testRenamingADisplayKeepsThePresetConfirmed() throws {
        let backend = try backend(current: previous)
        let preset = Preset(name: "Wide", displays: target, confirmed: true)
        try save(presets: [preset])
        let store = makeStore(backend)
        var draft = preset
        draft.displays[0].name = "Renamed"; draft.confirmed = false   // the editor may have already cleared it
        store.save(draft)
        XCTAssertEqual(store.settings.presets[0].displays[0].name, "Renamed")
        XCTAssertTrue(store.settings.presets[0].confirmed)
        XCTAssertTrue(try SettingsFile(directory: data).load().presets[0].confirmed)
        var moved = store.settings.presets[0]
        moved.displays[1].y = 100
        store.save(moved)
        XCTAssertFalse(store.settings.presets[0].confirmed)
        // An unconfirmed preset is not confirmed by a rename.
        var again = store.settings.presets[0]; again.displays[0].name = "Again"; again.confirmed = true
        store.save(again)
        XCTAssertFalse(store.settings.presets[0].confirmed)
    }
    func testSameLayoutIgnoresOnlyTheName() {
        var a = layout(); XCTAssertTrue(Configuration.sameLayout(a, layout()))
        a[0].name = "Other"; XCTAssertTrue(Configuration.sameLayout(a, layout()))
        a[0].mode.hertz = 30; XCTAssertFalse(Configuration.sameLayout(a, layout()))
        XCTAssertFalse(Configuration.sameLayout([a[0]], layout()))
    }

    // MARK: change notifications instead of polling

    final class FakeMonitor {
        var handler: (@MainActor (HardwareChange) -> Void)?
        var stopped = false
        final class Token { let owner: FakeMonitor; init(_ o: FakeMonitor) { owner = o }; deinit { owner.stopped = true } }
        var monitor: HardwareMonitor { HardwareMonitor { [self] h in handler = h; return Token(self) } }
        @MainActor func fire(_ change: HardwareChange = .usb) { handler?(change) }
    }
    final class FakeDevices: @unchecked Sendable {
        private let lock = NSLock(); private var list: [Device]; private var n = 0
        init(_ list: [Device]) { self.list = list }
        var devices: [Device] { lock.lock(); defer { lock.unlock() }; n += 1; return list }
        func set(_ new: [Device]) { lock.lock(); list = new; lock.unlock() }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
    @MainActor func makeEventStore(_ backend: DisplayBackend, _ fake: FakeDevices, _ monitor: FakeMonitor, settle: TimeInterval = 0.2) -> Store {
        let hardware = HardwareProvider(devices: { fake.devices }, connectedDisplayIDs: { [] }, nameDisplays: { $0 })
        let airPlay = AirPlayActions(authorized: { true }, requireAccess: {}, requestAccess: {}, receivers: { [] },
                                     setConnected: { _, _, _ in XCTFail("AirPlay must not be touched") })
        let posts = self.posts
        let store = Store(directory: data, backend: backend, hardware: hardware, airPlay: airPlay, notifier: Notifier { _, body in posts.items.append(body) },
                          launchWatchdog: { directory in
                              Thread.detachNewThread { RecoveryController(directory: directory).watch(backend: backend, disconnectAirPlay: { _ in }) }
                          }, windowVisible: { false }, background: false, monitor: monitor.monitor)
        store.settle = settle; store.coalesce = 0.05
        return store
    }
    @MainActor func eventually(_ timeout: TimeInterval = 10, _ done: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while true {
            if done() || Date() >= end { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    func deskRule() throws -> (Preset, ConnectionRule) {
        let preset = Preset(name: "Wide", displays: target, confirmed: true)
        let rule = ConnectionRule(name: "Desk", presetID: preset.id, requiredDevices: [bothDisplays[1]])
        try save(presets: [preset], rules: [rule])
        return (preset, rule)
    }

    @MainActor func testChangeEventThenStableDevicesAppliesRuleOnceAfterSettle() async throws {
        let backend = try backend(current: previous, steps: [1: target])
        _ = try deskRule()
        let fake = FakeDevices([bothDisplays[0]]), monitor = FakeMonitor()
        let store = makeEventStore(backend, fake, monitor, settle: 0.6)
        await eventually { !store.isTicking }   // launch evaluation: no rule matches
        XCTAssertFalse(store.isTicking); XCTAssertEqual(applyCalls(), 0)
        fake.set(bothDisplays); monitor.fire()
        XCTAssertTrue(store.isTicking)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(applyCalls(), 0)   // not before the settle interval
        await eventually { self.applyCalls() == 1 && !store.isTicking }
        XCTAssertEqual(applyCalls(), 1); XCTAssertEqual(store.status, "Automatically applied Wide"); XCTAssertFalse(store.isTicking)
        XCTAssertEqual(posts.items, ["Automatically applied Wide"])
    }
    @MainActor func testBurstOfEventsIsOneEvaluation() async throws {
        let backend = try backend(current: previous, steps: [1: target])
        _ = try deskRule()
        let fake = FakeDevices([bothDisplays[0]]), monitor = FakeMonitor()
        let store = makeEventStore(backend, fake, monitor)
        await eventually { !store.isTicking }
        let before = fake.reads
        fake.set(bothDisplays)
        for i in 0..<20 { monitor.fire(i % 2 == 0 ? .usb : .displays) }
        await eventually { self.applyCalls() == 1 && !store.isTicking }
        XCTAssertEqual(applyCalls(), 1); XCTAssertEqual(posts.items.count, 1)
        XCTAssertLessThanOrEqual(fake.reads - before, 4)   // 1 coalesced read + settle read + the post-apply consume (+1 slack), not one per event
    }
    @MainActor func testNoTimerRunsWhenIdleAndMonitorIsReleasedWithTheStore() async throws {
        let backend = try backend(current: previous)
        let fake = FakeDevices(bothDisplays), monitor = FakeMonitor()
        var store: Store? = makeEventStore(backend, fake, monitor)
        await eventually { store?.isTicking == false }
        XCTAssertFalse(store!.isTicking)
        let reads = fake.reads
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(fake.reads, reads)   // idle: no polling at all
        XCTAssertFalse(monitor.stopped)
        store = nil
        XCTAssertTrue(monitor.stopped)
    }
    @MainActor func testCountdownAndRecoveryResultRunOnTheTimerThenStop() async throws {
        let backend = try backend(current: previous, steps: [1: target, 2: previous])
        let preset = Preset(name: "Wide", displays: target)
        try save(presets: [preset])
        let monitor = FakeMonitor()
        let store = makeEventStore(backend, FakeDevices([]), monitor)
        await eventually { !store.isTicking }
        await store.apply(preset)
        XCTAssertNotNil(store.pending); XCTAssertTrue(store.isTicking)
        await eventually { store.secondsRemaining < 20 }
        XCTAssertLessThan(store.secondsRemaining, 20)   // countdown advanced with no manual tick
        store.revert()
        await eventually { !store.busy && !store.isTicking }
        XCTAssertFalse(store.busy); XCTAssertFalse(store.isTicking)
        XCTAssertTrue(try layoutMatches(backend, previous))
        XCTAssertNotNil(RecoveryController(directory: data).result())
    }
    @MainActor func testWakeResetsTheGateSoRulesAreReevaluated() async throws {
        let backend = try backend(current: previous, steps: [1: target])
        _ = try deskRule()
        let fake = FakeDevices(bothDisplays), monitor = FakeMonitor()
        let store = makeEventStore(backend, fake, monitor, settle: 0.1)
        await eventually { store.status == "Automatically applied Wide" && !store.isTicking }
        XCTAssertEqual(store.status, "Automatically applied Wide")
        monitor.fire(.usb)   // same devices: already consumed
        await eventually { store.isTicking }; await eventually { !store.isTicking }
        XCTAssertEqual(store.status, "Automatically applied Wide")
        monitor.fire(.wake)
        await eventually { store.status == "Wide is active" }
        XCTAssertEqual(store.status, "Wide is active"); XCTAssertEqual(applyCalls(), 1)
    }
}
