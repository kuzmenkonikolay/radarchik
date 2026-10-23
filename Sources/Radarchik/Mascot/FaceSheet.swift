import AppKit
import SwiftUI
import RadarchikCore

/// Лист эмоций (проверка этапа 2 дизайна v2) и лицо во всех размерах — для
/// моей проверки рисовки (я экран не вижу, а PNG — вижу).
///
/// Запуск: `.build/debug/Radarchik --render-mascots <папка> [--language en|ru]` — рисует
/// и выходит, панель не создаётся. По-английски лист эмоций идёт в case study на Contra.
@MainActor
enum MascotSheetRenderer {
    typealias Failure = RenderFailure

    static func render(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(EmotionsSheet(), to: folder.appendingPathComponent("emotions.png"))
        try write(SizesSheet(), to: folder.appendingPathComponent("sizes.png"))
    }

    private static func write(_ view: some View, to url: URL) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw Failure(description: "не отрисовалось: \(url.lastPathComponent)") }
        try data.write(to: url)
    }
}

/// «Лист эмоций» из мокапа: восемь карточек, в каждой лицо 120 и подпись.
struct EmotionsSheet: View {
    private struct Item {
        let spec: FaceSpec
        let title: String
        let caption: String
    }

    private var items: [Item] {
        [
            Item(spec: .main(.smug, tone: DS.Tone.info), title: L("Прищур", "Squint"), caption: L("по умолчанию — «я всё записал»", "by default — “I’ve logged it all”")),
            Item(spec: .main(.happy, tone: DS.Tone.plus), title: L("Доволен", "Happy"), caption: L("месяц в плюсе и растёт", "the month is in profit and growing")),
            Item(spec: .main(.worried, tone: DS.Tone.tips), title: L("Переживает", "Worried"), caption: L("проект проседает", "a project is slipping")),
            Item(spec: .main(.sad, tone: DS.Tone.minus), title: L("Грустит", "Sad"), caption: L("проект в минусе", "a project is in the red")),
            Item(spec: .main(.squint, tone: DS.Tone.asleep), title: L("Записал", "Noted"), caption: L("заметил, что ты делаешь руками одно и то же", "saw you doing the same thing by hand")),
            Item(spec: .main(.wide, tone: DS.Tone.face), title: L("Заметил", "Noticed"), caption: L("навёл курсор или пора платить", "the cursor is on it, or it’s time to pay")),
            Item(spec: .main(.sleep, tone: DS.Tone.dim), title: L("Спит", "Asleep"), caption: L("ночь или ты отошёл от компа", "night, or you stepped away")),
            Item(spec: .main(.smug, tone: DS.Tone.tips, hands: .wave, glasses: true), title: L("Советы готовы", "Tips ready"), caption: L("надел очки и машет", "puts on glasses and waves")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Лист эмоций", "Faces"))
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(DS.Ink.primary)
            Text(L("Только глаза и рот: эмоцию делают форма и наклон век. Цвет свечения показывает состояние денег.",
                   "Only eyes and a mouth: the shape and tilt of the lids make the emotion. The glow shows how the money is doing."))
                .font(.system(size: 14))
                .foregroundStyle(DS.Ink.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(220), spacing: 16), count: 4), spacing: 16) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Card(vertical: 24, horizontal: 16) {
                        VStack(spacing: 18) {
                            FaceCanvas(geometry: FaceGeometry(item.spec))
                                .frame(width: 120, height: 80)
                            VStack(spacing: 6) {
                                Text(item.title)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(DS.Ink.primary)
                                Text(item.caption)
                                    .font(.system(size: 12))
                                    .foregroundStyle(DS.Ink.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(32)
        .background(Color.black)
    }
}

/// Лицо во всех размерах, с ручками и моргающее — чтобы видеть, что мелкие
/// размеры читаются, а веки закрываются ровно.
struct SizesSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom, spacing: 24) {
                ForEach([120, 34, 30, 24, 22] as [CGFloat], id: \.self) { size in
                    VStack(spacing: 8) {
                        FaceCanvas(geometry: FaceGeometry(.main(.smug, tone: DS.Tone.plus)))
                            .frame(width: size, height: size * 2 / 3)
                        Text("\(Int(size))").font(.system(size: 11)).foregroundStyle(DS.Ink.secondary)
                    }
                }
                ForEach([(HandsMode.down, "down"), (.wave, "wave"), (.up, "up")], id: \.1) { hands, name in
                    VStack(spacing: 8) {
                        FaceCanvas(geometry: FaceGeometry(.main(.happy, tone: DS.Tone.plus, hands: hands)))
                            .frame(width: 120, height: 80)
                        Text(name).font(.system(size: 11)).foregroundStyle(DS.Ink.secondary)
                    }
                }
            }
            HStack(spacing: 24) {
                ForEach([0, 0.5, 1] as [Double], id: \.self) { blink in
                    VStack(spacing: 8) {
                        FaceCanvas(geometry: FaceGeometry(.main(.wide, tone: DS.Tone.info)), blink: blink)
                            .frame(width: 120, height: 80)
                        Text("blink \(blink)").font(.system(size: 11)).foregroundStyle(DS.Ink.secondary)
                    }
                }
                ForEach([CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 1)], id: \.x) { look in
                    VStack(spacing: 8) {
                        FaceCanvas(geometry: FaceGeometry(.main(.smug, tone: DS.Tone.tips)), look: look)
                            .frame(width: 120, height: 80)
                        Text("look \(Int(look.x)),\(Int(look.y))").font(.system(size: 11)).foregroundStyle(DS.Ink.secondary)
                    }
                }
                HStack(spacing: 10) {
                    ForEach(Array(DS.projectColors.enumerated()), id: \.offset) { index, hex in
                        FaceChip(spec: .mini(FaceEmotion.allCases[index % FaceEmotion.allCases.count], color: Color(hex: hex)))
                    }
                }
            }
        }
        .padding(32)
        .background(Color.black)
    }
}
