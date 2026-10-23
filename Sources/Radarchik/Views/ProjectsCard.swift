import SwiftUI
import RadarchikCore

/// Правая карточка главной и проекта: «Проекты» и «итог октября», сетка из
/// двух колонок пилюль высотой 42 с мини-лицом в настроении проекта, названием
/// и компактным итогом. Последняя пилюля — пунктирная «+ Проект».
struct ProjectsCard: View {
    let store: MoneyStore
    var selected: UUID?
    let onSelect: (UUID) -> Void
    let onAdd: () -> Void

    var body: some View {
        Card(vertical: 16, horizontal: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("Проекты", "Projects"))
                        .font(.bodyBold)
                        .foregroundStyle(DS.Ink.primary)
                    Spacer(minLength: 0)
                    Text(L("итог \(RussianWords.monthGenitive(store.month.month))", "\(Words.monthName(store.month.month)) so far"))
                        .font(.caption)
                        .foregroundStyle(DS.Ink.secondary)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(store.glances) { glance in
                        ProjectPill(glance: glance, net: store.monthNet(of: glance.project.id), isSelected: glance.project.id == selected) {
                            onSelect(glance.project.id)
                        }
                    }
                    AddProjectPill(action: onAdd)
                }
            }
        }
    }
}

/// Пилюля проекта: чип мини-лица 36×30, название, итог по знаку.
/// Выбранная — подсвечена цветом настроения: фон α 0.12, рамка α 0.55.
struct ProjectPill: View {
    let glance: ProjectGlance
    let net: Int64
    var isSelected = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let tone = FaceDirector.tone(glance)
        Button(action: action) {
            HStack(spacing: 7) {
                FaceChip(spec: .project(glance.mood, colorHex: glance.project.colorHex, mini: true))
                Text(glance.project.name)
                    .font(.bodySemibold)
                    .foregroundStyle(DS.Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 3)
                Text(MoneyFormat.bare(MoneyFormat.compact(net, glance.project.currency, signed: true)))
                    .font(.captionBold)
                    .monospacedDigit()
                    .foregroundStyle(DS.Money.text(for: net))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, 4)
            .padding(.trailing, 9)
            .frame(height: DS.Size.pillHeight)
            .background(RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous).fill(isSelected ? tone.opacity(0.12) : hovering ? DS.Surface.pillHover : DS.Surface.pill))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous).stroke(isSelected ? tone.opacity(0.55) : DS.Surface.pillBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.pill))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var help: String {
        let name = glance.project.name
        guard let mood = glance.mood else {
            return L("\(name): первый месяц идёт", "\(name): first month in progress")
        }
        return L("\(name): \(mood.label), по \(RussianWords.monthDative(glance.month.month))", "\(name): \(mood.label) as of \(Words.monthName(glance.month.month))")
    }
}

/// Пунктирная пилюля «+ Проект».
struct AddProjectPill: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text(L("Проект", "Project"))
            }
            .font(.bodyMedium)
            .foregroundStyle(hovering ? DS.Ink.primary : DS.Ink.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: DS.Size.pillHeight)
            .background(RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous).fill(hovering ? DS.Surface.pillHover : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.white.opacity(hovering ? 0.25 : 0.14))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.pill))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("Новый проект", "New project"))
    }
}

/// Крупная цифра: число 34 bold с трекингом −0.7, значок валюты мелко и серым рядом.
struct HeroAmount: View {
    let amount: Int64
    let currency: Currency
    var font: Font = .hero
    var symbolSize: CGFloat = 15

    var body: some View {
        let parts = Self.split(MoneyFormat.signedFull(amount, currency))
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(parts.number)
                .font(font)
                .tracking(-0.7)
                .monospacedDigit()
                .foregroundStyle(DS.Money.text(for: amount))
                .contentTransition(.numericText(value: Double(amount)))
                .lineLimit(1)
                .fixedSize()
            if let symbol = parts.symbol {
                Text(symbol)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(DS.Ink.secondary)
            }
        }
    }

    /// По-русски значок валюты стоит после суммы — отделяем его, чтобы написать мелко.
    static func split(_ text: String) -> (number: String, symbol: String?) {
        for symbol in Currency.allCases.map(\.symbol) where text.hasSuffix("\u{00A0}" + symbol) {
            return (String(text.dropLast(symbol.count + 1)), symbol)
        }
        return (text, nil)
    }
}
