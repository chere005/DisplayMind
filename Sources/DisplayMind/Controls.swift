import AppKit
import SwiftUI

/// A pop-up button that takes the width it is given and truncates its title.
/// SwiftUI's menu-style Picker is always as wide as its longest item, so a row of them has ragged edges and a long name overflows its column.
struct PopUp<Value: Hashable>: NSViewRepresentable {
    let label: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    /// Draws a separator under the first option ("Don’t change", "Extended display").
    var separatesFirst = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        (button.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map(\.title)
        if context.coordinator.titles != titles || context.coordinator.separatesFirst != separatesFirst {
            context.coordinator.titles = titles; context.coordinator.separatesFirst = separatesFirst
            button.removeAllItems()
            for (index, title) in titles.enumerated() {
                // Items are added through the menu so two displays with the same name both stay listed.
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.tag = index
                button.menu?.addItem(item)
                if index == 0, separatesFirst, titles.count > 1 { button.menu?.addItem(.separator()) }
            }
        }
        if let index = options.firstIndex(where: { $0.value == selection }) { button.selectItem(withTag: index) }
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel(label)
        button.toolTip = options.first { $0.value == selection }?.title
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let natural = nsView.intrinsicContentSize
        return CGSize(width: max(60, proposal.width ?? natural.width), height: natural.height)
    }
    final class Coordinator: NSObject {
        var parent: PopUp
        var titles: [String] = []
        var separatesFirst = false
        init(_ parent: PopUp) { self.parent = parent }
        @MainActor @objc func changed(_ sender: NSPopUpButton) {
            guard let index = sender.selectedItem?.tag, parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index].value
        }
    }
}

/// A segmented control whose segments share the width it is given.
struct Segments<Value: Hashable>: NSViewRepresentable {
    let label: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: options.map(\.title), trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = options.firstIndex { $0.value == selection } ?? -1
        control.isEnabled = context.environment.isEnabled
        control.setAccessibilityLabel(label)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let natural = nsView.intrinsicContentSize
        return CGSize(width: max(natural.width, proposal.width ?? natural.width), height: natural.height)
    }
    final class Coordinator: NSObject {
        var parent: Segments
        init(_ parent: Segments) { self.parent = parent }
        @MainActor @objc func changed(_ sender: NSSegmentedControl) {
            guard parent.options.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.options[sender.selectedSegment].value
        }
    }
}
