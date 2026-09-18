import InlineUI
import SwiftUI
import TextProcessing

struct ReactionEmojiPickerSheet: View {
  let selectedEmojis: Set<String>
  let onSelect: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var query = ""
  @State private var didSelect = false
  @FocusState private var isSearchFocused: Bool

  private let skinTone = EmojiSkinTonePreferenceStore.current()
  private let frequentItems: [EmojiPickerItem] = {
    let counts = ReactionPickerEmojiUsageStore.usageCounts()
    let skinTone = EmojiSkinTonePreferenceStore.current()
    var seen = Set<String>()
    return ReactionPickerEmojiUsageStore.suggestedEmojis(limit: 28)
      .compactMap { emoji in
        let preferredEmoji = skinTone.applying(to: emoji)
        guard counts[emoji, default: 0] > 0, seen.insert(preferredEmoji).inserted else { return nil }
        return EmojiPickerItem(emoji: preferredEmoji, shortcode: preferredEmoji, label: preferredEmoji)
      }
  }()

  private let columns = [GridItem(.adaptive(minimum: 44), spacing: 4)]

  private var sections: [EmojiPickerSection] {
    let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !search.isEmpty {
      return [EmojiPickerSection(
        id: "search", title: "Search Results",
        items: EmojiPickerData.suggestions(matching: search, limit: 200)
      )]
    }
    let frequent = frequentItems.isEmpty ? [] : [EmojiPickerSection(
      id: "frequent", title: "Frequently Used", items: frequentItems
    )]
    return frequent + EmojiPickerData.defaultSections
  }

  var body: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVGrid(columns: columns, spacing: 8) {
            ForEach(sections) { section in
              Section {
                ForEach(section.items) { item in
                  emojiButton(item)
                }
              } header: {
                Text(section.title)
                  .font(.subheadline.weight(.medium))
                  .foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.top, 12)
                  .padding(.bottom, 4)
                  .accessibilityAddTraits(.isHeader)
                  .id(section.id)
              }
            }
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay {
          if sections.allSatisfy(\.items.isEmpty) {
            ContentUnavailableView.search(text: query)
          }
        }
        .onChange(of: query) {
          if let first = sections.first {
            proxy.scrollTo(first.id, anchor: .top)
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            categoryBar { section in
              isSearchFocused = false
              withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                proxy.scrollTo(section.id, anchor: .top)
              }
            }
          }
        }
      }
      .navigationTitle("Reactions")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search emoji")
      .searchFocused($isSearchFocused)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close", systemImage: "xmark", role: .cancel) {
            dismiss()
          }
          .labelStyle(.iconOnly)
          .accessibilityLabel("Close emoji picker")
        }
      }
    }
    .background(Color(uiColor: .systemBackground))
    .accessibilityIdentifier("reactionEmojiPickerSheet")
  }

  private func emojiButton(_ item: EmojiPickerItem) -> some View {
    let emoji = skinTone.applying(to: item.emoji)
    let isSelected = selectedEmojis.contains(emoji)
    return Button {
      guard !didSelect else { return }
      didSelect = true
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      onSelect(emoji)
      dismiss()
    } label: {
      Text(emoji)
        .font(.system(size: 32))
        .frame(maxWidth: .infinity, minHeight: 48)
        .background {
          if isSelected {
            Circle().fill(Color.primary.opacity(0.12))
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(didSelect)
    .accessibilityLabel(item.label)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("reactionEmoji.\(emoji)")
  }

  private func categoryBar(onSelect: @escaping (EmojiPickerSection) -> Void) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 0) {
        ForEach(sections) { section in
          Button {
            onSelect(section)
          } label: {
            Image(systemName: categorySymbol(for: section.id))
              .font(.system(size: 20))
              .frame(width: 44, height: 48)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .accessibilityLabel(section.title)
        }
      }
      .padding(.horizontal, 8)
    }
    .background(.bar)
  }

  private func categorySymbol(for id: String) -> String {
    switch id {
      case "frequent": "clock"
      case "smileys": "face.smiling"
      case "people": "hand.wave"
      case "animals": "pawprint"
      case "food": "cup.and.saucer"
      case "travel": "car"
      case "activities": "soccerball"
      case "objects": "lightbulb"
      case "symbols": "number"
      case "flags": "flag"
      default: "face.smiling"
    }
  }
}
