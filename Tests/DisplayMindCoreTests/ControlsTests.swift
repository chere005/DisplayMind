import AppKit
import SwiftUI
import XCTest
@testable import DisplayMind

/// Native controls are inspected without creating, showing or activating a window.
final class ControlsTests: XCTestCase {
    @MainActor func testPopUpKeepsValuesAndSelectionCoherentAcrossChangingOptions() {
        var selected = "second"
        let selection = Binding(get: { selected }, set: { selected = $0 })
        var view = PopUp(label: "Display", options: [("first", "Same name"), ("second", "Same name")], selection: selection, separatesFirst: true)
        let coordinator = view.makeCoordinator()
        let native = NSPopUpButton(frame: .zero, pullsDown: false)
        view.synchronize(native, coordinator: coordinator, enabled: true, controlSize: .small)
        XCTAssertEqual(native.numberOfItems, 3, "equal titles remain distinct and retain their separator")
        XCTAssertEqual(native.selectedItem?.tag, 1)
        XCTAssertEqual(native.controlSize, .small)

        view = PopUp(label: "Display", options: [("second", "Renamed monitor"), ("third", "Another monitor")], selection: selection)
        view.synchronize(native, coordinator: coordinator, enabled: false, controlSize: .large)
        XCTAssertEqual(native.itemTitles, ["Renamed monitor", "Another monitor"])
        XCTAssertEqual(native.selectedItem?.tag, 0)
        XCTAssertFalse(native.isEnabled)
        XCTAssertEqual(native.controlSize, .large)
        native.selectItem(withTag: 1)
        coordinator.changed(native)
        XCTAssertEqual(selected, "third", "actions use the latest value list")

        view = PopUp(label: "Display", options: [("second", "Renamed monitor")], selection: selection)
        view.synchronize(native, coordinator: coordinator, enabled: true, controlSize: .regular)
        XCTAssertNil(native.selectedItem, "a removed value must not display a different monitor as selected")
        XCTAssertNil(native.toolTip)
        if #available(macOS 14.0, *) {
            view.synchronize(native, coordinator: coordinator, enabled: true, controlSize: .extraLarge)
            XCTAssertEqual(native.controlSize, .large, "AppKit's largest size is the fallback for SwiftUI extraLarge")
        }
    }

    @MainActor func testSegmentsRefreshLabelsValuesAndClearAMissingSelection() {
        var selected = 2
        let selection = Binding(get: { selected }, set: { selected = $0 })
        var view = Segments(label: "Condition", options: [(0, "Ignore"), (1, "Connected"), (2, "Absent")], selection: selection)
        let coordinator = view.makeCoordinator()
        let native = NSSegmentedControl()
        view.synchronize(native, coordinator: coordinator, enabled: true, controlSize: .small)
        XCTAssertEqual(native.segmentCount, 3)
        XCTAssertEqual(native.selectedSegment, 2)

        view = Segments(label: "Condition", options: [(2, "Missing"), (3, "Either")], selection: selection)
        view.synchronize(native, coordinator: coordinator, enabled: false, controlSize: .large)
        XCTAssertEqual(native.segmentCount, 2)
        XCTAssertEqual(native.label(forSegment: 0), "Missing")
        XCTAssertEqual(native.selectedSegment, 0)
        XCTAssertFalse(native.isEnabled)
        XCTAssertEqual(native.controlSize, .large)
        native.selectedSegment = 1
        coordinator.changed(native)
        XCTAssertEqual(selected, 3)

        view = Segments(label: "Condition", options: [(2, "Missing")], selection: selection)
        view.synchronize(native, coordinator: coordinator, enabled: true, controlSize: .regular)
        XCTAssertEqual(native.selectedSegment, -1)
    }

    @MainActor func testLongNativeControlTitlesRespectAssignedColumnWidths() {
        let long = String(repeating: "Long monitor title ", count: 6)
        let popup = PopUp(label: "Display", options: [(1, long)], selection: .constant(1))
        let nativePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.synchronize(nativePopup, coordinator: popup.makeCoordinator(), enabled: true, controlSize: .regular)
        let segments = Segments(label: "Choice", options: [(1, long), (2, long)], selection: .constant(1))
        let nativeSegments = NSSegmentedControl()
        segments.synchronize(nativeSegments, coordinator: segments.makeCoordinator(), enabled: true, controlSize: .regular)
        XCTAssertGreaterThan(nativePopup.intrinsicContentSize.width, 180)
        XCTAssertGreaterThan(nativeSegments.intrinsicContentSize.width, 180)
        XCTAssertEqual(popup.fittingSize(ProposedViewSize(width: 180, height: nil), control: nativePopup).width, 180)
        XCTAssertEqual(segments.fittingSize(ProposedViewSize(width: 180, height: nil), control: nativeSegments).width, 180)
    }
}
