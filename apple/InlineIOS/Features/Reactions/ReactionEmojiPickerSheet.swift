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
  /// Written every scroll frame; kept unobserved so only the active tab change re-renders.
  @State private var headerOffsets = HeaderOffsets()
  @State private var activeSectionID: String?
  @FocusState private var isSearchFocused: Bool

  private let skinTone = EmojiSkinTonePreferenceStore.current()
  /// Captured when the sheet opens so Frequently Used doesn't reshuffle while browsing.
  private let browseSections: [EmojiPickerSection] = {
    var sections = EmojiPickerData.defaultSections
    if let frequent = EmojiPickerData.frequentlyUsedSection(limit: 24) {
      sections.insert(frequent, at: 0)
    }
    return sections
  }()

  private let columns = [GridItem(.adaptive(minimum: 42, maximum: 56), spacing: 2)]
  private static let scrollSpace = "reactionEmojiScroll"

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var sections: [EmojiPickerSection] {
    guard !trimmedQuery.isEmpty else { return browseSections }
    return [EmojiPickerSection(
      id: "search", title: "",
      items: EmojiPickerData.suggestions(matching: trimmedQuery, limit: 200)
    )]
  }

  var body: some View {
    let sections = sections
    NavigationStack {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVGrid(columns: columns, spacing: 2) {
            ForEach(sections) { section in
              Section {
                ForEach(section.items) { item in
                  emojiButton(item)
                }
              } header: {
                sectionHeader(section)
              }
            }
          }
          .padding(.horizontal, 12)
          .padding(.top, trimmedQuery.isEmpty ? 0 : 8)
          .padding(.bottom, 16)
        }
        .coordinateSpace(.named(Self.scrollSpace))
        .scrollDismissesKeyboard(.interactively)
        .overlay {
          if sections.allSatisfy(\.items.isEmpty) {
            ContentUnavailableView.search(text: trimmedQuery)
          }
        }
        .onChange(of: trimmedQuery) {
          if let first = sections.first {
            proxy.scrollTo(first.id, anchor: .top)
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if trimmedQuery.isEmpty {
            categoryBar { section in
              isSearchFocused = false
              activeSectionID = section.id
              withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                proxy.scrollTo(section.id, anchor: .top)
              }
            }
          }
        }
      }
      .navigationTitle("Reactions")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Emoji")
      .searchFocused($isSearchFocused)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .onSubmit(of: .search) {
        // Return picks the best match.
        if let first = sections.first?.items.first {
          select(first)
        }
      }
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

  @ViewBuilder
  private func sectionHeader(_ section: EmojiPickerSection) -> some View {
    // Search results are one ranked list; a title adds nothing.
    if section.title.isEmpty {
      Color.clear.frame(height: 0).id(section.id)
    } else {
      Text(section.title)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
        .id(section.id)
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.frame(in: .named(Self.scrollSpace)).minY
        } action: { minY in
          headerOffsets.values[section.id] = minY
          updateActiveSection()
        }
        .onDisappear {
          headerOffsets.values[section.id] = nil
        }
    }
  }

  /// The last section whose title has reached the top of the grid.
  private func updateActiveSection() {
    let threshold: CGFloat = 24
    let passed = browseSections.last { section in
      guard let offset = headerOffsets.values[section.id] else { return false }
      return offset <= threshold
    }
    let next = passed?.id ?? browseSections.first?.id
    if activeSectionID != next {
      activeSectionID = next
    }
  }

  private func select(_ item: EmojiPickerItem) {
    guard !didSelect else { return }
    didSelect = true
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    onSelect(skinTone.applying(to: item.emoji))
    dismiss()
  }

  private func emojiButton(_ item: EmojiPickerItem) -> some View {
    let emoji = skinTone.applying(to: item.emoji)
    let isSelected = selectedEmojis.contains(emoji)
    return Button {
      select(item)
    } label: {
      Text(emoji)
        .font(.system(size: 30))
        .frame(maxWidth: .infinity, minHeight: 46)
        .background {
          if isSelected {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(Color.accentColor.opacity(0.16))
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(EmojiCellButtonStyle())
    .disabled(didSelect)
    .accessibilityLabel(item.label)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("reactionEmoji.\(emoji)")
  }

  private func categoryBar(onSelect: @escaping (EmojiPickerSection) -> Void) -> some View {
    HStack(spacing: 0) {
      ForEach(browseSections) { section in
        let isActive = section.id == (activeSectionID ?? browseSections.first?.id)
        Button {
          onSelect(section)
        } label: {
          Image(systemName: categorySymbol(for: section.id))
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .frame(width: 34, height: 30)
            .background {
              if isActive {
                Capsule().fill(Color.primary.opacity(0.08))
              }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
      }
    }
    .padding(.horizontal, 6)
    .background(.bar)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: activeSectionID)
  }

  private func categorySymbol(for id: String) -> String {
    switch id {
      case EmojiPickerData.frequentlyUsedSectionID: "clock"
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

private final class HeaderOffsets {
  var values: [String: CGFloat] = [:]
}

/// Pressed emoji dim and shrink slightly, like the system keyboard's emoji grid.
private struct EmojiCellButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.88 : 1)
      .opacity(configuration.isPressed ? 0.7 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}
