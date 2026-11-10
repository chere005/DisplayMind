import XCTest
@testable import DisplayMindCore
@testable import DisplayMind

final class RecoveryTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DisplayMind-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }
    func writeJournal(_ journal: RecoveryJournal) throws {
        try JSONEncoder().encode(journal).write(to: dir.appendingPathComponent("pending-change.json"))
    }
    func fakeBackend(current: [DisplaySetting], restored: [DisplaySetting], fail: Bool = false) throws -> DisplayBackend {
        try fixture(current).write(to: dir.appendingPathComponent("current.txt"), atomically: true, encoding: .utf8)
        try fixture(restored).write(to: dir.appendingPathComponent("restored.txt"), atomically: true, encoding: .utf8)
        let script = """
        #!/bin/sh
        cd "$(dirname "$0")"
        if [ "$1" = list ]; then cat current.txt; exit 0; fi
        printf '%s\\n' "$@" >> applied.txt
        \(fail ? "echo 'simulated failure' >&2; exit 1" : "cp restored.txt current.txt")
        """
        let executable = dir.appendingPathComponent("fake-displayplacer")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return DisplayBackend(helper: executable)
    }
    func testWatchdogRestoresAndVerifiesWithoutUI() throws {
        let previous = layout(); var changed = previous; changed[1].rotation = 270
        let backend = try fakeBackend(current: changed, restored: previous)
        let journal = RecoveryJournal(deadline: .distantPast, previous: previous)
        try writeJournal(journal)
        let recovery = RecoveryController(directory: dir)
        recovery.watch(backend: backend)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.pendingURL.path))
        XCTAssertEqual(recovery.result()?.id, journal.id)
        XCTAssertNil(recovery.result()?.error)
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("applied.txt")).contains("degree:90"))
    }
    func testKeepCancelsRollbackAndDeadlineCannotResurrectJournal() throws {
        let backend = try fakeBackend(current: layout(), restored: layout())
        let journal = RecoveryJournal(deadline: Date().addingTimeInterval(20), previous: layout())
        try writeJournal(journal)
        let recovery = RecoveryController(directory: dir)
        try recovery.keep(id: journal.id)
        XCTAssertThrowsError(try recovery.updateDeadline(id: journal.id, deadline: Date().addingTimeInterval(10)))
        recovery.watch(backend: backend)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("applied.txt").path))
    }
    func testExpiredChangeCannotBeKept() throws {
        let journal = RecoveryJournal(deadline: .distantPast, previous: layout())
        try writeJournal(journal)
        let recovery = RecoveryController(directory: dir)
        XCTAssertThrowsError(try recovery.keep(id: journal.id))
        XCTAssertNotNil(recovery.read())
    }
    func testRecoveryFailureIsReportedAndSnapshotPreserved() throws {
        var changed = layout(); changed[1].rotation = 270
        let backend = try fakeBackend(current: changed, restored: layout(), fail: true)
        let journal = RecoveryJournal(deadline: .distantPast, previous: layout())
        try writeJournal(journal)
        let recovery = RecoveryController(directory: dir); recovery.watch(backend: backend)
        XCTAssertTrue(recovery.result()?.error?.contains("simulated failure") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("restoring-\(journal.id).json").path))
    }
    func testUnpluggedMainDisplayAdaptsRecoveryToRemainingScreen() throws {
        var remaining = [layout()[1]]; Configuration.makeMain(displayB, displays: &remaining)
        let backend = try fakeBackend(current: remaining, restored: remaining)
        try writeJournal(RecoveryJournal(deadline: .distantPast, previous: layout()))
        let recovery = RecoveryController(directory: dir); recovery.watch(backend: backend)
        XCTAssertNotNil(recovery.result()); XCTAssertNil(recovery.result()?.error)
    }
    func testProcessTimeoutStopsOnlyItsOwnChild() {
        XCTAssertThrowsError(try ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"], timeout: 0.05))
    }
    func testRecoveryDisconnectsOnlyTheStreamStartedByTheChange() throws {
        let backend = try fakeBackend(current: layout(), restored: layout())
        let recovery = RecoveryController(directory: dir)
        var journal = RecoveryJournal(deadline: Date().addingTimeInterval(60), previous: layout())
        try writeJournal(journal)
        let target = AirPlayDestination(receiverName: "TV", displayID: displayB)
        try recovery.markAirPlayStarted(id: journal.id, target: target)
        try recovery.requestRevert()
        var disconnected: [AirPlayDestination] = []
        recovery.watch(backend: backend, disconnectAirPlay: { disconnected.append($0) })
        XCTAssertEqual(disconnected, [target]); XCTAssertNil(recovery.result()?.error)
        journal = RecoveryJournal(deadline: .distantPast, previous: layout())
        try writeJournal(journal)
        recovery.watch(backend: backend, disconnectAirPlay: { _ in XCTFail("Existing AirPlay streams must remain connected") })
        XCTAssertNil(recovery.result()?.error)
    }
    func testDisconnectFailureStillRestoresLayoutAndPreservesRecoverySnapshot() throws {
        var changed = layout(); changed[1].rotation = 270
        let backend = try fakeBackend(current: changed, restored: layout())
        var journal = RecoveryJournal(deadline: .distantPast, previous: layout())
        journal.startedAirPlay = AirPlayDestination(receiverName: "TV", displayID: displayB)
        try writeJournal(journal)
        let recovery = RecoveryController(directory: dir)
        recovery.watch(backend: backend, disconnectAirPlay: { _ in throw DisplayMindError("Permission revoked") })
        XCTAssertTrue(recovery.result()?.error?.contains("Permission revoked") == true)
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("applied.txt")).contains("degree:90"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("restoring-\(journal.id).json").path))
    }
}
