import Foundation
import DisplayMindCore

@MainActor extension Store {
    private func presetFolderName(_ proposed: String, ignoring id: UUID? = nil) -> String? {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, !name.contains(where: \.isNewline) else {
            fail("Give the folder a name of up to 100 characters.")
            return nil
        }
        let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard !(settings.presetFolders ?? []).contains(where: {
            $0.id != id && $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) == key
        }) else {
            fail("A folder with that name already exists.")
            return nil
        }
        return name
    }

    @discardableResult func createPresetFolder(name: String) -> UUID? {
        guard !busy, pending == nil, let name = presetFolderName(name) else { return nil }
        let folder = PresetFolder(name: name)
        var updated = settings
        updated.presetFolders = (updated.presetFolders ?? []) + [folder]
        return persist(updated) ? folder.id : nil
    }

    @discardableResult func renamePresetFolder(id: UUID, to proposed: String) -> Bool {
        guard !busy, pending == nil,
              let index = settings.presetFolders?.firstIndex(where: { $0.id == id }),
              let name = presetFolderName(proposed, ignoring: id) else { return false }
        var updated = settings
        updated.presetFolders?[index].name = name
        return persist(updated)
    }

    @discardableResult func setPresetFolderCollapsed(id: UUID, collapsed: Bool) -> Bool {
        guard !busy, pending == nil, let index = settings.presetFolders?.firstIndex(where: { $0.id == id }) else { return false }
        var updated = settings
        updated.presetFolders?[index].collapsed = collapsed
        return persist(updated)
    }

    @discardableResult func movePreset(id: UUID, to folderID: UUID?) -> Bool {
        guard !busy, pending == nil, let index = settings.presets.firstIndex(where: { $0.id == id }),
              folderID == nil || (settings.presetFolders ?? []).contains(where: { $0.id == folderID }) else { return false }
        var updated = settings
        updated.presets[index].folderID = folderID
        if selectedPresetID == id, let folderID,
           let folder = updated.presetFolders?.firstIndex(where: { $0.id == folderID }) {
            updated.presetFolders?[folder].collapsed = false
        }
        return persist(updated)
    }

    /// Removing a folder keeps its presets and connection rules, returning its contents to Ungrouped.
    @discardableResult func deletePresetFolder(id: UUID) -> Bool {
        guard !busy, pending == nil, (settings.presetFolders ?? []).contains(where: { $0.id == id }) else { return false }
        var updated = settings
        updated.presetFolders?.removeAll { $0.id == id }
        for index in updated.presets.indices where updated.presets[index].folderID == id {
            updated.presets[index].folderID = nil
        }
        return persist(updated)
    }
}
