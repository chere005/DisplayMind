import AppKit
import Combine
import DisplayMindCore
import ServiceManagement

@MainActor final class Store: ObservableObject {
    @Published var settings = AppSettings()
    @Published var displays: [ConnectedDisplay] = []
    @Published var devices: [Device] = []
    @Published var busy = false
    @Published var error: String?
    @Published var status = "Reading connected displays…"
    @Published var pending: PendingChange? { didSet { syncTimers() } }
    @Published var secondsRemaining = 10
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var selectedPresetID: UUID?
    @Published var showRules = false
    @Published var editorPreset: Preset? { didSet { if editorPreset != nil { refreshAuthorization() } } }
    @Published var editorRule: ConnectionRule?
    @Published var airPlayReceivers: [AirPlayReceiver] = []
    @Published var airPlayScanning = false
    @Published var airPlayAuthorized = false
    /// Connected displays that are AirPlay receivers: display UUID → the receiver's own name, as Screen Mirroring lists it.
    @Published var airPlayOnline: [String: String] = [:]
    /// The last error raised while no window was visible; shown in the menu until dismissed.
    @Published var menuError: String?
    let settingsFile: SettingsFile
    let backend: DisplayBackend
    let recovery: RecoveryController
    let hardware: HardwareProvider
    let airPlay: AirPlayActions
    let audio: AudioActions
    let notifier: Notifier
    var launchWatchdog: (URL) throws -> Void
    var windowVisible: @MainActor () -> Bool
    /// How long a device set must stay unchanged before rules run.
    var settle: TimeInterval = 3
    var openWindow: (() -> Void)?
    /// How long Revert is offered after a preset is applied by hand. When it ends the change stays (Sean, 2026-11-10: no automatic switch back).
    var revertWindow: TimeInterval = 10
    /// The journal outlives the window by this much, so the app closes it first and the watchdog only finishes the job if the app is gone.
    static let revertGrace: TimeInterval = 3
    /// Safety net in case a change notification is missed.
    static let fallbackInterval: TimeInterval = 60
    /// Quiet time after the last change event before devices are first read, so dock bursts become one evaluation.
    var coalesce: TimeInterval = 0.25
    private var gate = ConnectionGate()
    private var ticker: Timer?, debounce: Timer?, fallback: Timer?
    private var monitorToken: AnyObject?
    private let scheduling: Bool
    private var changeCount = 0
    /// A change (or launch/rule edit) has not yet been evaluated; the settle window is open.
    private var dirty = false { didSet { syncTimers() } }
    /// The sound devices as last seen settled, to tell a Bluetooth device going away from the user choosing another device.
    private var soundSeen = AudioSelection(), bluetoothSeen: Set<String> = []
    private var soundToken: AnyObject?, soundDebounce: Timer?
    /// A burst of CoreAudio changes (the default moves, then the device leaves the list) is read once, after this quiet time.
    var soundSettle: TimeInterval = 1
    /// The preset applied last; while its layout is the active one, its sound devices take over from Bluetooth.
    private var lastAppliedID: UUID?
    private var lastDevices: Set<String> = []
    /// The displays were reconfigured since the layout was last read, so "active preset" may be out of date.
    private var layoutStale = false
    private var polling = false
    private var writable = true
    private var applyFailure: String?
    /// A failed recovery has been shown but the user has not dismissed it; it stays unacknowledged on disk (and the status stays) until they do.
    private var recoveryUnacknowledged = false
    private var recoveryID: UUID? { didSet { syncTimers() } }
    /// True while a countdown, recovery wait, settle window or pending coalesced change needs timer wake-ups (the 60 s fallback does not count).
    static let attention = "Display recovery needs attention"
    var isTicking: Bool { ticker != nil || debounce != nil }

    struct PendingChange { var journal: RecoveryJournal; var preset: Preset }

