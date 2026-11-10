import XCTest
@testable import DisplayMindCore

private func box(_ id: String, _ x: Int, _ y: Int, _ w: Int = 1000, _ h: Int = 500, mirrorOf: String? = nil, enabled: Bool = true) -> DisplaySetting {
    DisplaySetting(id: id, name: "D\(id)", mode: DisplayMode(width: w, height: h), x: x, y: y, mirrorOf: mirrorOf, enabled: enabled)
}
private func snap(_ d: [DisplaySetting], _ id: String, _ x: Int, _ y: Int) -> [Int]? {
    Configuration.snappedPosition(d, moving: id, to: (x, y)).map { [$0.x, $0.y] }
}

final class ArrangementTests: XCTestCase {
    func testValidLayouts() {
        XCTAssertNil(Configuration.arrangementIssue([box("a", 0, 0)]))
        XCTAssertNil(Configuration.arrangementIssue([box("a", 0, 0), box("b", 1000, 0)]))
        XCTAssertNil(Configuration.arrangementIssue([box("a", 0, 0), box("b", 0, 500)]))
        XCTAssertNil(Configuration.arrangementIssue([box("a", 0, 0), box("b", 1000, 500)]), "corner touch")
        XCTAssertNil(Configuration.arrangementIssue([box("a", 0, 0), box("b", 1000, 200), box("c", 500, 700)]))
    }
    func testGapAndOverlap() {
        XCTAssertNotNil(Configuration.arrangementIssue([box("a", 0, 0), box("b", 1001, 0)]))
        XCTAssertNotNil(Configuration.arrangementIssue([box("a", 0, 0), box("b", 1000, 501)]))
        XCTAssertNotNil(Configuration.arrangementIssue([box("a", 0, 0), box("b", 999, 0)]))
        XCTAssertNotNil(Configuration.arrangementIssue([box("a", 0, 0), box("b", 10, 10)]))
        XCTAssertNotNil(Configuration.arrangementIssue([box("a", 0, 0), box("b", 0, 0)]))
    }
    func testDisconnectedThird() {
        let issue = Configuration.arrangementIssue([box("a", 0, 0), box("b", 1000, 0), box("c", 5000, 0)])
        XCTAssertNotNil(issue); XCTAssertTrue(issue!.contains("Dc"))
        XCTAssertNil(Configuration.arrangementIssue([box("a", 0, 0), box("b", 1000, 0), box("c", 2000, 0)]), "chain connects through b")
    }
    func testRotatedDimensionsAndNegativeCoordinates() {
        var portrait = box("b", 1000, 0, 500, 1000); portrait.rotation = 90
        XCTAssertNil(Configuration.arrangementIssue([box("a", 0, 0), portrait]))
        portrait.y = -600
        XCTAssertNil(Configuration.arrangementIssue([box("a", 0, 0), portrait]), "stands 1000 tall, spans -600..400")
        portrait.y = -1001
        XCTAssertNotNil(Configuration.arrangementIssue([box("a", 0, 0), portrait]))
        XCTAssertNil(Configuration.arrangementIssue([box("a", 0, 0), box("b", -1000, 0), box("c", -1000, -500)]))
        XCTAssertNotNil(Configuration.arrangementIssue([box("a", 0, 0), box("b", -999, -400)]), "negative overlap")
    }
    func testMirrorsAndDisabledIgnored() {
        XCTAssertNil(Configuration.arrangementIssue([box("a", 0, 0), box("m", 50, 50, mirrorOf: "a")]))
        XCTAssertNil(Configuration.arrangementIssue([box("a", 0, 0), box("off", 9000, 9000, enabled: false)]))
        XCTAssertNil(Configuration.arrangementIssue([box("a", 0, 0), box("b", 1000, 0), box("off", 0, 0, enabled: false)]))
    }
    func testSnapFromGapOnEachSide() {
        let d = [box("a", 0, 0), box("b", 0, 0)]
        XCTAssertEqual(snap(d, "b", 1100, 100), [1000, 100])
        XCTAssertEqual(snap(d, "b", -1100, 100), [-1000, 100])
        XCTAssertEqual(snap(d, "b", 100, 600), [100, 500])
        XCTAssertEqual(snap(d, "b", 100, -600), [100, -500])
    }
    func testSnapFromOverlapOnEachSide() {
        let d = [box("a", 0, 0), box("b", 0, 0)]
        XCTAssertEqual(snap(d, "b", 900, 50), [1000, 50])
        XCTAssertEqual(snap(d, "b", -900, 50), [-1000, 50])
        XCTAssertEqual(snap(d, "b", 50, 400), [50, 500])
        XCTAssertEqual(snap(d, "b", 50, -400), [50, -500])
    }
    func testSnapClampsPerpendicularToKeepContact() {
        let d = [box("a", 0, 0), box("b", 0, 0)]
        XCTAssertEqual(snap(d, "b", 1100, 5000), [1000, 500], "corner")
        XCTAssertEqual(snap(d, "b", 1100, -5000), [1000, -500])
        XCTAssertEqual(snap(d, "b", 5000, 600), [1000, 500])
    }
    func testSnapAvoidsOtherDisplaysAndUsesNearest() {
        let d = [box("a", 0, 0), box("c", 1000, 0), box("b", 0, 0)]
        // right of a is occupied by c; the nearest free contact is right of c.
        XCTAssertEqual(snap(d, "b", 1050, 100), [1050, 500])
        XCTAssertEqual(snap(d, "b", 2200, 100), [2000, 100])
    }
    func testSnapRotatedAndNegativeAndDeterministic() {
        var p = box("b", 0, 0, 500, 1000); p.rotation = 90
        let d = [box("a", -1000, -500), p]
        XCTAssertEqual(snap(d, "b", 20, -700), [0, -700], "right of a, spans -700..300, still touching a's -500..0")
        XCTAssertEqual(snap(d, "b", 20, -700), snap(d, "b", 20, -700))
        XCTAssertEqual(snap(d, "b", -1200, -1700), [-1200, -1500], "above a")
    }
    func testSnapPassThroughCases() {
        XCTAssertEqual(snap([box("a", 0, 0)], "a", 77, 88), [77, 88], "no neighbour")
        XCTAssertEqual(snap([box("a", 0, 0), box("m", 0, 0, mirrorOf: "a")], "a", 77, 88), [77, 88], "mirror is not a neighbour")
        XCTAssertEqual(snap([box("a", 0, 0), box("b", 0, 0, enabled: false)], "b", 77, 88), [77, 88], "disabled mover")
    }
    func testSnapResultHasNoIssue() {
        let d = [box("a", 0, 0), box("c", 1000, 0), box("b", 0, 0)]
        for (x, y) in [(1050, 100), (-30, 20), (400, 300), (3000, -900)] {
            var e = d; let p = Configuration.snappedPosition(e, moving: "b", to: (x, y))!
            e[2].x = p.x; e[2].y = p.y
            XCTAssertNil(Configuration.arrangementIssue(e), "\(x),\(y)")
        }
    }
    func testPickerOrder() {
        let modes = [DisplayMode(width: 800, height: 600, hertz: 60), DisplayMode(width: 2560, height: 1440, hertz: 60),
                     DisplayMode(width: 1920, height: 1080, hertz: 30), DisplayMode(width: 1920, height: 1080, hertz: 60),
                     DisplayMode(width: 1920, height: 1080, hertz: 60, scaled: true), DisplayMode(width: 1920, height: 1200, hertz: 60)]
        let sorted = modes.sorted(by: DisplayMode.pickerOrder).map { "\($0.width)x\($0.height)@\($0.hertz)\($0.scaled ? "s" : "")" }
        XCTAssertEqual(sorted, ["2560x1440@60", "1920x1200@60", "1920x1080@60s", "1920x1080@60", "1920x1080@30", "800x600@60"])
        XCTAssertEqual(modes.reversed().sorted(by: DisplayMode.pickerOrder), modes.sorted(by: DisplayMode.pickerOrder))
    }
}
