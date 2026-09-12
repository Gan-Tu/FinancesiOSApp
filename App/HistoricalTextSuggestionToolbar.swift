import SwiftUI

/// A single keyboard accessory row; never inserts content into the editor form.
struct HistoricalTextSuggestionToolbar: View {
    @ObservedObject var cache: HistoricalTextSuggestionCache
    let data: JournalData
    let ledgerID: UUID
    let field: HistoricalTextSuggestionField
    let query: String
    let select: (String) -> Void
    let done: () -> Void

    private struct Request: Hashable {
        let ledgerID: UUID
        let field: HistoricalTextSuggestionField
        let query: String
        let revision: UInt64
    }
    @State private var loadedRequest: Request?
    @State private var suggestions: [HistoricalTextSuggestion] = []
    @State private var activeLoadID = UUID()

    private var request: Request {
        Request(ledgerID: ledgerID, field: field, query: query, revision: cache.revision)
    }

    var body: some View {
        let requested = request
        HStack(spacing: 3) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    if loadedRequest == requested {
                        ForEach(Array(suggestions.enumerated()), id: \.element.text) { index, suggestion in
                            Button {
                                guard loadedRequest == requested, cache.revision == requested.revision else { return }
                                select(suggestion.text)
                            } label: {
                                Text(suggestion.text)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(.horizontal, 12)
                                    .frame(maxWidth: 220, minHeight: 32)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(suggestion.text)
                            .accessibilityHint(field == .note ? "Use this previous note" : "Use this previous payee")
                            .accessibilityIdentifier("history-\(field.rawValue)-suggestion-\(index)")
                        }
                    } else if !cache.hasCachedIndex(for: ledgerID) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.secondary)
                            .frame(width: 44, height: 44)
                            .accessibilityLabel("Loading suggestions")
                    }
                }
                .frame(minHeight: 44)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.never)
            .id(requested) // A new query starts at the highest-ranked chip.
            .accessibilityIdentifier("historical-suggestion-strip")
            .frame(maxWidth: .infinity)
            Button(action: done) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 20)).frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done")
        }
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
        .task(id: requested) {
            let loadID = UUID()
            activeLoadID = loadID
            do {
                let result = try await cache.suggestions(data: data, ledgerID: requested.ledgerID,
                    field: requested.field, query: requested.query, revision: requested.revision, limit: 5)
                guard !Task.isCancelled, activeLoadID == loadID, cache.revision == requested.revision else { return }
                suggestions = result
                loadedRequest = requested
            } catch {
                guard !Task.isCancelled, activeLoadID == loadID else { return }
                suggestions = []
                loadedRequest = nil
            }
        }
    }
}