    /// `background: false` skips the monitor, timers and first refresh so tests can drive `refresh()` / `tick()` directly; a `monitor` passed explicitly (a fake) turns the event-driven scheduling on.
    init(directory: URL = DataFolder.resolve(), demo: Bool = false,
         backend: DisplayBackend = DisplayBackend(), hardware: HardwareProvider = .live, airPlay: AirPlayActions = .live, audio: AudioActions = .live, notifier: Notifier = .live,
         launchWatchdog: @escaping (URL) throws -> Void = RecoveryController.launchWatchdog,
         windowVisible: @escaping @MainActor () -> Bool = mainWindowVisible, background: Bool = true, monitor: HardwareMonitor? = nil) {
        scheduling = background || monitor != nil
        settingsFile = SettingsFile(directory: directory)
        recovery = RecoveryController(directory: directory)
        self.backend = backend; self.hardware = hardware; self.airPlay = airPlay
        let audio = demo ? AudioActions.demo : audio
        self.audio = audio
        self.notifier = demo ? .none : notifier
        self.launchWatchdog = launchWatchdog; self.windowVisible = windowVisible
        airPlayAuthorized = airPlay.authorized()
        if demo { loadDemo(); return }
        do { settings = try settingsFile.load() } catch {
            failAtLaunch("Settings could not be opened: \(error.localizedDescription)")
            writable = false
        }
        selectedPresetID = settings.presets.first?.id
        let recovery = self.recovery, disconnect: (AirPlayDestination) throws -> Void = { try airPlay.setConnected($0, false, {}) }
        let connect: (AirPlayDestination) throws -> Void = { target in
            try AirPlayConnection.ensure(target, online: hardware.connectedDisplayIDs, start: { try airPlay.setConnected(target, true, {}) })
        }
        // A verified change whose revert window was open when the app went away stays; only an apply that never finished is rolled back.
        if let journal = recovery.read(), journal.keepWhenDue == true { try? recovery.keep(id: journal.id) }
        if let journal = recovery.read() {
            recoveryID = journal.id
            busy = true
            try? recovery.requestRevert()
            Task.detached { recovery.watch(backend: backend, disconnectAirPlay: disconnect, connectAirPlay: connect, audio: audio) }
        } else if let orphan = recovery.orphanedRestore() {
            // The watchdog died after claiming the journal: finish the restore, verified and reported through tick().
            recoveryID = orphan.id
            busy = true
            status = "Restoring previous layout…"
            Task.detached { recovery.resume(orphan, backend: backend, disconnectAirPlay: disconnect, connectAirPlay: connect, audio: audio) }
        } else if let result = recovery.result(), let failure = result.error, result.acknowledged != true {
            status = Self.attention
            recoveryUnacknowledged = true
            failAtLaunch("A display recovery that ran while DisplayMind was closed failed. " + failure)
        }
        if recovery.takeStaleUnsettledRestore() != nil {
            status = Self.attention
            failAtLaunch("The previous display layout was not restored. Open Display Settings to choose the layout you want.")
        }
        guard scheduling else { return }
        noteSound()
        soundToken = audio.watch { [weak self] in Task { @MainActor in self?.soundEvent() } }
        monitorToken = (monitor ?? .live).start { [weak self] change in self?.hardwareChanged(change) }
        fallback = Timer.scheduledTimer(withTimeInterval: Self.fallbackInterval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            Task { @MainActor in self.changed() }
        }
        dirty = true
        if background { Task { await refresh(); await tick() } } else { changed() }
    }

