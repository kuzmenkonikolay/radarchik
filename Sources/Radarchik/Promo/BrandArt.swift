import AppKit
import SwiftUI
import RadarchikCore

/// Иконка приложения и превью ссылки для GitHub (2026-10-19, перед open source).
/// Рисуются тем же кодом, что лицо в приложении (`FaceCanvas`, `PanelShape`).
///
/// - `--render-icon <папка>` — AppIcon.iconset; дальше `iconutil -c icns`.
/// - `--render-social <файл.png>` — превью ссылки 1280×640.
@MainActor
enum BrandRenderer {
    static func renderIcon(to folder: URL) throws {
        let iconset = folder.appendingPathComponent("AppIcon.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                try PNG.write(AppIconArt(), size: CGSize(width: 1_024, height: 1_024), pixelsWide: size * scale, to: iconset.appendingPathComponent(name))
            }
        }
    }

    static func renderSocial(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PNG.write(SocialPreviewArt(), size: CGSize(width: 1_280, height: 640), pixelsWide: 1_280, to: file)
    }
}

/// Картинка в PNG нужного размера в пикселях: вид рисуется векторно, поэтому
/// и 16, и 1024 пикселя получаются чёткими.
@MainActor
enum PNG {
    static func write(_ view: some View, size: CGSize, pixelsWide: Int, to url: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        renderer.scale = CGFloat(pixelsWide) / size.width
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw RenderFailure(description: "not rendered: \(url.lastPathComponent)") }
        try data.write(to: url)
    }
}

/// Свёрнутая чёлка без моделей: полоска с лицом слева и цифрами.
struct NotchStill: View {
    var notchSize = CGSize(width: 220, height: 38)
    var leading: [WingItem] = []
    var trailing: [WingItem] = []
    var spec: FaceSpec = .main(.smug, tone: DS.Tone.plus)
    var gaze: CGPoint = .zero

    var body: some View {
        let shape = PanelShape(topRadius: 6, bottomRadius: DS.Radius.collapsed)
        HStack(spacing: 8) {
            FaceCanvas(geometry: FaceGeometry(spec), look: gaze)
                .frame(width: DS.Size.collapsedHeight, height: DS.Size.collapsedHeight * 2 / 3)
            HStack(spacing: 8) { ForEach(leading) { WingItemView(item: $0) } }
            Spacer(minLength: notchSize.width + 24)
            HStack(spacing: 8) { ForEach(trailing) { WingItemView(item: $0) } }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: DS.Size.collapsedWidth)
        .frame(height: notchSize.height + 2)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .background(shape.fill(Color.black))
        .clipShape(shape)
    }
}

/// Иконка по сетке macOS: скруглённый квадрат 824 из 1024 с тенью. На нём —
/// «экран» и чёрная чёлка с прищуром Радарчика, как в покое.
struct AppIconArt: View {
    private let green = DS.Tone.plus

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 185, style: .continuous)
        shape
            .fill(LinearGradient(colors: [Color(hex: "#2E3270"), Color(hex: "#111327")], startPoint: .top, endPoint: .bottom))
            .overlay {
                // Свечение лица на «экране» вокруг чёлки.
                RadialGradient(colors: [green.opacity(0.30), .clear], center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 400)
            }
            .overlay(alignment: .top) { notch }
            .clipShape(shape)
            .frame(width: 824, height: 824)
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            .frame(width: 1_024, height: 1_024)
    }

    private var notch: some View {
        ZStack(alignment: .top) {
            PanelShape(topRadius: 40, bottomRadius: 120)
                .fill(Color.black)
                .frame(width: 700, height: 420)
            FaceCanvas(geometry: FaceGeometry(.main(.smug, tone: green)))
                .frame(width: 420, height: 280)
                .padding(.top, 70)
        }
    }
}

/// Превью ссылки на GitHub и в соцсетях: чёлка с крыльями сверху, название и одна строка о главном.
struct SocialPreviewArt: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(hex: "#1D2033"), Color(hex: "#0B0C12")], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [DS.Tone.plus.opacity(0.22), .clear], center: UnitPoint(x: 0.5, y: 0.05), startRadius: 0, endRadius: 520)

            NotchStill(
                leading: [WingItem(id: "month", icon: nil, text: "+$3.4k", color: DS.Money.positiveText)],
                trailing: [
                    WingItem(id: "cpu", icon: "cpu", text: "16%", widest: "88%"),
                    WingItem(id: "temperature", icon: "thermometer.medium", text: "54°", widest: "88°"),
                ]
            )
            .scaleEffect(2.4, anchor: .top)

            VStack(spacing: 18) {
                Text("Radarchik")
                    .font(.system(size: 104, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Ink.primary)
                Text("A tiny mascot that lives in your MacBook notch")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(DS.Ink.secondary)
                Text("Project money · Mac resources · Daily tips by Claude")
                    .font(.system(size: 26))
                    .foregroundStyle(DS.Ink.secondary)
                    .padding(.top, 6)
            }
            .padding(.top, 250)
        }
        .frame(width: 1_280, height: 640)
    }
}
