import AppKit
import SwiftUI

struct DisplayMindCommands: Commands {
	@ObservedObject var store: Store
	@ObservedObject var updates: UpdateChecker

	var body: some Commands {
		CommandGroup(after: .appInfo) {
			UpdateMenuItems(updates: updates)
		}
		CommandGroup(replacing: .newItem) {
			CaptureLayoutMenuItem(store: store, shortcut: KeyboardShortcut("n"))
		}
		CommandGroup(after: .sidebar) {
			Button("Refresh Displays") { Task { await store.refresh() } }
				.keyboardShortcut("r")
				.disabled(!store.canRefreshDisplays)
			Button("Connection Rules") {
				store.openWindow?()
				store.showRules = true
			}
		}
		CommandMenu("Presets") {
			PresetMenuItems(store: store)
		}
		CommandGroup(replacing: .help) {
			Button("DisplayMind Help") {
				NSWorkspace.shared.open(URL(string: "https://github.com/chere005/DisplayMind#use")!)
			}
		}
	}
}

struct CaptureLayoutMenuItem: View {
	@ObservedObject var store: Store
	var shortcut: KeyboardShortcut? = nil
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		Button("Capture Current Layout…") {
			DisplayMindWindow.open(using: openWindow)
			Task { await store.capture() }
		}
		.keyboardShortcut(shortcut)
		.disabled(!store.canStartLayoutCommand)
	}
}

struct PresetMenuItems: View {
	@ObservedObject var store: Store

	var body: some View {
		if store.pending != nil {
			Button("Revert (\(store.secondsRemaining)s left)", action: store.revert)
			Button("Keep Now", action: store.keep)
			Divider()
		}
		ForEach(store.settings.presets) { preset in
			Button { Task { await store.apply(preset) } } label: {
				if store.isActive(preset) { Label(preset.name, systemImage: "checkmark") }
				else { Text(preset.name) }
			}.disabled(!store.canStartLayoutCommand || store.unavailable(preset) != nil)
		}
		if store.settings.presets.isEmpty { Text("No presets yet") }
		Divider()
		Toggle("Automatic Switching", isOn: Binding(get: { store.settings.automationEnabled }, set: store.toggleAutomation))
	}
}

struct UpdateMenuItems: View {
	@ObservedObject var updates: UpdateChecker

	var body: some View {
		if let update = updates.available {
			Button("Download DisplayMind \(update.version)") { NSWorkspace.shared.open(update.downloadURL) }
		}
		Button(updates.checking ? "Checking for Updates…" : "Check for Updates…") {
			Task { await updates.check(manual: true) }
		}.disabled(updates.checking)
	}
}
