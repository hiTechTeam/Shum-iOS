#if os(iOS)
import SwiftUI

/// Search uses the same directory and navigation path as the ordinary chat list.
enum ShumChatSearch {
    static func matches(_ query: String, name: String, messages: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return false }
        return ([name] + messages).contains { text in
            words.allSatisfy { text.localizedStandardContains($0) }
        }
    }
}

struct ShumChatHeaderLayout: Equatable {
    static let searchHeight: CGFloat = 54
    let offset: CGFloat

    var collapse: CGFloat { min(Self.searchHeight, max(0, offset)) }
    var pull: CGFloat { max(0, -offset) }
    var searchHeight: CGFloat { Self.searchHeight - collapse }
    var fieldHeight: CGFloat { max(0, 44 - collapse * 60 / Self.searchHeight) }
    var contentOpacity: CGFloat { min(1, max(0, (fieldHeight - 34) / 10)) }
    var fieldOpacity: CGFloat { min(1, fieldHeight / 13) }
}

/// The collapsed control remains part of the scrollable chat header.
struct ShumChatSearchBar: View {
    let layout: ShumChatHeaderLayout
    let activate: () -> Void

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text("Поиск")
            }
            .font(.system(size: 17))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: layout.fieldHeight)
            .opacity(layout.contentOpacity)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .opacity(layout.fieldOpacity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("shum.chatSearch.activate")
    }
}

/// Search is an in-place layer of the chat root, not a UIKit search presentation.
/// A result can therefore push through exactly the same NavigationStack as a row.
struct ShumChatSearchOverlay: View {
    @ObservedObject var runtime: ShumRuntime
    @Binding var query: String
    let close: () -> Void
    let open: (ShumUIRoute) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Поиск", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .accessibilityIdentifier("shum.chatSearch.field")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Очистить поиск")
                    }
                }
                .font(.system(size: 17))
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 18))

                Button("Отмена", action: close)
                    .font(.system(size: 17))
                    .accessibilityIdentifier("shum.chatSearch.cancel")
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)

            ShumChatSearchResults(runtime: runtime, query: query, open: open)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ShumThemeCanvas().ignoresSafeArea())
        .onAppear {
            DispatchQueue.main.async { searchFocused = true }
        }
    }
}

private struct ShumChatSearchResults: View {
    @ObservedObject var runtime: ShumRuntime
    let query: String
    let open: (ShumUIRoute) -> Void

    private var results: [ShumDirectoryEntry] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return runtime.directoryEntries.filter { entry in
            entry.belongs(to: .all) && ShumChatSearch.matches(
                query,
                name: entry.peer.name,
                messages: runtime.conversation(entry.id).map(\.text)
            )
        }
    }

    var body: some View {
        ShumDirectoryList(runtime: runtime, folder: .all, entries: results, open: open) {
            EmptyView()
        } empty: {
            VStack(spacing: 8) {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "Поиск в чатах" : "Ничего не найдено")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("По имени или тексту сообщений")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .multilineTextAlignment(.center)
        }
    }
}
#endif
