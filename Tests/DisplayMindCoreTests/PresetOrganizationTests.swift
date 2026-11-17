import XCTest
@testable import DisplayMindCore
@testable import DisplayMind

final class PresetOrganizationTests: XCTestCase {
    private func preset(_ name: String, displays: [DisplaySetting], folder: UUID? = nil) -> Preset {
        var result = Preset(name: name, displays: displays, confirmed: true)
        result.folderID = folder
        return result
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DisplayMind-organization-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testMonitorFilterIncludesSavedOfflineMonitorsAndKeepsSameNamesDistinct() {
        var first = layout()[0], second = layout()[1]
        first.name = "LG"; second.name = "LG"
        let a = preset("Left", displays: [first]), b = preset("Right", displays: [second])
        let monitors = PresetOrganization.monitors(presets: [b, a], connected: [ConnectedDisplay(setting: second, modes: [second.mode])])
        XCTAssertEqual(monitors.map(\.id), [first.id, second.id])
        XCTAssertEqual(monitors.map(\.title), ["LG (1) · Not connected", "LG (2)"])
        XCTAssertEqual(monitors.map(\.connected), [false, true])
        XCTAssertEqual(PresetOrganization.filtered([a, b], monitorID: first.id).map(\.id), [a.id])
        XCTAssertEqual(PresetOrganization.filtered([a, b], monitorID: second.id).map(\.id), [b.id])
        XCTAssertEqual(PresetOrganization.filtered([a, b], monitorID: nil).map(\.id), [a.id, b.id])
    }

    func testMonitorNamesPreferRealConnectedNamesAndDeduplicateReferences() {
        let saved = layout()[0]
        var connected = saved; connected.name = "Desk display"
        let presets = [preset("One", displays: [saved]), preset("Two", displays: [saved])]
        let monitors = PresetOrganization.monitors(presets: presets, connected: [ConnectedDisplay(setting: connected, modes: [connected.mode])])
        XCTAssertEqual(monitors.count, 1)
        XCTAssertEqual(monitors[0].name, "Desk display")
        connected.name = "External display 1"
        XCTAssertEqual(PresetOrganization.monitors(presets: presets, connected: [ConnectedDisplay(setting: connected, modes: [connected.mode])])[0].name, saved.name)
    }

    func testGroupsPreserveSavedOrderAndKeepOrphanedPresetsAccessible() {
        let first = PresetFolder(name: "First"), second = PresetFolder(name: "Second")
        let ungrouped = preset("Ungrouped", displays: [layout()[0]])
        let orphan = preset("Recovered", displays: [layout()[0]], folder: UUID())
        let a = preset("A", displays: layout(), folder: second.id)
        let b = preset("B", displays: layout(), folder: first.id)
        let c = preset("C", displays: layout(), folder: first.id)
        var settings = AppSettings()
        settings.presetFolders = [second, first]
        settings.presets = [ungrouped, a, b, orphan, c]
        let groups = PresetOrganization.groups(settings: settings)
        XCTAssertEqual(groups.map(\.id), ["ungrouped", second.id.uuidString, first.id.uuidString])
        XCTAssertEqual(groups.map { $0.presets.map(\.id) }, [[ungrouped.id, orphan.id], [a.id], [b.id, c.id]])
        XCTAssertEqual(groups.map(\.totalCount), [2, 1, 2])
        XCTAssertEqual(Set(groups.flatMap(\.presets).map(\.id)), Set(settings.presets.map(\.id)))
    }

    func testFilteringAndCollapsingDoNotLoseFolderMembershipOrCounts() {
        let collapsed = PresetFolder(name: "Desk", collapsed: true), empty = PresetFolder(name: "Empty")
        let laptop = preset("Laptop", displays: [layout()[0]])
        let portrait = preset("Portrait", displays: layout(), folder: collapsed.id)
        let other = preset("Other", displays: [layout()[0]], folder: collapsed.id)
        var settings = AppSettings()
        settings.presets = [laptop, portrait, other]
        settings.presetFolders = [collapsed, empty]
        XCTAssertEqual(PresetOrganization.groups(settings: settings).map(\.id), ["ungrouped", collapsed.id.uuidString, empty.id.uuidString])
        XCTAssertEqual(PresetOrganization.visiblePresets(settings: settings).map(\.id), [laptop.id])
        let groups = PresetOrganization.groups(settings: settings, monitorID: displayB)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].presets.map(\.id), [portrait.id])
        XCTAssertEqual(groups[0].totalCount, 2)
        XCTAssertTrue(PresetOrganization.visiblePresets(settings: settings, monitorID: displayB).isEmpty)
        XCTAssertTrue(PresetOrganization.groups(settings: settings, monitorID: displayC).isEmpty)
        XCTAssertEqual(settings.presets[1].folderID, collapsed.id)
    }

    func testOldSettingsWithoutOrganizationFieldsStillDecode() throws {
        var settings = AppSettings()
        settings.presets = [preset("Legacy", displays: layout())]
        let encoded = try JSONEncoder().encode(settings)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "presetFolders")
        var presets = try XCTUnwrap(object["presets"] as? [[String: Any]])
        for index in presets.indices { presets[index].removeValue(forKey: "folderID") }
        object["presets"] = presets
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.presetFolders)
        XCTAssertNil(decoded.presets[0].folderID)
        XCTAssertEqual(decoded.presets[0].displays, settings.presets[0].displays)
        XCTAssertTrue(decoded.presets[0].confirmed)
    }

    func testFolderMembershipAndCollapseRoundTripThroughSettingsFile() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = PresetFolder(name: "Drawing", collapsed: true)
        var settings = AppSettings()
        settings.presetFolders = [folder]
        settings.presets = [preset("Tablet", displays: layout(), folder: folder.id)]
        let file = SettingsFile(directory: dir)
        try file.save(settings)
        XCTAssertEqual(try file.load(), settings)
    }

    func testDuplicateFolderIDsAreRejectedWithoutReplacingTheSettingsFile() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = PresetFolder(name: "Drawing")
        var settings = AppSettings()
        settings.presetFolders = [first, PresetFolder(id: first.id, name: "Office", collapsed: true)]
        settings.presets = [preset("Desk", displays: layout(), folder: first.id)]
        let file = SettingsFile(directory: dir)
        try file.save(settings)
        let original = try Data(contentsOf: file.url)
        XCTAssertThrowsError(try file.load())
        XCTAssertEqual(try Data(contentsOf: file.url), original)
    }

    @MainActor func testFolderChangesPreservePresetsRulesAndConfirmation() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir, demo: true)
        let before = store.settings
        let selected = try XCTUnwrap(before.presets.first)
        let id = try XCTUnwrap(store.createPresetFolder(name: "  Drawing  "))
        let otherID = try XCTUnwrap(store.createPresetFolder(name: "Office"))
        XCTAssertEqual(store.settings.presetFolders?.first?.name, "Drawing")
        XCTAssertTrue(store.movePreset(id: selected.id, to: id))
        XCTAssertTrue(store.movePreset(id: before.presets[1].id, to: otherID))
        XCTAssertTrue(store.setPresetFolderCollapsed(id: id, collapsed: true))
        XCTAssertTrue(store.renamePresetFolder(id: id, to: "Tablet"))
        XCTAssertEqual(store.settings.presets.map(\.id), before.presets.map(\.id))
        XCTAssertEqual(store.settings.presets.map(\.confirmed), before.presets.map(\.confirmed))
        XCTAssertEqual(store.settings.presets.map(\.displays), before.presets.map(\.displays))
        XCTAssertEqual(store.settings.presets.map(\.audio), before.presets.map(\.audio))
        XCTAssertEqual(store.settings.rules, before.rules)
        XCTAssertEqual(try SettingsFile(directory: dir).load(), store.settings)
        XCTAssertTrue(store.deletePresetFolder(id: id))
        var remaining = before.presets
        remaining[1].folderID = otherID
        XCTAssertEqual(store.settings.presets, remaining)
        XCTAssertEqual(store.settings.presetFolders?.map(\.id), [otherID])
        XCTAssertEqual(store.settings.rules, before.rules)
        XCTAssertEqual(try SettingsFile(directory: dir).load(), store.settings)
    }

    @MainActor func testFolderEditsRejectInvalidNamesAndUnknownTargetsWithoutLosingData() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir, demo: true)
        XCTAssertNil(store.createPresetFolder(name: " \n "))
        let first = try XCTUnwrap(store.createPresetFolder(name: "Desk"))
        let second = try XCTUnwrap(store.createPresetFolder(name: "Drawing"))
        XCTAssertNil(store.createPresetFolder(name: " desk "))
        let valid = store.settings
        XCTAssertFalse(store.renamePresetFolder(id: second, to: "DESK"))
        XCTAssertFalse(store.renamePresetFolder(id: first, to: ""))
        XCTAssertFalse(store.renamePresetFolder(id: UUID(), to: "Unknown"))
        XCTAssertFalse(store.movePreset(id: UUID(), to: first))
        XCTAssertFalse(store.movePreset(id: valid.presets[0].id, to: UUID()))
        XCTAssertFalse(store.setPresetFolderCollapsed(id: UUID(), collapsed: true))
        XCTAssertFalse(store.deletePresetFolder(id: UUID()))
        XCTAssertEqual(store.settings, valid)
        XCTAssertTrue(store.movePreset(id: valid.presets[0].id, to: first))
        XCTAssertTrue(store.movePreset(id: valid.presets[0].id, to: nil))
        XCTAssertNil(store.settings.presets[0].folderID)
    }

    @MainActor func testFailedFolderWriteLeavesInMemoryOrganizationUnchanged() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let blocked = dir.appendingPathComponent("file-instead-of-directory")
        try Data("fixture".utf8).write(to: blocked)
        let store = Store(directory: blocked, demo: true)
        let before = store.settings
        XCTAssertNil(store.createPresetFolder(name: "Unsaved"))
        XCTAssertEqual(store.settings, before)
        XCTAssertEqual(try Data(contentsOf: blocked), Data("fixture".utf8))
    }

    func testThumbnailPreservesPortraitAndLandscapeProportionsAtOneScale() throws {
        let displays = layout()
        let screens = PresetThumbnailGeometry.screens(for: displays, width: 80, height: 40)
        let landscape = try XCTUnwrap(screens.first { $0.id == displayA })
        let portrait = try XCTUnwrap(screens.first { $0.id == displayB })
        XCTAssertEqual(landscape.width / landscape.height, 1920.0 / 1080.0, accuracy: 0.000_001)
        XCTAssertEqual(portrait.width / portrait.height, 1080.0 / 1920.0, accuracy: 0.000_001)
        XCTAssertEqual(landscape.width / 1920, portrait.width / 1080, accuracy: 0.000_001)
        XCTAssertEqual(portrait.x, landscape.x + landscape.width, accuracy: 0.000_001)
        XCTAssertEqual(landscape.y, portrait.y, accuracy: 0.000_001)
        XCTAssertTrue(landscape.isMain); XCTAssertFalse(portrait.isMain)
    }

    func testThumbnailRetainsNegativePositionsAndCentersTheWholeLayout() throws {
        var displays = layout()
        displays[1].x = -1080
        displays[1].y = -400
        let screens = PresetThumbnailGeometry.screens(for: displays, width: 90, height: 48)
        let main = try XCTUnwrap(screens.first { $0.id == displayA })
        let left = try XCTUnwrap(screens.first { $0.id == displayB })
        XCTAssertLessThan(left.x, main.x)
        XCTAssertLessThan(left.y, main.y)
        XCTAssertEqual(left.x + left.width, main.x, accuracy: 0.000_001)
        let scale = main.width / 1920
        XCTAssertEqual(main.y - left.y, 400 * scale, accuracy: 0.000_001)
        let minX = try XCTUnwrap(screens.map(\.x).min())
        let minY = try XCTUnwrap(screens.map(\.y).min())
        let maxX = try XCTUnwrap(screens.map { $0.x + $0.width }.max())
        let maxY = try XCTUnwrap(screens.map { $0.y + $0.height }.max())
        XCTAssertEqual(minX, 90 - maxX, accuracy: 0.000_001)
        XCTAssertEqual(minY, 48 - maxY, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(minX, 3 - 0.000_001)
        XCTAssertGreaterThanOrEqual(minY, 3 - 0.000_001)
    }

    func testThumbnailDrawsMirrorsOnceCountsFollowersAndOmitsDisabledScreens() throws {
        var displays = layout()
        displays[1].mirrorOf = displayA
        displays.append(DisplaySetting(id: displayC, name: "Off", mode: DisplayMode(width: 800, height: 600), x: -800, enabled: false))
        let screens = PresetThumbnailGeometry.screens(for: displays, width: 50, height: 30)
        XCTAssertEqual(screens.count, 1)
        XCTAssertEqual(screens[0].id, displayA)
        XCTAssertEqual(screens[0].mirrorCount, 1)
        XCTAssertTrue(screens[0].isMain)
        displays[1].enabled = false
        XCTAssertEqual(PresetThumbnailGeometry.screens(for: displays, width: 50, height: 30)[0].mirrorCount, 0)
    }

    func testThumbnailHandlesInvalidAndTinyBoundsWithoutDistortingThinDisplays() throws {
        XCTAssertTrue(PresetThumbnailGeometry.screens(for: [], width: 80, height: 40).isEmpty)
        for size in [(0.0, 30.0), (6.0, 30.0), (30.0, 5.0), (-1.0, 30.0), (.infinity, 30.0), (30.0, .nan)] {
            XCTAssertTrue(PresetThumbnailGeometry.screens(for: layout(), width: size.0, height: size.1).isEmpty)
        }
        var invalid = layout()
        invalid[0].mode.width = 0
        XCTAssertTrue(PresetThumbnailGeometry.screens(for: invalid, width: 80, height: 40).isEmpty)
        invalid[0].mode.width = Int.max
        XCTAssertTrue(PresetThumbnailGeometry.screens(for: invalid, width: 80, height: 40).isEmpty)
        let thin = DisplaySetting(id: displayA, name: "Thin", mode: DisplayMode(width: 1, height: 1920))
        let screen = try XCTUnwrap(PresetThumbnailGeometry.screens(for: [thin], width: 10, height: 10).first)
        XCTAssertLessThan(screen.width, 1)
        XCTAssertEqual(screen.width / screen.height, 1.0 / 1920.0, accuracy: 0.000_000_001)
    }

    func testMultipleMonitorFilterMatchesAllOrAnySelectedIDs() {
        var a = layout()[0], b = layout()[1]
        a.name = "Same model"; b.name = "Same model"
        let c = DisplaySetting(id: displayC, name: "Tablet", mode: DisplayMode(width: 1920, height: 1080), enabled: false)
        let none = preset("No display records", displays: [])
        let laptop = preset("Laptop", displays: [a])
        let desk = preset("Laptop and portrait", displays: [a, b])
        let tablet = preset("Portrait and tablet", displays: [b, c])
        let all = preset("Every monitor", displays: [a, b, c])
        let presets = [none, laptop, desk, tablet, all]

        XCTAssertEqual(PresetOrganization.filtered(presets, monitorIDs: [displayA, displayB], matching: .all).map(\.id),
                       [desk.id, all.id])
        XCTAssertEqual(PresetOrganization.filtered(presets, monitorIDs: [displayA, displayB], matching: .any).map(\.id),
                       [laptop.id, desk.id, tablet.id, all.id])
        XCTAssertEqual(PresetOrganization.filtered(presets, monitorIDs: [displayB, displayC], matching: .all).map(\.id),
                       [tablet.id, all.id])
        XCTAssertEqual(PresetOrganization.filtered(presets, monitorIDs: [displayB, displayC], matching: .any).map(\.id),
                       [desk.id, tablet.id, all.id])
        XCTAssertEqual(PresetOrganization.filtered(presets, monitorIDs: [displayA, displayB, displayC]).map(\.id),
                       [all.id], "The default is All selected monitors")
        XCTAssertEqual(PresetOrganization.filtered(presets, monitorIDs: [displayC], matching: .all).map(\.id),
                       [tablet.id, all.id], "A disabled display record is still included in its saved preset")
    }

    func testMultipleMonitorFilterEmptySelectionAndUnknownIDs() {
        let none = preset("No records", displays: [])
        let laptop = preset("Laptop", displays: [layout()[0]])
        let desk = preset("Desk", displays: layout())
        let presets = [none, laptop, desk]
        let unknown = "00000000-0000-0000-0000-000000000099"
        for mode in PresetOrganization.MatchMode.allCases {
            XCTAssertEqual(PresetOrganization.filtered(presets, monitorIDs: [], matching: mode).map(\.id),
                           presets.map(\.id), "Clearing the selection shows every preset in either mode")
            XCTAssertTrue(PresetOrganization.filtered(presets, monitorIDs: [unknown], matching: mode).isEmpty)
        }
        XCTAssertTrue(PresetOrganization.filtered(presets, monitorIDs: [displayA, unknown], matching: .all).isEmpty)
        XCTAssertEqual(PresetOrganization.filtered(presets, monitorIDs: [displayA, unknown], matching: .any).map(\.id),
                       [laptop.id, desk.id])
    }

    func testMultipleMonitorGroupsPreserveCountsAndCollapsedVisibility() {
        let drawing = PresetFolder(name: "Drawing", collapsed: true)
        let office = PresetFolder(name: "Office")
        let empty = PresetFolder(name: "Empty")
        let a = layout()[0], b = layout()[1]
        let c = DisplaySetting(id: displayC, name: "Tablet", mode: DisplayMode(width: 1920, height: 1080))
        let laptop = preset("Laptop", displays: [a])
        let none = preset("No records", displays: [])
        let desk = preset("Desk", displays: [a, b], folder: drawing.id)
        let tablet = preset("Tablet", displays: [b, c], folder: drawing.id)
        let every = preset("Every", displays: [a, b, c], folder: office.id)
        let solo = preset("Solo tablet", displays: [c], folder: office.id)
        var settings = AppSettings()
        settings.presetFolders = [drawing, office, empty]
        settings.presets = [laptop, none, desk, tablet, every, solo]
        let allGroups = PresetOrganization.groups(settings: settings, monitorIDs: [displayA, displayB], matching: .all)
        XCTAssertEqual(allGroups.map(\.id), [drawing.id.uuidString, office.id.uuidString])
        XCTAssertEqual(allGroups.map(\.totalCount), [2, 2])
        XCTAssertEqual(allGroups.map { $0.presets.map(\.id) }, [[desk.id], [every.id]])
        XCTAssertEqual(PresetOrganization.visiblePresets(settings: settings, monitorIDs: [displayA, displayB], matching: .all).map(\.id),
                       [every.id])

        let anyGroups = PresetOrganization.groups(settings: settings, monitorIDs: [displayA, displayB], matching: .any)
        XCTAssertEqual(anyGroups.map(\.id), ["ungrouped", drawing.id.uuidString, office.id.uuidString])
        XCTAssertEqual(anyGroups.map(\.totalCount), [2, 2, 2])
        XCTAssertEqual(anyGroups.map { $0.presets.map(\.id) }, [[laptop.id], [desk.id, tablet.id], [every.id]])
        XCTAssertEqual(PresetOrganization.visiblePresets(settings: settings, monitorIDs: [displayA, displayB], matching: .any).map(\.id),
                       [laptop.id, every.id])
        for mode in PresetOrganization.MatchMode.allCases {
            XCTAssertEqual(PresetOrganization.groups(settings: settings, monitorIDs: [], matching: mode).map(\.id),
                           ["ungrouped", drawing.id.uuidString, office.id.uuidString, empty.id.uuidString])
            XCTAssertEqual(PresetOrganization.visiblePresets(settings: settings, monitorIDs: [], matching: mode).map(\.id),
                           [laptop.id, none.id, every.id, solo.id])
        }
        XCTAssertTrue(settings.presetFolders?[0].collapsed == true)
        XCTAssertEqual(settings.presets.map(\.folderID), [nil, nil, drawing.id, drawing.id, office.id, office.id])
    }

    func testSingleMonitorFilterOverloadsMatchOneItemSelection() {
        let folder = PresetFolder(name: "Desk")
        let laptop = preset("Laptop", displays: [layout()[0]])
        let desk = preset("Desk", displays: layout(), folder: folder.id)
        var settings = AppSettings()
        settings.presetFolders = [folder]
        settings.presets = [laptop, desk]
        for monitor in [nil, "", displayA, displayB, displayC] as [String?] {
            let selected: Set<String>
            if let monitor, !monitor.isEmpty { selected = [monitor] } else { selected = [] }
            let single = PresetOrganization.filtered(settings.presets, monitorID: monitor)
            let oldGroups = PresetOrganization.groups(settings: settings, monitorID: monitor)
            for mode in PresetOrganization.MatchMode.allCases {
                XCTAssertEqual(PresetOrganization.filtered(settings.presets, monitorIDs: selected, matching: mode).map(\.id),
                               single.map(\.id))
                let groups = PresetOrganization.groups(settings: settings, monitorIDs: selected, matching: mode)
                XCTAssertEqual(groups.map(\.id), oldGroups.map(\.id))
                XCTAssertEqual(groups.map { $0.presets.map(\.id) }, oldGroups.map { $0.presets.map(\.id) })
                XCTAssertEqual(groups.map(\.totalCount), oldGroups.map(\.totalCount))
                XCTAssertEqual(PresetOrganization.visiblePresets(settings: settings, monitorIDs: selected, matching: mode).map(\.id),
                               PresetOrganization.visiblePresets(settings: settings, monitorID: monitor).map(\.id))
            }
        }
    }
}
