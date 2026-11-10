import XCTest
@testable import DisplayMindCore

let displayA = "00000000-0000-0000-0000-000000000001"
let displayB = "00000000-0000-0000-0000-000000000002"
let displayC = "00000000-0000-0000-0000-000000000003"
func layout() -> [DisplaySetting] {
    [DisplaySetting(id: displayA, name: "Desktop", mode: DisplayMode(width: 1920, height: 1080, hertz: 60)),
     DisplaySetting(id: displayB, name: "Portrait", mode: DisplayMode(width: 1080, height: 1920, hertz: 60), rotation: 90, x: 1920)]
}

/// Synthetic helper output. Never captures the machine's actual identities or changes its screens.
func fixture(_ displays: [DisplaySetting]) throws -> String {
    var text = ""
    for (index, d) in displays.enumerated() {
        text += """
        Persistent screen id: \(d.id)
        Contextual screen id: \(index + 1)
        Serial screen id: s\(index + 100)
        Type: \(index == 0 ? "MacBook built in screen" : "27 inch external screen")
        Resolution: \(d.mode.width)x\(d.mode.height)
        Hertz: \(d.mode.hertz == 0 ? "N/A" : String(d.mode.hertz))
        Color Depth: \(d.mode.depth)
        Scaling: \(d.mode.scaled ? "on" : "off")
        Origin: (\(d.x),\(d.y))\(d.x == 0 && d.y == 0 ? " - main display" : "")
        Rotation: \(d.rotation)
        Enabled: \(d.enabled ? "true" : "false")
        Resolutions for rotation \(d.rotation):
          mode 0: res:\(d.mode.width)x\(d.mode.height)\(d.mode.hertz > 0 ? " hz:\(d.mode.hertz)" : "") color_depth:\(d.mode.depth)\(d.mode.scaled ? " scaling:on" : "") <-- current mode


        """
    }
    text += "Execute the command below to set your screens to the current arrangement.\n\ndisplayplacer "
    text += try Configuration.arguments(for: displays).map { "\"\($0)\"" }.joined(separator: " ") + "\n"
    return text
}

