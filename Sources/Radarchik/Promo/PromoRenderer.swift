import AppKit
import AVFoundation
import CoreVideo
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import RadarchikCore

/// Ролик в MP4 и кадры в PNG — тем же кодом, что приложение (2026-10-19).
/// Ничего ставить не надо: кадры рисует ImageRenderer, кодирует AVFoundation.
///
/// - `--render-promo <файл.mp4> [--format wide|square]` — ролик, 60 кадров в секунду;
/// - `--promo-frames <папка> [--format …] [--times 1,3.5,…]` — отдельные кадры для проверки;
/// - `--render-gif <файл.gif>` — короткая петля для README: чёлка крупно, 12 кадров в секунду.
@MainActor
enum PromoRenderer {
    static let fps = 60

    static func renderVideo(to url: URL, format: PromoFormat) throws {
        Language.setAppWide(.en)
        let world = try PromoWorld()
        let size = format.size
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 16_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure(description: "can't start writing") }
        writer.startSession(atSourceTime: .zero)

        let total = Int(PromoTimeline.duration * Double(fps))
        for frame in 0..<total {
            try autoreleasepool {
                let image = try render(t: Double(frame) / Double(fps), world: world, format: format)
                while !input.isReadyForMoreMediaData {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.002))
                }
                guard let pool = adaptor.pixelBufferPool, let buffer = pixelBuffer(image, pool: pool) else {
                    throw Failure(description: "no pixel buffer for frame \(frame)")
                }
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
            }
            if frame % fps == 0 { print("\(frame / fps) s / \(Int(PromoTimeline.duration)) s") }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? Failure(description: "writing failed") }
    }

    /// Кадры в PNG — проверить вёрстку, не открывая видео.
    static func renderFrames(to folder: URL, format: PromoFormat, times: [Double]) throws {
        Language.setAppWide(.en)
        let world = try PromoWorld()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for t in times {
            let image = try render(t: t, world: world, format: format)
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            try data.write(to: folder.appendingPathComponent(String(format: "frame-%05.2f.png", t)))
        }
    }

    /// Петля для README: от пробуждения до раскрытой сводки, чёлка крупно,
    /// без обоев (на однотонном фоне GIF намного меньше).
    static func renderGIF(to url: URL) throws {
        Language.setAppWide(.en)
        let world = try PromoWorld()
        let gifFPS = 12
        let range = (start: 2.3, end: 14.6)
        let count = Int((range.end - range.start) * Double(gifFPS))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw Failure(description: "can't create GIF")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(gifFPS)]] as CFDictionary
        for index in 0..<count {
            try autoreleasepool {
                let t = range.start + Double(index) / Double(gifFPS)
                world.show(PromoTimeline.pose(at: t, format: .wide).shownRoute)
                let renderer = ImageRenderer(content: PromoLoopFrame(t: t, world: world))
                renderer.scale = 1
                guard let image = renderer.cgImage else { throw Failure(description: "GIF frame \(index) not rendered") }
                CGImageDestinationAddImage(destination, image, frameProperties)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "GIF not written") }
    }

    private static func render(t: Double, world: PromoWorld, format: PromoFormat) throws -> CGImage {
        world.show(PromoTimeline.pose(at: t, format: format).shownRoute)
        let renderer = ImageRenderer(content: PromoFrame(t: t, world: world, format: format))
        renderer.scale = 1
        guard let image = renderer.cgImage else { throw Failure(description: "frame at \(t) s not rendered") }
        return image
    }

    private static func pixelBuffer(_ image: CGImage, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
}

/// Кадр петли для README: только чёлка крупно, на однотонном тёмном фоне.
private struct PromoLoopFrame: View {
    let t: Double
    let world: PromoWorld

    var body: some View {
        let pose = PromoTimeline.pose(at: t, format: .wide)
        // Свёрнутая с крыльями — во всю ширину; панель раскрыта — камера отъезжает, чтобы она влезла.
        let zoom = lerp(1.5, 1.18, Ease.smooth(Ease.clamp01(pose.expand)))
        ZStack(alignment: .top) {
            Color(hex: "#272B35")
            PromoLoopScreen(pose: pose, world: world)
                .frame(width: PromoWorld.screen.width, height: 620, alignment: .top)
                .scaleEffect(zoom, anchor: .top)
                .frame(width: 720, height: 560, alignment: .top)
        }
        .frame(width: 720, height: 560)
        .clipped()
        .environment(\.colorScheme, .dark)
        .environment(\.unrollsScrolling, true)
    }
}

private struct PromoLoopScreen: View {
    let pose: PromoPose
    let world: PromoWorld

    var body: some View {
        PromoNotchView(pose: pose, world: world)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}
