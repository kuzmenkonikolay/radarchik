import AppKit
import SwiftUI
import RadarchikCore

/// Иконка приложения и превью ссылки для GitHub (2026-10-19, перед open source).
/// Рисуются тем же кодом, что Живая чёлка в приложении: `NotchShape`,
/// `EyeShape`, `FaceMouth`, крылья `CollapsedMascot`.
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
        else { throw MascotSheetRenderer.Failure(description: "not rendered: \(url.lastPathComponent)") }
        try data.write(to: url)
    }
}

/// Свёрнутая чёлка без моделей: крылья, состояние и взгляд заданы снаружи.
/// Рисуется так же, как в `NotchRootView`: фигура, крылья и лицо в подбородке.
struct NotchStill: View {
    var notchSize = CGSize(width: 220, height: 38)
    var leading: [WingItem] = []
    var trailing: [WingItem] = []
    var state: MascotState = .idleScan
    var signal: AntennaSignal = .green
    var gaze: CGPoint = .zero

    var body: some View {
        let shape = NotchShape.collapsed(skin: .livingNotch, notchHeight: notchSize.height)
        CollapsedMascot(skin: .livingNotch, state: state, signal: signal, gaze: gaze, notchSize: notchSize, leading: leading, trailing: trailing)
            .background(shape.fill(DS.Surface.panel))
            .overlay(alignment: .top) {
                PlacedLivingFace(
                    state: state, signal: signal, gaze: gaze, scale: FacePlacement.chin.scale,
                    eyeCenterY: FacePlacement.chin.eyeCenterY(notchHeight: notchSize.height)
                )
            }
            .clipShape(shape)
    }
}

/// Иконка по сетке macOS: скруглённый квадрат 824 из 1024 с тенью. На нём —
/// «экран» и чёрная чёлка с хитрым прищуром Радарчика, как в покое.
struct AppIconArt: View {
    private let green = Color(hex: "#19C719")

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 185, style: .continuous)
        shape
            .fill(LinearGradient(colors: [Color(hex: "#3B3FA8"), Color(hex: "#15173B")], startPoint: .top, endPoint: .bottom))
            .overlay {
                // Свечение глаз на «экране» вокруг чёлки.
                RadialGradient(colors: [green.opacity(0.30), .clear], center: UnitPoint(x: 0.5, y: 0.22), startRadius: 0, endRadius: 380)
            }
            .overlay(alignment: .top) { notch }
            .clipShape(shape)
            .frame(width: 824, height: 824)
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            .frame(width: 1_024, height: 1_024)
    }

    private var notch: some View {
        let bandHeight: CGFloat = 132
        let chin = CGSize(width: 380, height: 262)
        return ZStack(alignment: .top) {
            NotchShape(topRadius: 32, bandRadius: 40, bandHeight: bandHeight, chinWidth: chin.width, chinRadius: 104)
                .fill(Color.black)
                .frame(width: 660, height: bandHeight + chin.height)
            face.padding(.top, bandHeight + 46)
        }
    }

    private var face: some View {
        VStack(spacing: 26) {
            HStack(spacing: 86) {
                // Левый глаз прикрыт сильнее — как `EyePose` в покое.
                eye(cover: 0.38)
                eye(cover: 0.22)
            }
            FaceMouth(kind: .smirk)
                .stroke(green.opacity(0.85), style: StrokeStyle(lineWidth: 17, lineCap: .round, lineJoin: .round))
                .frame(width: 132, height: 40)
        }
    }

    private func eye(cover: CGFloat) -> some View {
        EyeShape(pose: EyePose(openness: 1, cover: cover, tilt: 0, smile: 0))
            .fill(green)
            .frame(width: 80, height: 104)
            .shadow(color: green.opacity(0.9), radius: 26)
            .shadow(color: green.opacity(0.45), radius: 66)
    }
}

/// Превью ссылки на GitHub и в соцсетях: чёлка с крыльями сверху, название и одна строка о главном.
struct SocialPreviewArt: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(hex: "#1D2033"), Color(hex: "#0B0C12")], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [DS.antenna(.green).opacity(0.22), .clear], center: UnitPoint(x: 0.5, y: 0.05), startRadius: 0, endRadius: 520)

            NotchStill(
                leading: [WingItem(id: "month", icon: "chart.bar.fill", text: "+$3.4k", color: DS.Money.positiveText)],
                trailing: [
                    WingItem(id: "cpu", icon: "cpu", text: "16%", widest: "88%"),
                    WingItem(id: "temperature", icon: "thermometer.medium", text: "54°", widest: "88°"),
                ],
                state: .idleScan, signal: .green
            )
            .scaleEffect(2.6, anchor: .top)

            VStack(spacing: 18) {
                Text("Radarchik")
                    .font(.system(size: 104, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Ink.primary)
                Text("A tiny mascot that lives in your MacBook notch")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(DS.Ink.secondary)
                Text("Project money · Mac resources · Daily tips by Claude")
                    .font(.system(size: 26))
                    .foregroundStyle(DS.Ink.muted)
                    .padding(.top, 6)
            }
            .padding(.top, 250)
        }
        .frame(width: 1_280, height: 640)
    }
}
