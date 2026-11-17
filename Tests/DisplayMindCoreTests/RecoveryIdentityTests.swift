import XCTest
@testable import DisplayMindCore
@testable import DisplayMind

extension RecoveryTests {
    private var reconnectIdentity: DisplayIdentity { DisplayIdentity(vendor: 101, model: 202, serial: 303) }
    private var fourthDisplay: String { "00000000-0000-0000-0000-000000000004" }

    private func identityBackend(current: [DisplaySetting], restored: [DisplaySetting], fail: Bool = false) throws -> DisplayBackend {
        let identities = Dictionary(uniqueKeysWithValues: current.compactMap { display in display.identity.map { (display.id, $0) } })
        var backend = try fakeBackend(current: current, restored: restored, fail: fail)
        backend.identify = { displays in
            displays.map { display in
                var copy = display; copy.setting.identity = identities[display.id]; return copy
            }
        }
        return backend
    }

    func testWatchdogRebindsChangedPhysicalUUIDBeforeRestoringPreviousLayout() throws {
        var previous = layout(); previous[1].identity = reconnectIdentity
        var current = previous; current[1].id = displayC; current[1].rotation = 270
        var restored = previous; restored[1].id = displayC
        let backend = try identityBackend(current: current, restored: restored)
        let journal = RecoveryJournal(deadline: .distantPast, previous: previous)
        try writeJournal(journal)
        let recovery = RecoveryController(directory: dir)
        recovery.watch(backend: backend, audio: .demo)
        XCTAssertNil(recovery.result()?.error)
        XCTAssertEqual(recovery.result()?.id, journal.id)
        let applied = try String(contentsOf: dir.appendingPathComponent("applied.txt"))
        XCTAssertTrue(applied.contains("id:\(displayC)"))
        XCTAssertFalse(applied.contains(displayB))
        XCTAssertTrue(applied.contains("degree:90"))
        XCTAssertTrue(Configuration.matches(restored, actual: try backend.read().map(\.setting)))
    }

    func testWatchdogDoesNotChooseBetweenAmbiguousPhysicalIdentities() throws {
        var previous = [layout()[1]]; previous[0].x = 0; previous[0].identity = reconnectIdentity
        var current = layout(); current[1].id = displayC; current[1].identity = reconnectIdentity
        var duplicate = current[1]; duplicate.id = fourthDisplay; duplicate.x += 1080
        current.append(duplicate)
        let backend = try identityBackend(current: current, restored: current)
        let journal = RecoveryJournal(deadline: .distantPast, previous: previous)
        try writeJournal(journal)
        let recovery = RecoveryController(directory: dir)
        recovery.watch(backend: backend, audio: .demo)
        XCTAssertTrue(recovery.result()?.error?.contains("The previous displays are disconnected") == true)
        XCTAssertEqual(appliedCount(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("restoring-\(journal.id).json").path))
    }

    func testFailedReboundRestoreKeepsTheOriginalJournalBytes() throws {
        var previous = layout(); previous[1].identity = reconnectIdentity
        var current = previous; current[1].id = displayC; current[1].rotation = 270
        var restored = previous; restored[1].id = displayC
        let backend = try identityBackend(current: current, restored: restored, fail: true)
        let journal = RecoveryJournal(deadline: .distantPast, previous: previous)
        try writeJournal(journal)
        let original = try Data(contentsOf: dir.appendingPathComponent("pending-change.json"))
        let recovery = RecoveryController(directory: dir)
        recovery.watch(backend: backend, audio: .demo)
        XCTAssertTrue(recovery.result()?.error?.contains("simulated failure") == true)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("restoring-\(journal.id).json")), original)
        let applied = try String(contentsOf: dir.appendingPathComponent("applied.txt"))
        XCTAssertTrue(applied.contains(displayC)); XCTAssertFalse(applied.contains(displayB))
    }

    func testAirPlayReferencesAreExcludedFromPhysicalRecoveryMatching() throws {
        var previous = [layout()[1]]; previous[0].x = 0; previous[0].identity = reconnectIdentity
        var current = previous; current[0].id = displayC
        let backend = try identityBackend(current: current, restored: current)
        var journal = RecoveryJournal(deadline: .distantPast, previous: previous)
        let cast = AirPlayDestination(receiverName: "Receiver", displayID: displayB)
        journal.stoppedAirPlay = [cast]
        try writeJournal(journal)
        var connected: [AirPlayDestination] = []
        let recovery = RecoveryController(directory: dir)
        recovery.watch(backend: backend, connectAirPlay: { connected.append($0) }, audio: .demo)
        XCTAssertEqual(connected, [cast])
        XCTAssertTrue(recovery.result()?.error?.contains("The previous displays are disconnected") == true)
        XCTAssertEqual(appliedCount(), 0)
    }

    func testExplicitFixtureBackendDoesNotAddNativeMetadataAndCanInjectIdentity() throws {
        let fixtureBackend = try fakeBackend(current: layout(), restored: layout())
        XCTAssertTrue(try fixtureBackend.read().allSatisfy { $0.setting.identity == nil })
        let identity = reconnectIdentity
        let injected = DisplayBackend(helper: fixtureBackend.helper, identify: { displays in
            displays.map { display in var copy = display; copy.setting.identity = identity; return copy }
        })
        XCTAssertTrue(try injected.read().allSatisfy { $0.setting.identity == identity })
    }
}
