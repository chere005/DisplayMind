import SwiftUI
import DisplayMindCore

/// A miniature of the saved layout, independent of which displays happen to be connected.
struct PresetThumbnail: View {
    let displays: [DisplaySetting]
    var selected = false

    var body: some View {
        Canvas { context, size in
            let screens = PresetThumbnailGeometry.screens(for: displays, width: size.width, height: size.height)
            for screen in screens {
                let rect = CGRect(x: screen.x, y: screen.y, width: screen.width, height: screen.height)
                let radius = min(2, min(rect.width, rect.height) / 6)
                if screen.mirrorCount > 0 {
                    let behind = Path(roundedRect: rect.offsetBy(dx: 1.5, dy: 1.5), cornerRadius: radius)
                    context.stroke(behind, with: .color(Branding.text.opacity(0.8)), lineWidth: 0.8)
                }
                let outline = Path(roundedRect: rect, cornerRadius: radius)
                context.fill(outline, with: .color(screen.isMain ? Branding.fill : Branding.text.opacity(selected ? 0.42 : 0.28)))
                context.stroke(outline, with: .color(screen.isMain ? Branding.text : Color.secondary.opacity(0.65)), lineWidth: 0.7)
                if screen.isMain, rect.width > 5, rect.height > 5 {
                    let bar = CGRect(x: rect.midX - rect.width * 0.22, y: rect.minY + 1.5, width: rect.width * 0.44, height: 1)
                    context.fill(Path(roundedRect: bar, cornerRadius: 0.5), with: .color(.white.opacity(0.9)))
                }
            }
            if screens.isEmpty {
                let outline = Path(roundedRect: CGRect(x: 14, y: 8, width: 28, height: 20), cornerRadius: 2)
                context.stroke(outline, with: .color(Color.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(width: 56, height: 36)
        .accessibilityHidden(true)
    }
}
