import Foundation

/// Scaled extended-display bounds for a preset's small sidebar preview.
public enum PresetThumbnailGeometry {
    public struct Screen: Identifiable, Equatable {
        public let id: String
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        public let isMain: Bool
        public let mirrorCount: Int
    }

    /// Display modes already describe the saved orientation; mirrors share their source rectangle.
    public static func screens(for displays: [DisplaySetting], width: Double, height: Double) -> [Screen] {
        let inset = 3.0
        guard width.isFinite, height.isFinite, width > inset * 2, height > inset * 2 else { return [] }
        let roots = displays.filter { $0.enabled && $0.mirrorOf == nil }
        guard !roots.isEmpty, roots.allSatisfy({
            (1...32768).contains($0.mode.width) && (1...32768).contains($0.mode.height) &&
            (-100_000...100_000).contains($0.x) && (-100_000...100_000).contains($0.y)
        }) else { return [] }

        let minX = roots.map { Double($0.x) }.min()!
        let minY = roots.map { Double($0.y) }.min()!
        let maxX = roots.map { Double($0.x) + Double($0.mode.width) }.max()!
        let maxY = roots.map { Double($0.y) + Double($0.mode.height) }.max()!
        let spanWidth = maxX - minX, spanHeight = maxY - minY
        let scale = min((width - inset * 2) / spanWidth, (height - inset * 2) / spanHeight)
        guard scale.isFinite, scale > 0 else { return [] }
        let fittedWidth = spanWidth * scale, fittedHeight = spanHeight * scale
        guard fittedWidth.isFinite, fittedHeight.isFinite else { return [] }
        let originX = (width - fittedWidth) / 2
        let originY = (height - fittedHeight) / 2
        return roots.map { display in
            Screen(id: display.id, x: originX + (Double(display.x) - minX) * scale,
                   y: originY + (Double(display.y) - minY) * scale,
                   width: Double(display.mode.width) * scale, height: Double(display.mode.height) * scale,
                   isMain: display.x == 0 && display.y == 0,
                   mirrorCount: displays.filter { $0.enabled && $0.mirrorOf == display.id }.count)
        }
    }
}
