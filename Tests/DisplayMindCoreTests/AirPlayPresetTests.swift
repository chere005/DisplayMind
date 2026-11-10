import XCTest
@testable import DisplayMindCore
@testable import DisplayMind

/// A preset says which displays there are: one containing the AirPlay display connects its receiver, one without it stops the stream.
/// Everything here is a fake: a helper script, a fake Screen Mirroring and a fake list of AirPlay displays.
final class AirPlayPresetTests: XCTestCase {
    final class World: @unchecked Sendable {
        let lock = NSLock()
        var cast: [String: String] = [:], online: Set<String> = [], calls: [String] = []
        func read<T>(_ body: (World) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
    }
    let receiver = "plex’s Mac mini"
    var dir: URL!, data: URL!
    let world = World()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DisplayMind-airplay-tests-\(UUID())")
        data = dir.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    var laptop: DisplaySetting { DisplaySetting(id: displayA, name: "Laptop", mode: DisplayMode(width: 1920, height: 1080, hertz: 60)) }
    var television: DisplaySetting { DisplaySetting(id: displayB, name: "plex’s Mac mini (AirPlay)", mode: DisplayMode(width: 1920, height: 1080, hertz: 60), x: 1920) }
    var destination: AirPlayDestination { AirPlayDestination(receiverName: receiver, displayID: displayB) }

    /// Puts the fake displays in a state: with or without the AirPlay display.
    func set(casting: Bool) {
        let layout = casting ? [laptop, television] : [laptop]
        try? fixture(layout).write(to: dir.appendingPathComponent("current.txt"), atomically: true, encoding: .utf8)
        world.read { $0.cast = casting ? [displayB: self.receiver] : [:]; $0.online = Set(layout.map(\.id)) }
    }
    func backend() throws -> DisplayBackend {
        let script = """
        #!/bin/sh
        cd "$(dirname "$0")"
        if [ "$1" = list ]; then cat current.txt; exit 0; fi
        echo call >> calls.txt
        exit 0
        """
        let executable = dir.appendingPathComponent("fake-displayplacer")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var backend = DisplayBackend(helper: executable); backend.settle = 0.01; return backend
    }
    func helperApplies() -> Int { (try? String(contentsOf: dir.appendingPathComponent("calls.txt")).split(separator: "\n").count) ?? 0 }
    /// The fake Screen Mirroring: a press changes which displays exist, as the real one does.
    func toggle(_ target: AirPlayDestination, _ connecting: Bool) {
        world.read { $0.calls.append((connecting ? "connect " : "disconnect ") + target.receiverName) }
        set(casting: connecting)
    }
    @MainActor func makeStore(presets: [Preset]) throws -> Store {
        var settings = AppSettings(); settings.presets = presets
        try SettingsFile(directory: data).save(settings)
        let world = self.world, backend = try backend()
        let hardware = HardwareProvider(devices: { [] }, connectedDisplayIDs: { world.read { $0.online } }, nameDisplays: { $0 }, airPlayDisplays: { world.read { $0.cast } })
        let airPlay = AirPlayActions(authorized: { true }, requireAccess: {}, requestAccess: {}, receivers: { [] },
                                     setConnected: { target, connecting, before in try before(); self.toggle(target, connecting) })
        return Store(directory: data, backend: backend, hardware: hardware, airPlay: airPlay, audio: .demo, notifier: .none,
                     launchWatchdog: { directory in
                         Thread.detachNewThread {
                             RecoveryController(directory: directory).watch(backend: backend, disconnectAirPlay: { self.toggle($0, false) },
                                                                            connectAirPlay: { self.toggle($0, true) }, audio: .demo)
                         }
                     }, windowVisible: { false }, background: false)
    }
    @MainActor func tickUntil(_ store: Store, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(10)
        while !done() && Date() < end { await store.tick(); try? await Task.sleep(nanoseconds: 100_000_000) }
    }
    func journal() -> RecoveryJournal? { RecoveryController(directory: data).read() }

    func testAReceiverIsFoundByItsDisplayNameAndEitherApostrophe() throws {
        let listed = AirPlayReceiver(id: "screen-mirroring-device-AirPlay:1", name: receiver, selected: false)
        let other = AirPlayReceiver(id: "screen-mirroring-device-AirPlay:2", name: "Office TV", selected: false)
        for saved in ["plex’s Mac mini (AirPlay)", "plex's mac mini", " plex’s Mac mini "] {
            XCTAssertEqual(try AirPlaySelection.receiver(for: AirPlayDestination(receiverName: saved, displayID: displayB), in: [other, listed]), listed, saved)
        }
        XCTAssertNil(try AirPlaySelection.receiver(for: AirPlayDestination(receiverName: "plex’s Mac", displayID: displayB), in: [other, listed]))
        // The exact name wins over a merely similar one; two equally similar names are refused.
        let shouting = AirPlayReceiver(id: "screen-mirroring-device-AirPlay:3", name: "PLEX’S MAC MINI", selected: false)
        XCTAssertEqual(try AirPlaySelection.receiver(for: destination, in: [shouting, listed]), listed)
        XCTAssertThrowsError(try AirPlaySelection.receiver(for: AirPlayDestination(receiverName: "plex's mac mini", displayID: displayB), in: [shouting, listed]))
        XCTAssertEqual(AirPlaySelection.receiverName(fromDisplay: "plex’s Mac mini (AirPlay)"), receiver)
    }

