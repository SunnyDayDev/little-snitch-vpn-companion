import SwiftUI
import UniformTypeIdentifiers

/// Окно журнала (ФТ-6). Состав и метрики — по макету `design/app.pen`, лист
/// «Журнал»: тулбар с фильтром и экспортом, таблица из пяти колонок,
/// футер со счётчиком и ссылкой очистки.
@MainActor
struct JournalWindow: View {
    @Environment(AppModel.self) private var model
    @State private var filter = 0
    @State private var isExporting = false

    private static let filters: [(title: String, category: JournalEvent.Category?)] = [
        ("Все", nil),
        ("Переходы", .transition),
        ("Действия", .action),
        ("Ошибки", .error),
    ]

    /// Лимит — свойство отображения, применяется ПОСЛЕ фильтра: шумная
    /// категория не должна голодить редкую (см. JournalDisplay).
    private static let displayLimit = 2000

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            DSSeparator()
            content
        }
        .frame(width: DSMetrics.Journal.width, height: DSMetrics.Journal.height)
        .background(DSColor.bgWindow)
        .task { await model.refreshJournal() }
        .fileExporter(isPresented: $isExporting,
                      document: JournalDocument(text: exportText),
                      contentType: .plainText,
                      defaultFilename: "journal.txt") { _ in }
    }

    private var toolbar: some View {
        HStack(spacing: DSMetrics.Journal.contentGap) {
            DSSegmentedControl(titles: Self.filters.map(\.title), selection: $filter)
            Spacer()
            DSSecondaryButton("Экспорт…") { isExporting = true }
        }
        .padding(DSMetrics.Journal.toolbarPadding)
        .background(DSColor.bgWindow)
    }

    private var content: some View {
        let slice = self.slice
        return VStack(spacing: DSMetrics.Journal.contentGap) {
            VStack(spacing: 0) {
                JournalHeaderRow()
                DSSeparator()
                if slice.events.isEmpty {
                    Text("Записей нет")
                        .font(DSFont.secondary)
                        .foregroundStyle(DSColor.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DSMetrics.Table.horizontalPadding)
                        .padding(.vertical, DSMetrics.Table.rowVerticalPadding)
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(slice.events.enumerated()), id: \.offset) { index, event in
                                if index > 0 { DSSeparator() }
                                JournalRow(event: event)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(DSColor.bgCard, in: RoundedRectangle(cornerRadius: DSRadius.lg))

            HStack {
                Text(counterText(for: slice))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textTertiary)
                Spacer()
                DSLinkButton("Очистить журнал") {
                    Task { await model.clearJournal() }
                }
            }
        }
        .padding(DSMetrics.Journal.contentPadding)
    }

    private func counterText(for slice: JournalDisplay.Slice) -> String {
        slice.isTruncated
            ? "показаны последние \(slice.events.count) из \(slice.totalMatching) · хранятся 7 дней"
            : "\(slice.totalMatching) событий · хранятся 7 дней"
    }

    private var slice: JournalDisplay.Slice {
        JournalDisplay.slice(of: model.journalEvents,
                             category: Self.filters[filter].category,
                             limit: Self.displayLimit)
    }

    /// Экспортируем весь журнал, а не только показанные строки: фильтр — это
    /// про чтение на экране, а выгрузка нужна целиком.
    private var exportText: String {
        model.journalExportText
    }
}

@MainActor
private struct JournalHeaderRow: View {
    var body: some View {
        HStack(spacing: DSMetrics.Table.columnGap) {
            column("Время", width: DSMetrics.Journal.timeColumn)
            column("Триггер", width: DSMetrics.Journal.triggerColumn)
            column("Egress", width: DSMetrics.Journal.egressColumn)
            column("Событие", width: DSMetrics.Journal.eventColumn)
            column("Действие", width: DSMetrics.Journal.actionColumn)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DSMetrics.Table.horizontalPadding)
        .padding(.vertical, DSMetrics.Table.headerVerticalPadding)
    }

    private func column(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(DSFont.sectionCaption)
            .textCase(.uppercase)
            .foregroundStyle(DSColor.textTertiary)
            .frame(width: width, alignment: .leading)
    }
}

@MainActor
private struct JournalRow: View {
    let event: JournalEvent

    var body: some View {
        HStack(alignment: .top, spacing: DSMetrics.Table.columnGap) {
            Text(JournalFormatting.time(event.time))
                .font(DSFont.secondary)
                .foregroundStyle(DSColor.textSecondary)
                .frame(width: DSMetrics.Journal.timeColumn, alignment: .leading)

            Text(event.trigger.map(JournalFormatting.trigger) ?? "—")
                .font(DSFont.secondary)
                .foregroundStyle(DSColor.textSecondary)
                .frame(width: DSMetrics.Journal.triggerColumn, alignment: .leading)

            Text(event.egressIP ?? "—")
                .font(DSFont.mono)
                .foregroundStyle(DSColor.textSecondary)
                .frame(width: DSMetrics.Journal.egressColumn, alignment: .leading)

            // Событие — единственная цветная ячейка: переходы и ошибки должны
            // выхватываться глазом при скролле журнала. Текст ошибки от LS
            // бывает в несколько абзацев — ограничиваем строки, чтобы одна
            // запись не растягивала таблицу на пол-экрана; полный текст
            // остаётся в подсказке и в экспорте.
            Text(JournalFormatting.kind(event.kind))
                .font(.system(size: 12, weight: isEmphasised ? .semibold : .regular))
                .foregroundStyle(eventColor)
                .lineLimit(3)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .help(JournalFormatting.kind(event.kind))
                .frame(width: DSMetrics.Journal.eventColumn, alignment: .leading)

            Text(event.action ?? "—")
                .font(DSFont.secondary)
                .foregroundStyle(DSColor.textSecondary)
                .lineLimit(3)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .help(event.action ?? "")
                .frame(width: DSMetrics.Journal.actionColumn, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DSMetrics.Table.horizontalPadding)
        .padding(.vertical, DSMetrics.Table.journalRowVerticalPadding)
    }

    private var isEmphasised: Bool {
        switch event.kind {
        case .transition, .error, .warning: true
        case .action, .fact: false
        }
    }

    private var eventColor: Color {
        switch event.kind {
        case .transition(_, let to):
            switch to {
            case .leak: DSColor.danger
            case .protected: DSColor.ok
            case .offline: DSColor.muted
            case .checking: DSColor.warn
            case .paused: DSColor.warn
            }
        case .error: DSColor.danger
        case .warning: DSColor.warn
        case .action, .fact: DSColor.textPrimary
        }
    }
}

/// Экспорт журнала в текстовый файл.
struct JournalDocument: FileDocument {
    static let readableContentTypes = [UTType.plainText]

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
