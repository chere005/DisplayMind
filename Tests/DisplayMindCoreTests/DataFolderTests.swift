import XCTest
@testable import DisplayMindCore

final class DataFolderTests: XCTestCase {
    var root: URL!, home: URL!, support: URL!
    let files = FileManager.default
    override func setUpWithError() throws {
        root = files.temporaryDirectory.appendingPathComponent("DisplayMind-folder-tests-\(UUID())")
        home = root.appendingPathComponent("home"); support = home.appendingPathComponent("Library/Application Support")
        try files.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try files.removeItem(at: root) }
    func legacy(_ names: String...) throws -> URL {
        let folder = home.appendingPathComponent("DisplayMind")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names { try Data("{}".utf8).write(to: folder.appendingPathComponent(name)) }
        return folder
    }

    func testFreshInstallUsesApplicationSupportAndCreatesNothing() {
        let folder = DataFolder.resolve(home: home, support: support)
        XCTAssertEqual(folder.path, support.appendingPathComponent("DisplayMind").path)
        XCTAssertFalse(files.fileExists(atPath: folder.path))
    }
    func testFolderFromEarlierVersionsIsMovedOnceWithEverythingInIt() throws {
        let old = try legacy("settings.json", "recovery-result.json", "restoring-1.json")
        let folder = DataFolder.resolve(home: home, support: support)
        XCTAssertEqual(folder.path, support.appendingPathComponent("DisplayMind").path)
        XCTAssertFalse(files.fileExists(atPath: old.path))
        XCTAssertEqual(try files.contentsOfDirectory(atPath: folder.path).sorted(), ["recovery-result.json", "restoring-1.json", "settings.json"])
        XCTAssertEqual(DataFolder.resolve(home: home, support: support).path, folder.path)
    }
    func testPendingChangeKeepsTheOldFolderForThisRun() throws {
        // The watchdog for that change was started with the old path; moving its journal would cancel the rollback.
        let old = try legacy("settings.json", "pending-change.json")
        XCTAssertEqual(DataFolder.resolve(home: home, support: support).path, old.path)
        XCTAssertTrue(files.fileExists(atPath: old.appendingPathComponent("pending-change.json").path))
        try files.removeItem(at: old.appendingPathComponent("pending-change.json"))
        XCTAssertEqual(DataFolder.resolve(home: home, support: support).path, support.appendingPathComponent("DisplayMind").path)
    }
    func testAnUnrelatedFolderOfTheSameNameIsNotTouched() throws {
        let old = try legacy("notes.txt")
        XCTAssertEqual(DataFolder.resolve(home: home, support: support).path, support.appendingPathComponent("DisplayMind").path)
        XCTAssertTrue(files.fileExists(atPath: old.appendingPathComponent("notes.txt").path))
    }
    func testExistingNewFolderWinsAndTheOldOneIsLeft() throws {
        let old = try legacy("settings.json")
        let new = support.appendingPathComponent("DisplayMind")
        try files.createDirectory(at: new, withIntermediateDirectories: true)
        XCTAssertEqual(DataFolder.resolve(home: home, support: support).path, new.path)
        XCTAssertTrue(files.fileExists(atPath: old.appendingPathComponent("settings.json").path))
    }
}
