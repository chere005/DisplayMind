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
    @Published var pending: PendingChange?
    @Published var secondsRemaining = 20
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var selectedPresetID: UUID?
    @Published var showRules = false
    @Published var editorPreset: Preset?
    @Published var editorRule: ConnectionRule?
    @Published var airPlayReceivers: [AirPlayReceiver] = []
    @Published var airPlayScanning = false
    @Published var airPlayAuthorized = AirPlayController.authorized
    let settingsFile: SettingsFile
    let backend: DisplayBackend
    let recovery: RecoveryController
    var openWindow: (() -> Void)?
    private var gate = ConnectionGate()
    private var timer: Timer?
    private var lastDevices: Set<String> = []
    private var polling = false
    private var writable = true
    private var wakeObserver: NSObjectProtocol?
    private var applyFailure: String?
    private var recoveryID: UUID?

    struct PendingChange { var journal: RecoveryJournal; var preset: Preset }

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("DisplayMind"), demo: Bool = false) {
        settingsFile = SettingsFile(directory: directory)
        recovery = RecoveryController(directory: directory)
        backend = DisplayBackend()
        if demo { loadDemo(); return }
        do { settings = try settingsFile.load() } catch {
            self.error = "Settings could not be opened: \(error.localizedDescription)"
            writable = false
        }
        selectedPresetID = settings.presets.first?.id
        if let journal = recovery.read() {
            recoveryID = journal.id
            busy = true
            try? recovery.requestRevert()
            let recovery = self.recovery, backend = self.backend
            Task.detached { recovery.watch(backend: backend) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.gate.reset() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await refresh(); await tick() }
    }

    var connectedIDs: Set<String> { Set(displays.map(\.id)) }
    var selectedPreset: Preset? { settings.presets.first { $0.id == selectedPresetID } }
    var knownDevices: [Device] {
        let stored = settings.rules.flatMap { $0.requiredDevices + $0.absentDevices }
        return Array(Dictionary((stored + devices).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }).values).sorted { $0.name < $1.name }
    }
    func unavailable(_ preset: Preset) -> String? { Configuration.availability(preset, connected: connectedIDs) }
    func report(_ error: Error) { self.error = error.localizedDescription }
    func allowAirPlayControl() {
        AirPlayController.requestAccess()
        airPlayAuthorized = AirPlayController.authorized
    }
    func findAirPlayReceivers() async {
        guard !busy, !airPlayScanning, pending == nil else { return }
        airPlayAuthorized = AirPlayController.authorized
        guard airPlayAuthorized else { allowAirPlayControl(); return }
        airPlayScanning = true
        defer { airPlayScanning = false }
        do {
            airPlayReceivers = try await Task.detached { try AirPlayController().receivers() }.value
            if airPlayReceivers.isEmpty { error = "No AirPlay receivers are visible in Screen Mirroring. You can enter a receiver’s exact name instead." }
        } catch { report(error) }
    }
    func defaultRuleDevices(for preset: Preset) -> [Device] {
        devices.filter { $0.kind == .display && $0.id != "display:\(preset.airPlay?.displayID ?? "")" }
    }
    private func persist(_ updated: AppSettings) -> Bool {
        guard writable else { error = "The existing settings file could not be read. It has been preserved in ~/DisplayMind."; return false }
        do { try settingsFile.save(updated); settings = updated; return true }
        catch { report(error); return false }
    }
    func refresh() async {
        do {
            let backend = self.backend
            let current = try await Task.detached { try backend.read() }.value
            displays = Hardware.nameDisplays(current)
            if pending == nil && !busy { status = "\(current.count) display\(current.count == 1 ? "" : "s") connected" }
        } catch { report(error) }
    }
    func capture() async {
        guard !busy, pending == nil else { return }
        busy = true
        defer { busy = false }
        do {
            let backend = self.backend
            let current = try await Task.detached { try backend.read() }.value
            displays = Hardware.nameDisplays(current)
            editorPreset = Preset(name: "Preset \(settings.presets.count + 1)", displays: displays.map(\.setting), confirmed: true)
        } catch { report(error) }
    }
    func save(_ preset: Preset) {
        do { try Configuration.validate(preset) } catch { report(error); return }
        if let target = preset.airPlay, displays.contains(where: { $0.id == target.displayID && $0.builtIn }) {
            error = "Choose the receiver's display as the saved AirPlay display, rather than the Mac's built-in display."
            return
        }
        var preset = preset
        preset.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preset.name.isEmpty else { error = "Give this preset a name."; return }
        var updated = settings
        if let i = updated.presets.firstIndex(where: { $0.id == preset.id }) {
            if preset.displays != updated.presets[i].displays || preset.airPlay != updated.presets[i].airPlay { preset.confirmed = false }
            updated.presets[i] = preset
        } else {
            preset.confirmed = preset.confirmed && preset.airPlay == nil && Configuration.matches(preset.displays, actual: displays.map(\.setting))
            updated.presets.append(preset)
        }
        if persist(updated) { selectedPresetID = preset.id; showRules = false; editorPreset = nil; gate.reset() }
    }
    func duplicate(_ preset: Preset) {
        var copy = preset; copy.id = UUID(); copy.name += " copy"
        editorPreset = copy
    }
    func delete(_ preset: Preset) {
        var updated = settings
        updated.presets.removeAll { $0.id == preset.id }
        updated.rules.removeAll { $0.presetID == preset.id }
        if persist(updated) { selectedPresetID = settings.presets.first?.id; gate.reset() }
    }
    func saveRule(_ rule: ConnectionRule) {
        guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rule.requiredDevices.isEmpty || !rule.absentDevices.isEmpty,
              settings.presets.contains(where: { $0.id == rule.presetID }) else { error = "Choose a preset, a name, and at least one connection condition."; return }
        var updated = settings
        if let i = updated.rules.firstIndex(where: { $0.id == rule.id }) { updated.rules[i] = rule } else { updated.rules.append(rule) }
        if persist(updated) { editorRule = nil; gate.reset() }
    }
    func deleteRule(_ rule: ConnectionRule) {
        var updated = settings; updated.rules.removeAll { $0.id == rule.id }
        if persist(updated) { gate.reset() }
    }
    func moveRule(_ rule: ConnectionRule, by offset: Int) {
        guard let i = settings.rules.firstIndex(where: { $0.id == rule.id }), settings.rules.indices.contains(i + offset) else { return }
        var updated = settings; updated.rules.swapAt(i, i + offset)
        if persist(updated) { gate.reset() }
    }
    func toggleAutomation(_ enabled: Bool) {
        var updated = settings; updated.automationEnabled = enabled
        if persist(updated) { gate.reset() }
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
            let backend = self.backend
            try Configuration.validate(preset)
            let current = try await Task.detached { try backend.read() }.value
            if let reason = Configuration.availability(preset, connected: Set(current.map(\.id))) { throw DisplayMindError(reason) }
            _ = try Configuration.arguments(for: preset.displays)
            if Configuration.matches(preset.displays, actual: current.map(\.setting)) {
                if !preset.confirmed { confirm(preset.id) }
                status = "\(preset.name) is active"
                busy = false
                return
            }
            let needsAirPlay = preset.airPlay.map { target in !current.contains(where: { $0.id == target.displayID }) } ?? false
            if needsAirPlay { try AirPlayController.requireAccess() }
            var journal = try recovery.arm(previous: current.map(\.setting), setupTimeout: needsAirPlay ? 180 : 65)
            recoveryID = journal.id
            if needsAirPlay, let target = preset.airPlay {
                status = "Connecting AirPlay to \(target.receiverName)…"
                let recovery = self.recovery, changeID = journal.id
                try await Task.detached {
                    try AirPlayConnection.ensure(target, online: Hardware.connectedDisplayIDs, start: {
                        try AirPlayController().setConnected(target, true, beforeConnect: {
                            try recovery.markAirPlayStarted(id: changeID, target: target)
                        })
                    })
                }.value
            }
            status = "Applying \(preset.name)…"
            var connected = current
            if needsAirPlay { connected = try await Task.detached { try backend.read() }.value }
            if let reason = Configuration.availability(preset, connected: Set(connected.map(\.id)), allowAirPlayConnection: false) { throw DisplayMindError(reason) }
            if !Configuration.matches(preset.displays, actual: connected.map(\.setting)) {
                try await Task.detached { try backend.apply(preset.displays) }.value
            }
            let actual = try await Task.detached { try backend.read() }.value
            displays = Hardware.nameDisplays(actual)
            guard Configuration.matches(preset.displays, actual: actual.map(\.setting)) else {
                throw DisplayMindError("macOS did not accept every setting in this preset.")
            }
            if automatic {
                try recovery.keep(id: journal.id)
                recoveryID = nil
                status = "Automatically applied \(preset.name)"
                gate.consume(Hardware.devices(), now: Date())
                busy = false
            } else {
                journal.deadline = Date().addingTimeInterval(20)
                try recovery.updateDeadline(id: journal.id, deadline: journal.deadline)
                pending = PendingChange(journal: journal, preset: preset)
                secondsRemaining = 20
                status = "Keep this display layout?"
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
            gate.consume(Hardware.devices(), now: Date())
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
    private func tick() async {
        airPlayAuthorized = AirPlayController.authorized
        if let pending { secondsRemaining = max(0, Int(ceil(pending.journal.deadline.timeIntervalSinceNow))) }
        if let id = recoveryID, let result = recovery.result(), result.id == id {
            recoveryID = nil; pending = nil; busy = false
            status = result.error == nil ? "Previous layout restored" : "Display recovery needs attention"
            if let failure = result.error { error = failure }
            else if let failure = applyFailure { error = failure + " The previous layout was restored." }
            applyFailure = nil
            await refresh()
            gate.consume(Hardware.devices(), now: Date())
        }
        guard !polling, !busy, !airPlayScanning, pending == nil else { return }
        polling = true
        defer { polling = false }
        let found = await Task.detached { Hardware.devices() }.value
        devices = found.map { device in
            var copy = device
            if device.kind == .display, let display = displays.first(where: { "display:\($0.id)" == device.id }) { copy.name = display.setting.name }
            return copy
        }
        let ids = Set(devices.map(\.id))
        if ids != lastDevices { lastDevices = ids; await refresh() }
        guard gate.shouldEvaluate(devices, now: Date()), writable,
              let rule = RuleEngine.match(settings: settings, devices: devices),
              let preset = settings.presets.first(where: { $0.id == rule.presetID }) else { return }
        await apply(preset, automatic: true)
    }
    func loadDemo() {
        let a = DisplaySetting(id: "00000000-0000-0000-0000-000000000001", name: "Studio Display", mode: DisplayMode(width: 2560, height: 1440, hertz: 60, scaled: true))
        let b = DisplaySetting(id: "00000000-0000-0000-0000-000000000002", name: "Portrait display", mode: DisplayMode(width: 1080, height: 1920, hertz: 60), rotation: 90, x: 2560)
        let c = DisplaySetting(id: "00000000-0000-0000-0000-000000000003", name: "Built-in display", mode: DisplayMode(width: 1512, height: 982, hertz: 120, scaled: true), x: 400, y: 1440)
        let preset = Preset(name: "At my desk", displays: [a,b,c], confirmed: true)
        var laptop = c; laptop.x = 0; laptop.y = 0
        settings.presets = [preset, Preset(name: "Presentation", displays: [a], confirmed: true), Preset(name: "Just the laptop", displays: [laptop], confirmed: true)]
        displays = [a,b,c].map { ConnectedDisplay(setting: $0, modes: [$0.mode]) }
        devices = [a,b,c].map { Device(id: "display:\($0.id)", name: $0.name, kind: .display) } + [Device(id: "usb:demo", name: "Desk dock", kind: .usb)]
        settings.rules = [ConnectionRule(name: "When I dock", presetID: preset.id, requiredDevices: [devices.last!])]
        selectedPresetID = preset.id; status = "3 displays connected"
    }
}
