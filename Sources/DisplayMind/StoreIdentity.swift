import Foundation
import DisplayMindCore

@MainActor extension Store {
    /// A current UUID always wins over an alias left by an earlier connection.
    var currentDisplayAliases: [String: String] { displayAliases.filter { !connectedIDs.contains($0.key) } }

    func currentDisplayID(_ id: String) -> String {
        DisplayReconciliation.resolvedID(id, using: currentDisplayAliases)
    }

    /// Keep a stale editor's layout edits while replacing only its old device references and missing identity metadata.
    func currentPresetReferences(_ preset: Preset) -> Preset {
        var updated = DisplayReconciliation.remap(preset: preset, using: currentDisplayAliases)
        if let stored = settings.presets.first(where: { $0.id == updated.id }) {
            for index in updated.displays.indices where updated.displays[index].identity == nil {
                updated.displays[index].identity = stored.displays.first(where: { $0.id == updated.displays[index].id })?.identity
            }
        }
        return updated
    }

    /// Physical identity matching changes saved references, never the live layout or a recovery journal.
    func reconcileDisplayIdentities() {
        guard identityUpdatesAllowed else { return }
        var excluded = Set(airPlayOnline.keys)
        excluded.formUnion(settings.presets.compactMap { $0.airPlay?.displayID })
        let mapping = DisplayReconciliation.mapping(settings: settings, connected: displays, excluded: excluded)
        let updated = DisplayReconciliation.reconcile(settings: settings, connected: displays, excluded: excluded)
        guard updated != settings, persist(updated) else { return }
        var aliases = displayAliases.mapValues { DisplayReconciliation.resolvedID($0, using: mapping) }
        aliases.merge(mapping) { _, new in new }
        displayAliases = aliases.filter { $0.key != $0.value }
    }
}
