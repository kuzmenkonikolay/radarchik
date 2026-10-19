import SwiftUI
import RadarchikCore

/// «Разбор дня и Claude»: ключ API (в Связке ключей), модель, время разбора,
/// отправлять ли заголовки окон, прокси и «Проверить связь».
struct ClaudeSettingsView: View {
    let model: NotchViewModel
    let review: ReviewService
    @Bindable var settings: AppSettings

    @State private var keyText = ""
    private enum Field { case key, proxy }
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            PanelHeader(title: L("Разбор дня и Claude", "Daily review & Claude"), onBack: { model.pop() })
            FitOrScroll(maxHeight: 600) {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    key
                    FormRow(L("Модель", "Model")) {
                        SegmentedPicker(selection: $settings.claudeModel) { $0.title }
                    }
                    Hint(settings.claudeModel.note).padding(.leading, DS.Size.formLabel + DS.Spacing.xs)

                    FormRow(L("Время разбора", "Review time")) { HourStepper(hour: $settings.reviewHour) }
                    Hint(L("Если в это время мак спал — разберу при первой активности после.",
                           "If the Mac was asleep then, I’ll review at the first activity after."))
                        .padding(.leading, DS.Size.formLabel + DS.Spacing.xs)

                    FormRow(L("Заголовки окон", "Window titles")) {
                        Toggle(isOn: $settings.sendWindowTitles) {
                            Text(L("Отправлять в Claude", "Send to Claude"))
                                .font(.system(size: 13))
                                .foregroundStyle(DS.Ink.primary)
                        }
                        .toggleStyle(.panel)
                    }
                    Hint(settings.sendWindowTitles
                        ? L("Уходят 15 самых долгих заголовков. С ними советы точнее. Окна из исключений и инкогнито не уходят никогда.",
                            "The 15 longest-viewed titles are sent. Tips get more precise with them. Excluded and incognito windows are never sent.")
                        : L("Заголовки не уходят: только приложения, сайты и шаблоны команд.",
                            "No titles are sent: only apps, sites and command templates."))
                        .padding(.leading, DS.Size.formLabel + DS.Spacing.xs)

                    proxy
                }
            }
        }
    }

    @ViewBuilder
    private var key: some View {
        FormRow(L("Ключ API", "API key")) {
            if review.hasAPIKey {
                HStack(spacing: DS.Spacing.xs) {
                    Label(L("сохранён в Связке ключей", "saved in Keychain"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Ink.secondary)
                    Spacer(minLength: 0)
                    PillButton(L("Удалить", "Delete")) { review.deleteAPIKey() }
                }
            } else {
                HStack(spacing: DS.Spacing.xs) {
                    PanelSecureField("sk-ant-…", text: $keyText, isFocused: focus == .key)
                        .focused($focus, equals: .key)
                        .onSubmit(saveKey)
                    PillButton(L("Сохранить", "Save"), prominent: true) { saveKey() }
                        .disabled(keyText.trimmedOrNil == nil)
                }
            }
        }
        if !review.hasAPIKey {
            Hint(L("Ключ создаётся на console.anthropic.com → API Keys. Хранится только в Связке ключей этого мака.",
                   "Create a key at console.anthropic.com → API Keys. It’s stored only in this Mac’s Keychain."))
                .padding(.leading, DS.Size.formLabel + DS.Spacing.xs)
        }
    }

    @ViewBuilder
    private var proxy: some View {
        FormRow(L("Прокси", "Proxy")) {
            HStack(spacing: DS.Spacing.xs) {
                PanelTextField(L("не нужен", "not needed"), text: $settings.proxyAddress, isFocused: focus == .proxy)
                    .focused($focus, equals: .proxy)
                PillButton(review.isCheckingConnection ? L("Проверяю…", "Checking…") : L("Проверить связь", "Test connection")) {
                    Task { await review.checkConnection() }
                }
                .disabled(review.isCheckingConnection)
            }
        }
        if let status = review.connectionStatus {
            Hint(status).padding(.leading, DS.Size.formLabel + DS.Spacing.xs)
        }
        Hint(proxyHint)
            .padding(.leading, DS.Size.formLabel + DS.Spacing.xs)
    }

    /// С адресом запросы идут только через прокси; пусто — напрямую.
    private var proxyHint: String {
        if case .proxy? = ClaudeRoute.parse(settings.proxyAddress) {
            return L("Все запросы к Claude идут только через этот прокси. Если он не отвечает — разбор подождёт.",
                     "All Claude requests go through this proxy only. If it’s down, the review waits.")
        }
        return L("Пусто — напрямую. Нужен прокси — впиши адрес вида http://127.0.0.1:8888, и запросы пойдут только через него.",
                 "Empty means direct. Need a proxy? Enter an address like http://127.0.0.1:8888 and requests will go only through it.")
    }

    private func saveKey() {
        review.saveAPIKey(keyText)
        keyText = ""
    }
}