final class ConfigurationTests: XCTestCase {
    func testExtendedAndRotatedArguments() throws {
        let args = try Configuration.arguments(for: layout())
        XCTAssertEqual(args.count, 2)
        XCTAssertTrue(args[1].contains("res:1080x1920"))
        XCTAssertTrue(args[1].contains("origin:(1920,0) degree:90"))
        XCTAssertFalse(args[1].contains("\""))
    }
    func testMirrorArgumentsUseSourceAndDoNotApplyFollowerTwice() throws {
        var d = layout(); d[1].mirrorOf = displayA
        let args = try Configuration.arguments(for: d)
        XCTAssertEqual(args.count, 1)
        XCTAssertTrue(args[0].hasPrefix("id:\(displayA)+\(displayB) res:1920x1080"))
        XCTAssertTrue(args[0].hasSuffix("degree:0"))
    }
    func testRejectsCyclesMissingSourcesAndDuplicateMain() {
        var d = layout(); d[0].mirrorOf = displayB; d[1].mirrorOf = displayA
        XCTAssertThrowsError(try Configuration.validate(d))
        d = layout(); d[1].mirrorOf = displayC
        XCTAssertThrowsError(try Configuration.validate(d))
        d = layout(); d[1].x = 0
        XCTAssertThrowsError(try Configuration.validate(d))
        d = layout(); d[1].id = displayA
        XCTAssertThrowsError(try Configuration.validate(d))
    }
    func testRejectsMalformedOrExtremeInputWithoutTrapping() {
        var d = layout(); d[1].id = "$(touch /tmp/nope)"
        XCTAssertThrowsError(try Configuration.arguments(for: d))
        d = layout(); d[1].x = Int.min
        XCTAssertThrowsError(try Configuration.validate(d))
        d = layout(); d[1].mode.width = 0
        XCTAssertThrowsError(try Configuration.validate(d))
        d = layout(); d[1].rotation = 12
        XCTAssertThrowsError(try Configuration.validate(d))
        XCTAssertThrowsError(try Configuration.validate([]))
    }
    func testValidatesSavedSoundDevices() throws {
        func preset(_ audio: AudioSelection?) -> Preset { Preset(name: "P", displays: layout(), audio: audio) }
        try Configuration.validate(preset(nil))
        try Configuration.validate(preset(AudioSelection(output: AudioDevice(uid: "a", name: "A"))))
        for bad in [AudioDevice(uid: "", name: "A"), AudioDevice(uid: "a", name: "  "), AudioDevice(uid: "a\nb", name: "A"), AudioDevice(uid: "a", name: "A\nB"),
                    AudioDevice(uid: String(repeating: "x", count: 257), name: "A"), AudioDevice(uid: "a", name: String(repeating: "x", count: 257))] {
            XCTAssertThrowsError(try Configuration.validate(preset(AudioSelection(input: bad))))
            XCTAssertThrowsError(try Configuration.validate(preset(AudioSelection(output: bad))))
        }
    }
    func testChangingMainPreservesRelativePositions() throws {
        var d = layout(); Configuration.makeMain(displayB, displays: &d)
        XCTAssertEqual(d[0].x, -1920); XCTAssertEqual(d[1].x, 0)
        try Configuration.validate(d)
    }
    func testRoundTripParserWithMirrorAndVariableRefreshRate() throws {
        var d = layout(); d[0].mode.hertz = 0; d[0].mode.scaled = true; d[1].mirrorOf = displayA
        let result = try DisplayParser.parse(fixture(d))
        XCTAssertEqual(result.map(\.id), [displayA, displayB])
        XCTAssertEqual(result[1].setting.mirrorOf, displayA)
        XCTAssertTrue(result[0].setting.mode.scaled)
        XCTAssertEqual(result[0].setting.mode.hertz, 0)
        XCTAssertEqual(result[0].modes, [d[0].mode])
    }
    func testParserRejectsTruncatedAndUnexpectedOutput() throws {
        XCTAssertThrowsError(try DisplayParser.parse("helper failed"))
        let text = try fixture(layout()).replacingOccurrences(of: "Resolution:", with: "Unknown:")
        XCTAssertThrowsError(try DisplayParser.parse(text))
    }
    func testCaptureParsesNegativePositionsAndDisabledDisplay() throws {
        var d = layout(); Configuration.makeMain(displayB, displays: &d)
        d.append(DisplaySetting(id: displayC, name: "Off", mode: DisplayMode(width: 1920, height: 1080), x: 3000, enabled: false))
        let parsed = try DisplayParser.parse(fixture(d))
        XCTAssertEqual(parsed[0].setting.x, -1920)
        XCTAssertFalse(parsed[2].setting.enabled)
    }
    func testVerificationDetectsPartialApplication() {
        let d = layout()
        XCTAssertTrue(Configuration.matches(d, actual: d))
        var partial = d; partial[1].rotation = 0
        XCTAssertFalse(Configuration.matches(d, actual: partial))
        partial = d; partial[1].mode.width = 800
        XCTAssertFalse(Configuration.matches(d, actual: partial))
        partial = d; partial[1].mirrorOf = displayA
        XCTAssertFalse(Configuration.matches(d, actual: partial))
        XCTAssertFalse(Configuration.matches(d, actual: [d[0]]))
    }
    func testPlaceholderNamesAreOnlyTheOnesThisAppMakesUp() {
        for name in ["External display", "External display 2", "External display 12", "31-inch display"] { XCTAssertTrue(DisplayParser.isPlaceholder(name), name) }
        for name in ["Built-in display", "Wacom One 12", "External display two", "My External display 2", "31-inch display left", ""] { XCTAssertFalse(DisplayParser.isPlaceholder(name), name) }
    }
    func testSoundPolicyLeavesBluetoothInUseAndTakesOverOnlyWhenItGoes() {
        let speakers = AudioDevice(uid: "spk", name: "Speakers"), mic = AudioDevice(uid: "mic", name: "Mic")
        let pods = AudioDevice(uid: "bt", name: "AirPods"), tv = AudioDevice(uid: "tv", name: "TV")
        let wanted = AudioSelection(output: speakers, input: mic)
        // Headphones are the output: only the input is set.
        var plan = AudioPolicy.applicable(wanted, current: AudioSelection(output: pods, input: mic), bluetooth: ["bt"])
        XCTAssertEqual(plan.set, AudioSelection(output: nil, input: mic)); XCTAssertEqual(plan.kept, [pods])
        // Headphones are connected but not in use, or the preset names them itself: nothing is held back.
        plan = AudioPolicy.applicable(wanted, current: AudioSelection(output: tv, input: mic), bluetooth: ["bt"])
        XCTAssertEqual(plan.set, wanted); XCTAssertTrue(plan.kept.isEmpty)
        plan = AudioPolicy.applicable(AudioSelection(output: pods), current: AudioSelection(output: pods), bluetooth: ["bt"])
        XCTAssertEqual(plan.set, AudioSelection(output: pods)); XCTAssertTrue(plan.kept.isEmpty)
        // They were the default and have gone: the preset's output takes over, the input was never theirs.
        XCTAssertEqual(AudioPolicy.takeover(wanted, previous: AudioSelection(output: pods, input: mic), previousBluetooth: ["bt"], connected: ["spk", "mic", "tv"]), AudioSelection(output: speakers))
        // Still connected (the user chose another device), or the device that went was not Bluetooth: no takeover.
        XCTAssertTrue(AudioPolicy.takeover(wanted, previous: AudioSelection(output: pods), previousBluetooth: ["bt"], connected: ["bt", "spk"]).isEmpty)
        XCTAssertTrue(AudioPolicy.takeover(wanted, previous: AudioSelection(output: tv), previousBluetooth: [], connected: ["spk"]).isEmpty)
    }
}
