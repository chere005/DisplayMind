import AppKit
import SwiftUI
import DisplayMindCore

// MARK: Shared pieces

/// A rounded group with a visible edge in both appearances.
struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Branding.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Branding.hairline))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary) }
}

/// A borderless symbol button with a real hit area and a tooltip.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 28, height: 26).contentShape(Rectangle()) }
            .buttonStyle(.borderless).help(help).accessibilityLabel(help)
    }
}

/// A label on the left and a switch on the right edge, so stacked switches line up.
struct SwitchRow: View {
    let title: String
    let isOn: Binding<Bool>
    var body: some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Branding.fill)
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3).background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: Main window

struct MainView: View {
    @ObservedObject var store: Store
    @State private var deletingPreset: Preset?
    @State private var deletingRule: ConnectionRule?
    /// The preset whose name is being edited in place in the sidebar.
    @State private var renamingID: UUID?
    @State private var renameText: String
    @FocusState private var renameFocused: Bool
    @FocusState private var focusedPresetID: UUID?
    @State private var monitorFilter: Set<String>
    @State private var monitorMatchMode: PresetOrganization.MatchMode
    @State private var folderEditor: FolderEditor?
    @State private var deletingFolder: PresetFolder?
    @State private var newFolderScrollTarget: UUID?
    private var locked: Bool { store.busy || store.pending != nil }
    private struct FolderEditor: Identifiable {
        var id = UUID()
        var folder: PresetFolder?
    }
    /// `renaming` opens with that preset's name already being edited (previews).
    init(store: Store, renaming: UUID? = nil, monitorFilter: Set<String> = [], monitorMatchMode: PresetOrganization.MatchMode = .all, folderEditing: Bool = false, newFolder: Bool = false) {
        self.store = store
        _renamingID = State(initialValue: renaming)
        _renameText = State(initialValue: store.settings.presets.first { $0.id == renaming }?.name ?? "")
        _monitorFilter = State(initialValue: monitorFilter)
        _monitorMatchMode = State(initialValue: monitorMatchMode)
        _folderEditor = State(initialValue: folderEditing ? FolderEditor(folder: newFolder ? nil : store.settings.presetFolders?.first) : nil)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 280)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if store.pending != nil { confirmation.padding(.horizontal, 28).padding(.top, 20) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if store.showRules { rulesContent }
                        else if let preset = store.selectedPreset { presetContent(preset) }
                        else if store.settings.presets.isEmpty { welcome }
                        else { selectionEmpty }
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                statusBar
            }
        }
        .frame(minWidth: 980, minHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $store.editorPreset) { PresetEditor(store: store, original: $0) }
        .sheet(item: $store.editorRule) { RuleEditor(store: store, original: $0) }
        .sheet(item: $folderEditor) { editor in
            PresetFolderNameEditor(folder: editor.folder, cancel: { folderEditor = nil }) { name in
                let saved: Bool
                if let folder = editor.folder {
                    saved = store.renamePresetFolder(id: folder.id, to: name)
                } else if let id = store.createPresetFolder(name: name) {
                    saved = true
                    monitorFilter = []
                    newFolderScrollTarget = id
                } else {
                    saved = false
                }
                if saved { folderEditor = nil; alignPresetSelection(); return nil }
                let message = store.error ?? "This folder could not be saved."
                store.dismissError()
                return message
            }
        }
        .alert("DisplayMind", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.dismissError() } })) {
            Button("OK", role: .cancel) { store.dismissError() }
        } message: { Text(store.error ?? "") }
        .alert("Delete \(deletingPreset?.name ?? "preset")?", isPresented: Binding(get: { deletingPreset != nil }, set: { if !$0 { deletingPreset = nil } })) {
            Button("Delete", role: .destructive) { if let deletingPreset { store.delete(deletingPreset) }; deletingPreset = nil }
            Button("Cancel", role: .cancel) { deletingPreset = nil }
        } message: { Text("Connection rules using this preset will also be removed.") }
        .alert("Delete the rule \(deletingRule?.name ?? "")?", isPresented: Binding(get: { deletingRule != nil }, set: { if !$0 { deletingRule = nil } })) {
            Button("Delete", role: .destructive) { if let deletingRule { store.deleteRule(deletingRule) }; deletingRule = nil }
            Button("Cancel", role: .cancel) { deletingRule = nil }
        } message: { Text("The preset it applies is kept.") }
        .alert("Remove the folder \(deletingFolder?.name ?? "")?", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } })) {
            Button("Remove folder", role: .destructive) {
                if let folder = deletingFolder { _ = store.deletePresetFolder(id: folder.id) }
                deletingFolder = nil
                alignPresetSelection()
            }
            Button("Cancel", role: .cancel) { deletingFolder = nil }
        } message: { Text("Its presets are kept and moved to Ungrouped. Connection rules are kept.") }
        .onChange(of: monitorFilter) { _ in commitRename(); alignPresetSelection() }
        .onChange(of: monitorMatchMode) { _ in commitRename(); alignPresetSelection() }
        .onAppear { alignPresetSelection() }
        .onChange(of: store.settings) { _ in normalizeMonitorFilter() }
        .onChange(of: monitorOptions.map(\.id)) { _ in normalizeMonitorFilter() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: Branding.logo).resizable().frame(width: 30, height: 30).accessibilityHidden(true)
                Text("DisplayMind").font(.system(size: 17, weight: .semibold, design: .rounded))
            }.padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 20)
            HStack {
                SectionLabel("Presets")
                Spacer()
                IconButton(symbol: "folder.badge.plus", help: "New preset folder") { folderEditor = FolderEditor() }
                    .disabled(locked)
            }.padding(.leading, 20).padding(.trailing, 14).padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Includes displays").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !monitorFilter.isEmpty {
                        Button("Clear") { monitorFilter = [] }.buttonStyle(.plain).font(.caption).foregroundStyle(Branding.text)
                            .accessibilityLabel("Clear display filter")
                    }
                }
                PresetMonitorFilter(monitors: monitorOptions, selected: $monitorFilter, matching: $monitorMatchMode, matchCount: matchingPresets.count)
            }.padding(.horizontal, 16).padding(.bottom, 10)
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(presetGroups) { group in
                        if let folder = group.folder {
                            folderHeader(folder, group: group).id(folder.id)
                            if !folder.collapsed {
                                presetRows(group.presets).padding(.leading, 10)
                                if group.presets.isEmpty {
                                    Text("Move presets here from their ⋯ menu.").font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 20).padding(.trailing, 10).padding(.bottom, 8)
                                }
                            }
                        } else {
                            if !(store.settings.presetFolders ?? []).isEmpty {
                                SectionLabel("Ungrouped").padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
                            }
                            presetRows(group.presets)
                        }
                    }
                    if store.settings.presets.isEmpty {
                        Text("No presets yet. Capture your current layout to make the first one.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
                    } else if !monitorFilter.isEmpty && matchingPresets.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(monitorFilter.count == 1 ? "No presets include this display." : "No presets match these displays.").foregroundStyle(.secondary)
                            Button("Clear display filter") { monitorFilter = [] }.buttonStyle(.plain).foregroundStyle(Branding.text)
                        }.font(.callout).padding(.horizontal, 10).padding(.vertical, 8)
                    }
                }.padding(.horizontal, 10)
            }
            .onChange(of: renamingID) { id in if let id { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: focusedPresetID) { id in if let id { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: newFolderScrollTarget) { id in
                if let id { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) } }
            }
            .onChange(of: renameFocused) { focused in if !focused { commitRename() } }   // clicking elsewhere keeps the typed name
            }
            Button { Task { await store.capture() } } label: {
                Label("Capture current layout", systemImage: "plus.viewfinder").frame(maxWidth: .infinity)
            }.controlSize(.large).disabled(locked).padding(.horizontal, 14).padding(.vertical, 12)
                .help("Save the layout your displays have right now as a new preset")
            Divider().padding(.horizontal, 16)
            Button { store.showRules = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.horizontal").frame(width: 24).foregroundStyle(store.showRules ? Branding.text : Color.secondary)
                    Text("Connection rules").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                    if !store.settings.rules.isEmpty { Text("\(store.settings.rules.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }.padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
                    .background(store.showRules ? Branding.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).padding(.horizontal, 10).padding(.top, 10)
                .accessibilityAddTraits(store.showRules ? .isSelected : [])
            VStack(alignment: .leading, spacing: 10) {
                SwitchRow(title: "Automatic switching", isOn: Binding(get: { store.settings.automationEnabled }, set: store.toggleAutomation))
                SwitchRow(title: "Open at login", isOn: Binding(get: { store.loginEnabled }, set: store.setLogin))
                Button {
                    try? FileManager.default.createDirectory(at: store.settingsFile.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(store.settingsFile.directory)
                } label: { Label("Open data folder", systemImage: "folder").foregroundStyle(Branding.text).contentShape(Rectangle()) }.buttonStyle(.plain).padding(.top, 2)
            }.font(.callout).padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 18)
        }.background(Color.primary.opacity(0.03))
    }

    private var monitorOptions: [PresetOrganization.Monitor] {
        PresetOrganization.monitors(presets: store.settings.presets, connected: store.displays)
    }
    private var matchingPresets: [Preset] {
        PresetOrganization.filtered(store.settings.presets, monitorIDs: monitorFilter, matching: monitorMatchMode)
    }
    private var presetGroups: [PresetOrganization.Group] {
        PresetOrganization.groups(settings: store.settings, monitorIDs: monitorFilter, matching: monitorMatchMode)
    }
    private func normalizeMonitorFilter() {
        let available = Set(monitorOptions.map(\.id))
        monitorFilter = Set(monitorFilter.map { store.currentDisplayID($0) }).intersection(available)
        alignPresetSelection()
    }
    private func alignPresetSelection() {
        if matchingPresets.contains(where: { $0.id == store.selectedPresetID }) { return }
        let visible = PresetOrganization.visiblePresets(settings: store.settings, monitorIDs: monitorFilter, matching: monitorMatchMode)
        store.selectedPresetID = visible.first?.id ?? matchingPresets.first?.id
    }
    private func presetRows(_ presets: [Preset]) -> some View {
        ForEach(presets) { preset in
            Group { if renamingID == preset.id { renameRow(preset) } else { presetRow(preset) } }.id(preset.id)
        }
    }
    private func movePresetFocus(_ direction: MoveCommandDirection, from id: UUID) {
        guard direction == .up || direction == .down else { return }
        let visible = PresetOrganization.visiblePresets(settings: store.settings, monitorIDs: monitorFilter, matching: monitorMatchMode)
        guard let current = visible.firstIndex(where: { $0.id == id }) else { return }
        let next = current + (direction == .up ? -1 : 1)
        guard visible.indices.contains(next) else { return }
        store.selectedPresetID = visible[next].id
        store.showRules = false
        focusedPresetID = visible[next].id
    }
    private func folderHeader(_ folder: PresetFolder, group: PresetOrganization.Group) -> some View {
        let containsSelection = !store.showRules && group.presets.contains(where: { $0.id == store.selectedPresetID })
        return HStack(spacing: 2) {
            Button {
                commitRename()
                if store.setPresetFolderCollapsed(id: folder.id, collapsed: !folder.collapsed) { alignPresetSelection() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: folder.collapsed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold)).frame(width: 10)
                    Image(systemName: folder.collapsed ? "folder" : "folder.fill").foregroundStyle(folder.collapsed && containsSelection ? Branding.text : Color.secondary)
                    Text(folder.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).help(folder.name)
                    Spacer(minLength: 2)
                    Text(monitorFilter.isEmpty ? "\(group.totalCount)" : "\(group.presets.count)/\(group.totalCount)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(folder.collapsed ? "Expand" : "Collapse") \(folder.name)")
                .accessibilityValue(containsSelection ? "Contains selected preset" : "")
                .disabled(locked)
            Menu {
                Button("Rename folder…") { folderEditor = FolderEditor(folder: folder) }
                Button("Remove folder…", role: .destructive) { deletingFolder = folder }
            } label: { Image(systemName: "ellipsis").frame(width: 22, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Folder actions").accessibilityLabel("Actions for \(folder.name)").disabled(locked)
        }.padding(.leading, 8).padding(.trailing, 4).padding(.top, 5)
            .background(folder.collapsed && containsSelection ? Branding.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contextMenu {
                Button("Rename folder…") { folderEditor = FolderEditor(folder: folder) }.disabled(locked)
                Button("Remove folder…", role: .destructive) { deletingFolder = folder }.disabled(locked)
            }
    }

    private func beginRename(_ preset: Preset) {
        guard !locked else { return }
        renameText = preset.name
        store.selectedPresetID = preset.id; store.showRules = false
        renamingID = preset.id
        DispatchQueue.main.async { renameFocused = true }
    }
    private func commitRename(restoreFocus: Bool = false) {
        guard let id = renamingID else { return }
        renamingID = nil
        if let preset = store.settings.presets.first(where: { $0.id == id }) { store.rename(preset, to: renameText) }
        if restoreFocus { DispatchQueue.main.async { focusedPresetID = id } }
    }
    private func cancelRename() {
        guard let id = renamingID else { return }
        renamingID = nil
        DispatchQueue.main.async { focusedPresetID = id }
    }

    /// The sidebar row while its name is edited: Return or a click elsewhere keeps the name, Escape discards it.
    private func renameRow(_ preset: Preset) -> some View {
        HStack(spacing: 10) {
            PresetThumbnail(displays: preset.displays, selected: true)
            TextField("Preset name", text: $renameText).textFieldStyle(.roundedBorder).font(.system(size: 13, weight: .medium))
                .focused($renameFocused)
                .onSubmit { commitRename(restoreFocus: true) }
                .onExitCommand { cancelRename() }
                .accessibilityLabel("Preset name")
        }.padding(.horizontal, 10).padding(.vertical, 8)
            .background(Branding.selection, in: RoundedRectangle(cornerRadius: 8))
    }

    private func presetRow(_ preset: Preset) -> some View {
        let selected = !store.showRules && store.selectedPresetID == preset.id
        return Button { store.selectedPresetID = preset.id; store.showRules = false; focusedPresetID = preset.id } label: {
            HStack(spacing: 10) {
                PresetThumbnail(displays: preset.displays, selected: selected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Text("\(preset.displays.count) display\(preset.displays.count == 1 ? "" : "s")" + (store.isActive(preset) ? " · Active" : ""))
                        .font(.caption).foregroundStyle(store.isActive(preset) ? Branding.text : Color.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                .background(selected ? Branding.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help(preset.name)
            .focusable()
            .focused($focusedPresetID, equals: preset.id)
            .onMoveCommand { movePresetFocus($0, from: preset.id) }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(preset) })
            .accessibilityAction(named: "Rename") { beginRename(preset) }
            .contextMenu {
                Button("Apply") { Task { await store.apply(preset) } }.disabled(locked || store.unavailable(preset) != nil)
                Button("Edit preset…") { store.editorPreset = preset }.disabled(locked)
                presetMenu(preset).disabled(locked)
            }
    }

    // MARK: Header

    private var title: String {
        store.showRules ? "Connection rules" : store.selectedPreset?.name ?? (store.settings.presets.isEmpty ? "Your displays, arranged." : "Choose a preset")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 24, weight: .semibold, design: .rounded)).lineLimit(1).truncationMode(.tail).help(title)
                subtitle.font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if store.busy { ProgressView().controlSize(.small) }
            if store.showRules {
                Button { newRule() } label: { Label("New rule", systemImage: "plus") }
                    .controlSize(.large).fixedSize().disabled(store.settings.presets.isEmpty || locked)
            } else if let preset = store.selectedPreset { presetActions(preset) }
        }.padding(.horizontal, 28).frame(height: 86)
    }

    @ViewBuilder private var subtitle: some View {
        if store.showRules {
            Text("Rules run from top to bottom. The first matching rule wins.").foregroundStyle(.secondary)
        } else if let preset = store.selectedPreset {
            // One line of status, most pressing first; it never competes with a second label for the width.
            if let reason = store.unavailable(preset) {
                Label(reason + " to use this preset", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(reason + " to use this preset")
            } else if store.isActive(preset) {
                Label(preset.confirmed ? "Active now" : "Active now · apply and keep it once to enable rules", systemImage: "checkmark.circle.fill").foregroundStyle(Branding.text)
            } else if !preset.confirmed {
                Label("Ready to apply · keep it once to enable rules", systemImage: "info.circle").foregroundStyle(.secondary)
            } else {
                Label("Ready to apply", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
        } else {
            Text(store.settings.presets.isEmpty ? "Save a layout, then switch to it in a click." : "Choose a preset from the sidebar.").foregroundStyle(.secondary)
        }
    }

    private func presetActions(_ preset: Preset) -> some View {
        HStack(spacing: 8) {
            Button { Task { await store.apply(preset) } } label: { Label("Apply preset", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).tint(Branding.fill).disabled(locked || store.unavailable(preset) != nil)
            Button("Edit preset…") { store.editorPreset = preset }.disabled(locked)
            Menu { presetMenu(preset) } label: { Text("⋯").frame(width: 16) }
                .menuStyle(.button).buttonStyle(.bordered).menuIndicator(.hidden).fixedSize()
                .help("More actions").accessibilityLabel("More actions").disabled(locked)
        }.controlSize(.large).fixedSize()
    }

    @ViewBuilder private func presetMenu(_ preset: Preset) -> some View {
        Button("Rename") { beginRename(preset) }
        Button("Duplicate…") { store.duplicate(preset) }
        Menu("Move to folder") {
            Button {
                if store.movePreset(id: preset.id, to: nil) { alignPresetSelection() }
            } label: {
                if preset.folderID == nil { Label("Ungrouped", systemImage: "checkmark") } else { Text("Ungrouped") }
            }
            if !(store.settings.presetFolders ?? []).isEmpty { Divider() }
            ForEach(store.settings.presetFolders ?? []) { folder in
                Button {
                    if store.movePreset(id: preset.id, to: folder.id) { alignPresetSelection() }
                } label: {
                    if preset.folderID == folder.id { Label(folder.name, systemImage: "checkmark") } else { Text(folder.name) }
                }
            }
        }
        Button("Create connection rule…") { store.editorRule = rule(for: preset) }
        Divider()
        Button("Delete preset…", role: .destructive) { deletingPreset = preset }
    }

    // MARK: Status bar and countdown

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle().fill(store.status == Store.attention ? Color.red : locked ? Color.orange : Branding.text).frame(width: 7, height: 7)
            Text(store.status).font(.callout).foregroundStyle(.secondary).lineLimit(2).help(store.status)
            Spacer(minLength: 12)
            IconButton(symbol: "gearshape", help: "Open macOS Display Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
            }
            IconButton(symbol: "arrow.clockwise", help: "Read the displays again") { Task { await store.refresh() } }.disabled(locked)
        }.padding(.leading, 28).padding(.trailing, 20).frame(minHeight: 44)
    }

    /// Shown for the revert window after a preset is applied by hand. Doing nothing keeps the change.
    private var confirmation: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Branding.text)
            VStack(alignment: .leading, spacing: 3) {
                Text("Layout applied").fontWeight(.semibold)
                Text("It stays. You can revert for \(store.secondsRemaining) more second\(store.secondsRemaining == 1 ? "" : "s").")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 12)
            Button("Revert", action: store.revert).keyboardShortcut(.cancelAction).help("Go back to the previous layout (Esc)")
            Button("Keep", action: store.keep).buttonStyle(.borderedProminent).tint(Branding.fill).keyboardShortcut(.defaultAction).help("Keep it and close this now")
        }.controlSize(.large).padding(16)
            .background(Branding.selection, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Branding.text.opacity(0.35)))
    }

    // MARK: Preset page

    private struct Detail: Identifiable { let id: String; let symbol: String; let value: String }

    private func details(_ preset: Preset) -> [Detail] {
        var rows: [Detail] = []
        if let target = preset.airPlay {
            rows.append(Detail(id: "AirPlay", symbol: "airplayvideo", value: target.receiverName + (store.connectedIDs.contains(target.displayID) ? " · connected" : " · connects when applied")))
        }
        if let output = preset.audio?.output { rows.append(Detail(id: "Sound output", symbol: "speaker.wave.2", value: output.name)) }
        if let input = preset.audio?.input { rows.append(Detail(id: "Sound input", symbol: "mic", value: input.name)) }
        return rows
    }

    private func symbol(for display: DisplaySetting) -> String {
        if display.mirrorOf != nil { return "rectangle.on.rectangle" }
        if store.displays.first(where: { $0.id == display.id })?.builtIn == true || display.name.localizedCaseInsensitiveContains("built-in") { return "laptopcomputer" }
        return display.rotation % 180 == 0 ? "display" : "rectangle.portrait"
    }

    private func presetContent(_ preset: Preset) -> some View {
        let rows = details(preset)
        return VStack(alignment: .leading, spacing: 20) {
            DisplayDiagram(displays: preset.displays).frame(height: 250)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Displays")
                Card {
                    ForEach(preset.displays) { display in
                        HStack(spacing: 12) {
                            Image(systemName: symbol(for: display)).font(.title3).foregroundStyle(.secondary).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(display.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                                Text(display.mirrorOf != nil ? "Follows its source" : display.mode.label + (display.rotation == 0 ? "" : " · rotated \(display.rotation)°"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            Text(role(display, in: preset.displays)).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }.padding(.horizontal, 14).padding(.vertical, 11)
                        if display.id != preset.displays.last?.id { Divider().padding(.leading, 54) }
                    }
                }
            }
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Applied with the layout")
                    Card {
                        ForEach(rows) { row in
                            HStack(spacing: 12) {
                                Image(systemName: row.symbol).foregroundStyle(.secondary).frame(width: 28)
                                Text(row.id)
                                Spacer(minLength: 12)
                                Text(row.value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }.padding(.horizontal, 14).padding(.vertical, 11)
                            if row.id != rows.last?.id { Divider().padding(.leading, 54) }
                        }
                    }
                }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            DisplayDiagram(displays: store.displays.map(\.setting)).frame(height: 270)
            Text("A setup for every way you work.").font(.title2).fontWeight(.semibold)
            Text("Capture your current displays, then edit their rotation, resolution, position, mirroring and sound. Your presets are one click away in the menu bar.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { Task { await store.capture() } } label: { Label("Save my current layout", systemImage: "plus.viewfinder") }
                .buttonStyle(.borderedProminent).tint(Branding.fill).controlSize(.large).disabled(store.busy || store.displays.isEmpty)
        }
    }

    private var selectionEmpty: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: monitorFilter.isEmpty ? "folder" : "line.3.horizontal.decrease.circle").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(monitorFilter.isEmpty ? "Choose a preset" : "No matching presets").font(.title3).fontWeight(.semibold)
                Text(monitorFilter.isEmpty ? "Choose a saved layout from the sidebar." : monitorFilter.count > 1 && monitorMatchMode == .all
                     ? "Choose fewer displays, switch to Any selected, or clear the display filter." : "Choose different displays or clear the display filter.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !monitorFilter.isEmpty { Button("Clear display filter") { monitorFilter = [] } }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Rules page

    private var rulesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !store.settings.automationEnabled {
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                    Text("Automatic switching is paused, so no rule runs.")
                    Spacer(minLength: 12)
                    Button("Turn on") { store.toggleAutomation(true) }
                }.padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.35)))
            }
            if store.settings.rules.isEmpty {
                Card {
                    VStack(spacing: 10) {
                        Image(systemName: "cable.connector").font(.system(size: 32)).foregroundStyle(Branding.text)
                        Text("Connect your dock. Get your layout.").font(.title3).fontWeight(.semibold)
                        Text("Choose displays or USB devices, then the preset to use when they are connected or absent.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        Button("Create a rule…", action: newRule).controlSize(.large).disabled(store.settings.presets.isEmpty).padding(.top, 4)
                        if store.settings.presets.isEmpty { Text("Capture a preset first.").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity).padding(28)
                }
            }
            ForEach(Array(store.settings.rules.enumerated()), id: \.element.id) { index, rule in ruleCard(index, rule) }
            SectionLabel("Connected now").padding(.top, 10)
            Card {
                if store.devices.isEmpty { Text("Nothing detected yet.").foregroundStyle(.secondary).padding(14) }
                ForEach(store.devices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: device.kind == .display ? "display" : "cable.connector").foregroundStyle(.secondary).frame(width: 28)
                        Text(device.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 12)
                        Text(device.kind == .display ? "Display" : "USB").font(.callout).foregroundStyle(.secondary)
                    }.padding(.horizontal, 14).padding(.vertical, 9)
                    if device.id != store.devices.last?.id { Divider().padding(.leading, 54) }
                }
            }
            Text("A USB device without a serial number is remembered by its port. DisplayMind stays in the menu bar when you close this window.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.disabled(locked)
    }

    private func state(of rule: ConnectionRule, preset: Preset?) -> (text: String, color: Color) {
        guard let preset else { return ("Preset missing", .red) }
        if !preset.confirmed { return ("Apply and keep the preset first", .orange) }
        if !rule.enabled { return ("Off", .secondary) }
        if !store.settings.automationEnabled { return ("Paused", .secondary) }
        return RuleEngine.match(settings: store.settings, devices: store.devices)?.id == rule.id ? ("Matches now", Branding.text) : ("Waiting for devices", .secondary)
    }

    private func ruleCard(_ index: Int, _ rule: ConnectionRule) -> some View {
        let preset = store.settings.presets.first { $0.id == rule.presetID }
        let state = state(of: rule, preset: preset)
        return Card {
            HStack(alignment: .top, spacing: 12) {
                Text("\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 16, alignment: .trailing).padding(.top, 1)
                Toggle("Rule enabled", isOn: Binding(get: { rule.enabled }, set: { enabled in var copy = rule; copy.enabled = enabled; store.saveRule(copy) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Branding.fill).help(rule.enabled ? "This rule is on" : "This rule is off")
                VStack(alignment: .leading, spacing: 6) {
                    Text(rule.name).fontWeight(.semibold).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(ruleSummary(rule)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Label(preset?.name ?? "No preset", systemImage: "arrow.turn.down.right").font(.callout).lineLimit(1).truncationMode(.middle)
                        Badge(text: state.text, color: state.color)
                    }.padding(.top, 2)
                }.opacity(rule.enabled ? 1 : 0.65)
                Spacer(minLength: 12)
                HStack(spacing: 2) {
                    IconButton(symbol: "arrow.up", help: "Move up: checked earlier") { store.moveRule(rule, by: -1) }.disabled(index == 0)
                    IconButton(symbol: "arrow.down", help: "Move down: checked later") { store.moveRule(rule, by: 1) }.disabled(index == store.settings.rules.count - 1)
                    Button("Edit…") { store.editorRule = rule }.padding(.horizontal, 6)
                    IconButton(symbol: "trash", help: "Delete rule…") { deletingRule = rule }
                }.fixedSize()
            }.padding(14)
        }
    }

    private func rule(for preset: Preset) -> ConnectionRule {
        ConnectionRule(name: "Use \(preset.name)", presetID: preset.id, requiredDevices: store.defaultRuleDevices(for: preset))
    }
    private func newRule() {
        guard let preset = store.selectedPreset ?? store.settings.presets.first else { return }
        store.editorRule = rule(for: preset)
    }
    private func ruleSummary(_ rule: ConnectionRule) -> String {
        var parts: [String] = []
        if !rule.requiredDevices.isEmpty { parts.append("Connected: " + rule.requiredDevices.map(\.name).joined(separator: ", ")) }
        if !rule.absentDevices.isEmpty { parts.append("Absent: " + rule.absentDevices.map(\.name).joined(separator: ", ")) }
        if rule.exactDisplays { parts.append("no other displays") }
        return parts.joined(separator: " · ")
    }
}

struct PresetFolderNameEditor: View {
    let folder: PresetFolder?
    let cancel: () -> Void
    let save: (String) -> String?
    @State private var name: String
    @State private var validationError: String?
    @FocusState private var focused: Bool
    init(folder: PresetFolder?, validationError: String? = nil, cancel: @escaping () -> Void, save: @escaping (String) -> String?) {
        self.folder = folder; self.cancel = cancel; self.save = save
        _name = State(initialValue: folder?.name ?? "")
        _validationError = State(initialValue: validationError)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(folder == nil ? "New preset folder" : "Rename preset folder").font(.title2).fontWeight(.semibold)
            TextField("Folder name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { saveName() }.accessibilityLabel("Folder name")
            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(folder == nil ? "Create folder" : "Rename folder") { saveName() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 360)
            .onAppear { focused = true }
            .onChange(of: name) { _ in validationError = nil }
    }
    private func saveName() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        validationError = save(name)
    }
}

func role(_ display: DisplaySetting, in displays: [DisplaySetting]) -> String {
    if !display.enabled { return "Disabled" }
    if let source = display.mirrorOf { return "Mirrors " + (displays.first { $0.id == source }?.name ?? "display") }
    return display.x == 0 && display.y == 0 ? "Main display" : "Extended"
}

// MARK: Arrangement diagram

/// A tile is a button for VoiceOver and keyboard users only where clicking it does something.
private struct Selectable: ViewModifier {
    let isSelected: Bool
    let action: (() -> Void)?
    func body(content: Content) -> some View {
        if let action { content.accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton).accessibilityAction { action() } } else { content }
    }
}

/// The extended displays to scale. With `select` a click chooses a display; with `moved` extended displays can be dragged.
struct DisplayDiagram: View {
    let displays: [DisplaySetting]
    var selected: String?
    var select: ((String) -> Void)?
    var moved: ((String, Int, Int) -> Void)?
    @State private var dragging: String?
    @State private var translation = CGSize.zero
    var body: some View {
        GeometryReader { proxy in
            let roots = displays.filter { $0.enabled && $0.mirrorOf == nil }
            let minX = roots.map(\.x).min() ?? 0
            let minY = roots.map(\.y).min() ?? 0
            let maxX = roots.map { $0.x + $0.mode.width }.max() ?? 1
            let maxY = roots.map { $0.y + $0.mode.height }.max() ?? 1
            let scale = max(0.001, min((proxy.size.width - 80) / CGFloat(max(1, maxX - minX)), (proxy.size.height - 56) / CGFloat(max(1, maxY - minY))))
            let offsetX = (proxy.size.width - CGFloat(maxX - minX) * scale) / 2
            let offsetY = (proxy.size.height - CGFloat(maxY - minY) * scale) / 2
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Branding.card)
                Canvas { context, size in
                    for x in stride(from: 12.0, to: size.width, by: 20) {
                        for y in stride(from: 12.0, to: size.height, by: 20) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.secondary.opacity(0.18)))
                        }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 14))
                RoundedRectangle(cornerRadius: 14).strokeBorder(Branding.hairline)
                ForEach(roots) { display in
                    let isMain = display.x == 0 && display.y == 0
                    let isSelected = selected == display.id
                    let width = max(44, CGFloat(display.mode.width) * scale - 4)
                    let height = max(30, CGFloat(display.mode.height) * scale - 4)
                    let mirrors = displays.filter { $0.mirrorOf == display.id }.count
                    VStack(spacing: 4) {
                        Text(display.name).font(.system(size: 12, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                        if height > 64 { Text("\(String(display.mode.width)) × \(String(display.mode.height))").font(.system(size: 10)).opacity(0.8).lineLimit(1).minimumScaleFactor(0.7) }
                        if mirrors > 0, height > 86 { Label(mirrors == 1 ? "Mirrored" : "Mirrored ×\(mirrors)", systemImage: "rectangle.on.rectangle").font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.7) }
                    }.padding(6).frame(width: width, height: height)
                        .overlay(alignment: .top) {
                            if isMain { Capsule().fill(.white.opacity(0.85)).frame(width: min(width - 16, 54), height: 4).padding(.top, 7) }
                        }
                        .foregroundStyle(.white)
                        .background(LinearGradient(colors: isMain ? [Color(red: 0.16, green: 0.55, blue: 0.68), Color(red: 0.11, green: 0.34, blue: 0.51)] : [Color(red: 0.34, green: 0.47, blue: 0.62), Color(red: 0.24, green: 0.32, blue: 0.46)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(isSelected ? 0.95 : 0.2), lineWidth: isSelected ? 2.5 : 1))
                        .shadow(color: .black.opacity(isSelected ? 0.35 : 0.15), radius: isSelected ? 10 : 8, y: 4)
                        .contentShape(Rectangle())
                        .offset(x: dragging == display.id ? translation.width : 0, y: dragging == display.id ? translation.height : 0)
                        .position(x: offsetX + CGFloat(display.x - minX) * scale + CGFloat(display.mode.width) * scale / 2,
                                  y: offsetY + CGFloat(display.y - minY) * scale + CGFloat(display.mode.height) * scale / 2)
                        .zIndex(dragging == display.id ? 2 : isSelected ? 1 : 0)
                        .onTapGesture { select?(display.id) }
                        .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                            guard moved != nil, !isMain else { return }
                            if dragging != display.id { select?(display.id) }
                            dragging = display.id; translation = value.translation
                        }.onEnded { value in
                            if moved != nil, !isMain { moved?(display.id, display.x + Int((value.translation.width / scale / 10).rounded()) * 10, display.y + Int((value.translation.height / scale / 10).rounded()) * 10) }
                            dragging = nil; translation = .zero
                        })
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(display.name), \(role(display, in: displays)), \(display.rotation) degrees")
                        .modifier(Selectable(isSelected: isSelected, action: select.map { choose in { choose(display.id) } }))
                }
                if roots.isEmpty { Text("No displays available").foregroundStyle(.secondary) }
            }
        }
    }
}