    private func hardwareChanged(_ change: HardwareChange) {
        if change == .wake { gate.reset() }
        if change != .usb { layoutStale = true }   // an arrangement change keeps the same device set
        changed()
    }
    /// Schedules one device evaluation after a quiet `coalesce` period; the settle window then runs on the 1 s ticker.
    private func changed() {
        changeCount += 1
        dirty = true
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: coalesce, repeats: false) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.debounce = nil; self.syncTimers(); await self.tick(); self.syncTimers() }
        }
    }
    /// The 1 s ticker runs only while a countdown, recovery wait or settle window is open.
    private func syncTimers() {
        guard scheduling else { return }
        let needed = pending != nil || recoveryID != nil || (dirty && debounce == nil)
        if needed && ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                Task { @MainActor in await self.tick() }
            }
        } else if !needed { ticker?.invalidate(); ticker = nil }
    }
    /// Accessibility trust changes only in System Settings, so read it when the app is activated, an editor opens, or a related button is pressed.
    func refreshAuthorization() { airPlayAuthorized = airPlay.authorized() }

    var connectedIDs: Set<String> { Set(displays.map(\.id)) }
    var selectedPreset: Preset? { settings.presets.first { $0.id == selectedPresetID } }
    var knownDevices: [Device] {
        let stored = settings.rules.flatMap { $0.requiredDevices + $0.absentDevices }
        return Array(Dictionary((stored + devices).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }).values).sorted { $0.name < $1.name }
    }
    func unavailable(_ preset: Preset) -> String? { Configuration.availability(preset, connected: connectedIDs) }
    /// The displays show exactly this preset's layout right now.
    func isActive(_ preset: Preset) -> Bool {
        Set(preset.displays.map(\.id)) == connectedIDs && Configuration.matches(preset.displays, actual: displays.map(\.setting))
    }
    private var idleStatus: String {
        if let active = settings.presets.first(where: isActive) { return "\(active.name) is active" }
        return "\(displays.count) display\(displays.count == 1 ? "" : "s") connected"
    }
    func report(_ error: Error) { fail(error.localizedDescription) }
    /// With the window open the message is an alert; otherwise it is a menu line plus a notification, with no stale alert later.
    func fail(_ message: String) {
        if windowVisible() { error = message } else { menuError = message; notifier.post("DisplayMind", message) }
    }
    /// Launch runs before any window exists: the message also goes to `error` so the window shows the alert when it opens.
    private func failAtLaunch(_ message: String) {
        error = message; menuError = message
        notifier.post("DisplayMind", message)
    }
    private func rearm() { gate.reset(); if scheduling { changed() } }
    func dismissMenuError() { menuError = nil; dismissedFailure() }
    func dismissError() { error = nil; dismissedFailure() }
    /// The user has seen a recovery failure: only now is it acknowledged on disk.
    private func dismissedFailure() {
        guard recoveryUnacknowledged else { return }
        recoveryUnacknowledged = false
        recovery.acknowledge()
        error = nil; menuError = nil
        if status == Self.attention { status = idleStatus }
    }
    func allowAirPlayControl() {
        airPlay.requestAccess()
        airPlayAuthorized = airPlay.authorized()
    }
    func findAirPlayReceivers() async {
        guard !busy, !airPlayScanning, pending == nil else { return }
        airPlayAuthorized = airPlay.authorized()
        guard airPlayAuthorized else { allowAirPlayControl(); return }
        airPlayScanning = true
        defer { airPlayScanning = false }
        do {
            let receivers = airPlay.receivers
            airPlayReceivers = try await Task.detached { try receivers() }.value
            if airPlayReceivers.isEmpty { fail("No AirPlay receivers are visible in Screen Mirroring. You can enter a receiver’s exact name instead.") }
        } catch { report(error) }
    }
    func defaultRuleDevices(for preset: Preset) -> [Device] {
        devices.filter { $0.kind == .display && $0.id != "display:\(preset.airPlay?.displayID ?? "")" }
    }
    private func noteSound() { soundSeen = audio.current(); bluetoothSeen = audio.bluetooth() }
    private func soundEvent() {
        soundDebounce?.invalidate()
        soundDebounce = Timer.scheduledTimer(withTimeInterval: soundSettle, repeats: false) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.soundDebounce = nil; await self.soundChanged() }
        }
    }
    /// The preset whose sound devices apply now: the one applied last while its layout is still the active one, else any preset with that layout.
    private var soundPreset: Preset? {
        settings.presets.first { $0.id == lastAppliedID && $0.audio != nil && isActive($0) } ?? settings.presets.first { $0.audio != nil && isActive($0) }
    }
    /// The sound devices changed. If the Bluetooth device that was the default has gone, the active preset's device takes over
    /// instead of whatever macOS fell back to. Any other change is the user's and is only noted.
    func soundChanged() async {
        let audio = self.audio
        let (now, bluetooth, connected) = await Task.detached { (audio.current(), audio.bluetooth(), Set((audio.outputs() + audio.inputs()).map(\.uid))) }.value
        let previous = soundSeen, previousBluetooth = bluetoothSeen
        soundSeen = now; bluetoothSeen = bluetooth
        guard !busy, let preset = soundPreset, let wanted = preset.audio else { return }
        let takeover = AudioPolicy.takeover(wanted, previous: previous, previousBluetooth: previousBluetooth, connected: connected)
        guard !takeover.isEmpty, takeover.differs(from: now) else { return }
        do {
            let missing = try await Task.detached { try audio.set(takeover) }.value
            noteSound()
            let moved = [takeover.output, takeover.input].compactMap { $0 }.filter { !missing.contains($0.name) }.map(\.name)
            if !moved.isEmpty, pending == nil { status = "Bluetooth disconnected: sound moved to " + moved.joined(separator: " and ") + " (\(preset.name))" }
        } catch { fail(error.localizedDescription) }
    }
    /// Sets the preset's sound devices. A side on Bluetooth headphones stays with them; the preset's device takes over when they disconnect.
    /// A CoreAudio error is reported but never reverts the layout; returns a note about devices left alone or not connected.
    private func applySound(_ preset: Preset) async -> String? {
        guard let saved = preset.audio, !saved.isEmpty else { return nil }
        let audio = self.audio
        do {
            let (missing, kept) = try await Task.detached { () -> ([String], [AudioDevice]) in
                let plan = AudioPolicy.applicable(saved, current: audio.current(), bluetooth: audio.bluetooth())
                return (plan.set.isEmpty ? [] : try audio.set(plan.set), plan.kept)
            }.value
            noteSound()
            var notes: [String] = []
            if !kept.isEmpty { notes.append("Sound stays on " + Array(Set(kept.map(\.name))).sorted().joined(separator: ", ") + " while it is connected.") }
            if !missing.isEmpty { notes.append("Sound device not connected: " + missing.joined(separator: ", ") + ".") }
            return notes.isEmpty ? nil : notes.joined(separator: " ")
        } catch { fail(error.localizedDescription); return nil }
    }
    private func persist(_ updated: AppSettings) -> Bool {
        guard writable else { fail("The existing settings file could not be read. It has been preserved; use Open data folder to see it."); return false }
        do { try settingsFile.save(updated); settings = updated; return true }
        catch { report(error); return false }
    }
    func refresh() async {
        do {
            let backend = self.backend
            let current = try await Task.detached { try backend.read() }.value
            displays = hardware.nameDisplays(current)
            airPlayOnline = hardware.airPlayDisplays()
            adoptDisplayNames()
            adoptAirPlay()
            if pending == nil && !busy && !recoveryUnacknowledged { status = idleStatus }
        } catch { report(error) }
    }
    func capture() async {
        guard !busy, pending == nil else { return }
        busy = true
        defer { busy = false }
        do {
            let backend = self.backend
            let current = try await Task.detached { try backend.read() }.value
            displays = hardware.nameDisplays(current)
            airPlayOnline = hardware.airPlayDisplays()
            let cast = displays.first { airPlayOnline[$0.id] != nil }.map { AirPlayDestination(receiverName: receiverName(for: $0.setting), displayID: $0.id) }
            editorPreset = Preset(name: "Preset \(settings.presets.count + 1)", displays: displays.map(\.setting), confirmed: true, airPlay: cast,
                                  audio: Optional(audio.current()).flatMap { $0.isEmpty ? nil : $0 })
        } catch { report(error) }
    }
    func save(_ preset: Preset) {
        do { try Configuration.validate(preset) } catch { report(error); return }
        if let target = preset.airPlay, displays.contains(where: { $0.id == target.displayID && $0.builtIn }) {
            fail("Choose the receiver's display as the saved AirPlay display, rather than the Mac's built-in display.")
            return
        }
        var preset = preset
        preset.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preset.name.isEmpty else { fail("Give this preset a name."); return }
        var updated = settings
        if let i = updated.presets.firstIndex(where: { $0.id == preset.id }) {
            // The editor's draft may already say unconfirmed; only a layout change (not a rename) may withdraw confirmation.
            let stored = updated.presets[i]
            preset.confirmed = Configuration.sameLayout(preset.displays, stored.displays) && preset.airPlay == stored.airPlay && stored.confirmed
            updated.presets[i] = preset
        } else {
            // A layout captured as it stands is proven, including one captured while its receiver was connected.
            let castOnline = preset.airPlay.map { airPlayOnline[$0.displayID] != nil } ?? true
            preset.confirmed = preset.confirmed && castOnline && Configuration.matches(preset.displays, actual: displays.map(\.setting))
            updated.presets.append(preset)
        }
        if persist(updated) { selectedPresetID = preset.id; showRules = false; editorPreset = nil; rearm() }
    }
    /// A new name never touches the layout, so the preset keeps its confirmation and its rules.
    @discardableResult func rename(_ preset: Preset, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = settings.presets.firstIndex(where: { $0.id == preset.id }) else { return false }
        guard settings.presets[i].name != name else { return true }
        var updated = settings
        updated.presets[i].name = name
        guard persist(updated) else { return false }
        if pending == nil && !busy && !recoveryUnacknowledged { status = idleStatus }
        return true
    }
    /// The name Screen Mirroring lists for the receiver behind a display.
    func receiverName(for display: DisplaySetting) -> String {
        airPlayOnline[display.id].flatMap { $0.isEmpty ? nil : $0 } ?? AirPlaySelection.receiverName(fromDisplay: display.name)
    }
    /// A preset that contains an AirPlay display connects its receiver when applied, without being told to: that is what the preset shows.
    /// A saved receiver name that is really the display's name ("… (AirPlay)") is corrected to the receiver's.
    private func adoptAirPlay() {
        guard writable, !airPlayOnline.isEmpty else { return }
        var updated = settings
        for p in updated.presets.indices {
            let preset = updated.presets[p]
            if let target = preset.airPlay {
                if let receiver = airPlayOnline[target.displayID], !receiver.isEmpty, receiver != target.receiverName, target.controlIdentifier == nil,
                   AirPlaySelection.normalized(receiver) == AirPlaySelection.normalized(target.receiverName) {
                    updated.presets[p].airPlay?.receiverName = receiver
                }
            } else if preset.manualAirPlay != true, let display = preset.displays.first(where: { $0.enabled && airPlayOnline[$0.id] != nil }) {
                updated.presets[p].airPlay = AirPlayDestination(receiverName: receiverName(for: display), displayID: display.id)
            }
        }
        if updated != settings { _ = persist(updated) }
    }
    /// A preset captured while macOS had no name for a display (a mirror) holds a placeholder such as "External display 2".
    /// Once the display reports its real name, the presets and rules that mention it take that name.
    private func adoptDisplayNames() {
        let real = Dictionary(displays.filter { !DisplayParser.isPlaceholder($0.setting.name) }.map { ($0.id, $0.setting.name) }, uniquingKeysWith: { first, _ in first })
        guard writable, !real.isEmpty else { return }
        var updated = settings
        for p in updated.presets.indices {
            for d in updated.presets[p].displays.indices {
                let display = updated.presets[p].displays[d]
                if DisplayParser.isPlaceholder(display.name), let name = real[display.id] { updated.presets[p].displays[d].name = name }
            }
        }
        func named(_ device: Device) -> Device {
            guard device.kind == .display, DisplayParser.isPlaceholder(device.name), let name = real[String(device.id.dropFirst("display:".count))] else { return device }
            return Device(id: device.id, name: name, kind: device.kind)
        }
        for r in updated.rules.indices {
            updated.rules[r].requiredDevices = updated.rules[r].requiredDevices.map(named)
            updated.rules[r].absentDevices = updated.rules[r].absentDevices.map(named)
        }
        if updated != settings { _ = persist(updated) }
    }
    func duplicate(_ preset: Preset) {
        var copy = preset; copy.id = UUID(); copy.name += " copy"
        editorPreset = copy
    }
    func delete(_ preset: Preset) {
        var updated = settings
        updated.presets.removeAll { $0.id == preset.id }
        updated.rules.removeAll { $0.presetID == preset.id }
        if persist(updated) { selectedPresetID = settings.presets.first?.id; rearm() }
    }
    func saveRule(_ rule: ConnectionRule) {
        guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rule.requiredDevices.isEmpty || !rule.absentDevices.isEmpty,
              settings.presets.contains(where: { $0.id == rule.presetID }) else { fail("Choose a preset, a name, and at least one connection condition."); return }
        var updated = settings
        if let i = updated.rules.firstIndex(where: { $0.id == rule.id }) { updated.rules[i] = rule } else { updated.rules.append(rule) }
        if persist(updated) { editorRule = nil; rearm() }
    }
    func deleteRule(_ rule: ConnectionRule) {
        var updated = settings; updated.rules.removeAll { $0.id == rule.id }
        if persist(updated) { rearm() }
    }
    func moveRule(_ rule: ConnectionRule, by offset: Int) {
        guard let i = settings.rules.firstIndex(where: { $0.id == rule.id }), settings.rules.indices.contains(i + offset) else { return }
        var updated = settings; updated.rules.swapAt(i, i + offset)
        if persist(updated) { rearm() }
    }
    func toggleAutomation(_ enabled: Bool) {
        var updated = settings; updated.automationEnabled = enabled
        if persist(updated) { rearm() }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { report(error) }
    }

    func apply(_ preset: Preset, automatic: Bool = false) async {
        guard !busy, !airPlayScanning, pending == nil else { return }
        busy = true
        applyFailure = nil
        status = "Applying \(preset.name)…"
        do {
            let backend = self.backend, hardware = self.hardware, airPlay = self.airPlay
            try Configuration.validate(preset)
            lastAppliedID = preset.id
            let soundBefore = audio.current()
            let current = try await Task.detached { try backend.read() }.value
            let cast = hardware.airPlayDisplays()
            airPlayOnline = cast
            if let reason = Configuration.availability(preset, connected: Set(current.map(\.id))) { throw DisplayMindError(reason) }
            _ = try Configuration.arguments(for: preset.displays)
            // The preset says which displays there are. An AirPlay display it has no place for is a stream to stop.
            let wanted = Set(preset.displays.map(\.id))
            let stale = current.filter { cast[$0.id] != nil && !wanted.contains($0.id) }.map { display in
                AirPlayDestination(receiverName: cast[display.id].flatMap { $0.isEmpty ? nil : $0 } ?? AirPlaySelection.receiverName(fromDisplay: display.setting.name), displayID: display.id)
            }
            if stale.isEmpty, Configuration.matches(preset.displays, actual: current.map(\.setting)) {
                if !preset.confirmed { confirm(preset.id) }
                var note: String?
                if let wanted = preset.audio, wanted.differs(from: soundBefore) { note = await applySound(preset) }
                status = "\(preset.name) is active" + (note.map { ". " + $0 } ?? "")
                if automatic, let note { notifier.post("DisplayMind", "\(preset.name): " + note) }
                busy = false
                return
            }
            let needsAirPlay = preset.airPlay.map { target in !current.contains(where: { $0.id == target.displayID }) } ?? false
            let usesAirPlay = needsAirPlay || !stale.isEmpty
            if usesAirPlay { try airPlay.requireAccess() }
            var journal = try recovery.arm(previous: current.map(\.setting), previousAudio: preset.audio.flatMap { soundBefore.limited(to: $0) }, setupTimeout: usesAirPlay ? 240 : 120, launch: launchWatchdog)
            recoveryID = journal.id
            let recovery = self.recovery, changeID = journal.id
            for target in stale {
                status = "Disconnecting AirPlay from \(target.receiverName)…"
                try recovery.markAirPlayStopped(id: changeID, target: target)   // recorded first, so a revert reconnects it
                try await Task.detached { try airPlay.setConnected(target, false, {}) }.value
            }
            if needsAirPlay, let target = preset.airPlay {
                status = "Connecting AirPlay to \(target.receiverName)…"
                try await Task.detached {
                    try AirPlayConnection.ensure(target, online: hardware.connectedDisplayIDs, start: {
                        try airPlay.setConnected(target, true, {
                            try recovery.markAirPlayStarted(id: changeID, target: target)
                        })
                    })
                }.value
            }
            status = "Applying \(preset.name)…"
            var connected = current
            if usesAirPlay { connected = try await Task.detached { try backend.read() }.value }
            if let reason = Configuration.availability(preset, connected: Set(connected.map(\.id)), allowAirPlayConnection: false) { throw DisplayMindError(reason) }
            var actual = connected
            if !Configuration.matches(preset.displays, actual: connected.map(\.setting)) {
                actual = try await Task.detached {
                    try backend.applyVerified(preset.displays, rejected: "macOS did not accept every setting in this preset.")
                }.value
            }
            displays = hardware.nameDisplays(actual)
            airPlayOnline = hardware.airPlayDisplays()
            let note = await applySound(preset)
            if automatic {
                try recovery.keep(id: journal.id)
                recoveryID = nil
                let suffix = note.map { ". " + $0 } ?? ""
                status = "Automatically applied \(preset.name)" + suffix
                notifier.post("DisplayMind", "Automatically applied \(preset.name)" + suffix)
                gate.consume(hardware.devices(), now: Date())
                busy = false
            } else {
                journal.deadline = Date().addingTimeInterval(revertWindow)
                try recovery.openRevertWindow(id: journal.id, until: journal.deadline.addingTimeInterval(Self.revertGrace))
                pending = PendingChange(journal: journal, preset: preset)
                secondsRemaining = Int(revertWindow.rounded(.up))
                status = "Applied \(preset.name). Revert within \(secondsRemaining) seconds if it is wrong." + (note.map { " " + $0 } ?? "")
                busy = false
                openWindow?()
            }
        } catch {
            if recoveryID != nil {
                applyFailure = error.localizedDescription
                status = "Restoring previous layout…"
                try? recovery.requestRevert()
            } else { busy = false; report(error); status = "Preset could not be applied" }
        }
    }
    func keep() {
        guard let pending else { return }
        do {
            try recovery.keep(id: pending.journal.id)
            confirm(pending.preset.id)
            status = "\(pending.preset.name) is active"
            gate.consume(hardware.devices(), now: Date())
            self.pending = nil; recoveryID = nil
        } catch { report(error) }
    }
    private func confirm(_ id: UUID) {
        var updated = settings
        if let i = updated.presets.firstIndex(where: { $0.id == id }) { updated.presets[i].confirmed = true; _ = persist(updated) }
    }
    func revert() {
        busy = true; status = "Restoring previous layout…"; pending = nil
        do { try recovery.requestRevert() } catch { busy = false; report(error) }
    }
    func tick() async {
        let seen = changeCount
        defer { syncTimers() }
        if let pending {
            secondsRemaining = max(0, Int(ceil(pending.journal.deadline.timeIntervalSinceNow)))
            if pending.journal.deadline <= Date() { keep() }   // not reverted in its window: the change stays
        }
        if let id = recoveryID, let result = recovery.result(), result.id == id {
            recoveryID = nil; pending = nil; busy = false
            lastAppliedID = nil   // the preset did not stay
            noteSound()
            status = result.error == nil ? "Previous layout restored" : Self.attention
            if let failure = result.error { recoveryUnacknowledged = true; fail(failure) }
            else if let failure = applyFailure { fail(failure + " The previous layout was restored.") }
            applyFailure = nil
            await refresh()
            gate.consume(hardware.devices(), now: Date())
        }
        guard !polling, !busy, !airPlayScanning, pending == nil else { return }   // dirty stays set, so the ticker retries
        polling = true
        defer { polling = false }
        let devicesNow = hardware.devices
        let found = await Task.detached { devicesNow() }.value
        devices = found.map { device in
            var copy = device
            if device.kind == .display, let display = displays.first(where: { "display:\($0.id)" == device.id }) { copy.name = display.setting.name }
            return copy
        }
        let ids = Set(devices.map(\.id))
        if ids != lastDevices || layoutStale { lastDevices = ids; layoutStale = false; await refresh() }
        let due = gate.shouldEvaluate(devices, now: Date(), settle: settle)
        dirty = scheduling && (gate.isPending(devices) || changeCount != seen)
        guard due, writable,
              let rule = RuleEngine.match(settings: settings, devices: devices),
              let preset = settings.presets.first(where: { $0.id == rule.presetID }) else { return }
        await apply(preset, automatic: true)
    }
    func loadDemo() {
        let a = DisplaySetting(id: "00000000-0000-0000-0000-000000000001", name: "Studio Display", mode: DisplayMode(width: 2560, height: 1440, hertz: 60, scaled: true))
        let b = DisplaySetting(id: "00000000-0000-0000-0000-000000000002", name: "Portrait display", mode: DisplayMode(width: 1080, height: 1920, hertz: 60), rotation: 90, x: 2560)
        let c = DisplaySetting(id: "00000000-0000-0000-0000-000000000003", name: "Built-in display", mode: DisplayMode(width: 1512, height: 982, hertz: 120, scaled: true), x: 400, y: 1440)
        let preset = Preset(name: "At my desk", displays: [a,b,c], confirmed: true,
                            audio: AudioSelection(output: AudioDevice(uid: "demo-display", name: "Studio Display Speakers"), input: AudioDevice(uid: "demo-mic", name: "MacBook Pro Microphone")))
        var laptop = c; laptop.x = 0; laptop.y = 0
        settings.presets = [preset, Preset(name: "Presentation", displays: [a], confirmed: true), Preset(name: "Just the laptop", displays: [laptop], confirmed: true)]
        displays = [a,b,c].map { ConnectedDisplay(setting: $0, modes: [$0.mode]) }
        devices = [a,b,c].map { Device(id: "display:\($0.id)", name: $0.name, kind: .display) } + [Device(id: "usb:demo", name: "Desk dock", kind: .usb)]
        settings.rules = [ConnectionRule(name: "When I dock", presetID: preset.id, requiredDevices: [devices.last!])]
        selectedPresetID = preset.id; status = "3 displays connected"
    }
}