    @MainActor func testAPresetWithoutTheAirPlayDisplayStopsTheStreamAndRevertBringsItBack() async throws {
        set(casting: true)
        let solo = Preset(name: "Solo Laptop", displays: [laptop], confirmed: true)
        let store = try makeStore(presets: [solo])
        await store.refresh()
        XCTAssertFalse(store.isActive(solo), "an extra AirPlay display means the solo layout is not what the displays show")
        await store.apply(solo)
        XCTAssertEqual(world.read { $0.calls }, ["disconnect \(receiver)"])
        XCTAssertEqual(journal()?.stoppedAirPlay, [destination])
        XCTAssertNotNil(store.pending); XCTAssertEqual(helperApplies(), 0, "with the stream gone the laptop already has the layout")
        XCTAssertTrue(store.isActive(solo))
        store.revert()
        await tickUntil(store) { !store.busy }
        XCTAssertEqual(world.read { $0.calls }, ["disconnect \(receiver)", "connect \(receiver)"])
        XCTAssertEqual(world.read { $0.online }, [displayA, displayB])
        XCTAssertNil(RecoveryController(directory: data).result()?.error)
        XCTAssertNil(store.menuError); XCTAssertEqual(store.airPlayOnline, [displayB: receiver])
    }

    @MainActor func testKeepingTheChangeLeavesTheStreamStopped() async throws {
        set(casting: true)
        let solo = Preset(name: "Solo Laptop", displays: [laptop], confirmed: true)
        let store = try makeStore(presets: [solo])
        await store.apply(solo)
        store.keep()
        XCTAssertNil(store.pending); XCTAssertNil(journal())
        XCTAssertEqual(world.read { $0.calls }, ["disconnect \(receiver)"])
        XCTAssertEqual(world.read { $0.online }, [displayA])
    }

    @MainActor func testAPresetContainingTheAirPlayDisplayConnectsItWithoutBeingTold() async throws {
        // Captured while casting, before presets linked their receiver by themselves.
        set(casting: true)
        let casted = Preset(name: "Casted", displays: [laptop, television], confirmed: true)
        let store = try makeStore(presets: [casted])
        await store.refresh()
        XCTAssertEqual(store.settings.presets[0].airPlay, destination)
        XCTAssertTrue(store.settings.presets[0].confirmed)
        XCTAssertEqual(try SettingsFile(directory: data).load().presets[0].airPlay, destination)
        // The stream is stopped elsewhere; the preset is still usable and brings it back.
        set(casting: false)
        await store.refresh()
        XCTAssertNil(store.unavailable(store.settings.presets[0]))
        await store.apply(store.settings.presets[0])
        XCTAssertEqual(world.read { $0.calls }, ["connect \(receiver)"])
        XCTAssertEqual(journal()?.startedAirPlay, destination)
        XCTAssertNotNil(store.pending); XCTAssertEqual(world.read { $0.online }, [displayA, displayB])
    }

    @MainActor func testTurningTheLinkOffIsRespectedAndADisplayNameIsCorrectedToTheReceiver() async throws {
        set(casting: true)
        var byHand = Preset(name: "By hand", displays: [laptop, television], confirmed: true); byHand.manualAirPlay = true
        let named = Preset(name: "Named after the display", displays: [laptop, television], confirmed: true,
                           airPlay: AirPlayDestination(receiverName: "plex’s Mac mini (AirPlay)", displayID: displayB))
        let store = try makeStore(presets: [byHand, named])
        await store.refresh()
        XCTAssertNil(store.settings.presets[0].airPlay)
        XCTAssertEqual(store.settings.presets[1].airPlay, destination)
        XCTAssertTrue(store.settings.presets[1].confirmed)
    }

    @MainActor func testCapturingWhileCastingLinksTheReceiverAndStaysConfirmed() async throws {
        set(casting: true)
        let store = try makeStore(presets: [])
        await store.capture()
        let captured = try XCTUnwrap(store.editorPreset)
        XCTAssertEqual(captured.airPlay, destination)
        store.save(captured)
        XCTAssertEqual(store.settings.presets.first?.airPlay, destination)
        XCTAssertEqual(store.settings.presets.first?.confirmed, true)
    }
}
