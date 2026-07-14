import Auth
import InlineKit
import InlineUI
import Logger
import RealtimeV2
import SwiftUI

struct ReactionOverlayView: View {
  let fullMessage: FullMessage
  let onDismiss: () -> Void
  let onEmojiPickerActiveChanged: (Bool) -> Void
  let onEmojiPickerDismissed: () -> Void

  private static let log = Log.scoped("ReactionOverlayView")

  // State for hover and animation
  @State private var isHovered: [String: Bool] = [:]
  @State private var suggestedReactions = ReactionPickerEmojiUsageStore.suggestedEmojis()
  @State private var suggestionCounts = ReactionPickerEmojiUsageStore.usageCounts()
  @State private var suggestionSources: [String: String] = [:]
  @State private var appearScale: CGFloat = 0.5
  @State private var appearOpacity: Double = 0
  @State private var isEmojiPickerPresented = false
  @State private var isSelectingCustomEmoji = false

  private let pageWidth: CGFloat = 280 // Width of one page of reactions
  private static let buttonSize: CGFloat = 32
  private static let moreReactionsKey = "__more_reactions"

  private func handleReactionSelected(_ emoji: String) {
    let preferredEmoji = AppSettings.shared.preferredEmojiSkinTone.applying(to: emoji)
    guard let emoji = EmojiPickerValue.normalizedEmoji(from: preferredEmoji) else { return }

    // Check if user already reacted with this emoji
    guard let currentUserId = Auth.shared.getCurrentUserId() else {
      onDismiss()
      return
    }

    let hasReaction = fullMessage.reactions.contains {
      $0.reaction.emoji == emoji && $0.reaction.userId == currentUserId
    }

    Task(priority: .userInitiated) { @MainActor in
      do {
        if hasReaction {
          // Remove reaction
          try await Api.realtime.send(.deleteReaction(
            emoji: emoji,
            message: fullMessage.message
          ))
        } else {
          // Add reaction
          try await Api.realtime.send(.addReaction(
            emoji: emoji,
            message: fullMessage.message
          ))
          ReactionPickerEmojiUsageStore.recordPick(emoji)
          reloadSuggestedReactions()
        }
      } catch {
        Self.log.error("Failed to update reaction", error: error)
      }
    }

    // Dismiss the overlay
    onDismiss()
  }

  private func showEmojiPicker() {
    isSelectingCustomEmoji = false
    isEmojiPickerPresented = true
  }

  private func handleCustomEmojiSelected(_ value: String) {
    isSelectingCustomEmoji = true
    isEmojiPickerPresented = false
    handleReactionSelected(value)
  }

  private func removeSuggestion(_ emoji: String) {
    ReactionPickerEmojiUsageStore.removeSuggestion(suggestionSources[emoji] ?? emoji)

    withAnimation(.smoothSnappy) {
      reloadSuggestedReactions()
    }
  }

  private func reloadSuggestedReactions() {
    let counts = ReactionPickerEmojiUsageStore.usageCounts()
    let sourceReactions = ReactionPickerEmojis.suggestions(from: counts)
    var displayedReactions: [String] = []
    var sources: [String: String] = [:]

    for source in sourceReactions {
      let displayed = AppSettings.shared.preferredEmojiSkinTone.applying(to: source)
      guard sources[displayed] == nil else { continue }
      sources[displayed] = source
      displayedReactions.append(displayed)
    }

    suggestionCounts = counts
    suggestionSources = sources
    suggestedReactions = displayedReactions
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 2) {
        ForEach(suggestedReactions, id: \.self) { emoji in
          reactionButton(emoji)
        }
        moreReactionsButton
      }
      .padding(.vertical, 2)
      .padding(.horizontal, 6)
    }
    .background(
      RoundedRectangle(cornerRadius: 20)
        .fill(.ultraThinMaterial)
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
    )
    .frame(width: pageWidth, height: 50)
    .scaleEffect(appearScale)
    .opacity(appearOpacity)
    .onAppear {
      reloadSuggestedReactions()
      withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
        appearScale = 1.0
        appearOpacity = 1.0
      }
    }
    .onChange(of: isEmojiPickerPresented) { wasPresented, isPresented in
      onEmojiPickerActiveChanged(isPresented)
      guard wasPresented, !isPresented else { return }

      if isSelectingCustomEmoji {
        isSelectingCustomEmoji = false
        return
      }

      onEmojiPickerDismissed()
    }
    .padding(5)
  }

  private func reactionButton(_ emoji: String) -> some View {
    Button(
      action: {
        handleReactionSelected(emoji)
      },
      label: {
        Text(emoji)
          .font(.system(size: 22))
          .frame(width: Self.buttonSize, height: Self.buttonSize)
      }
    )
    .buttonStyle(.plain)
    .background(buttonBackground(key: emoji))
    .contentShape(Circle())
    .scaleEffect(isHovered[emoji] == true ? 1.1 : 1.0)
    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHovered[emoji])
    .onHover { hovering in
      isHovered[emoji] = hovering
    }
    .contextMenu {
      if suggestionCounts[suggestionSources[emoji] ?? emoji, default: 0] > 0 {
        Button("Remove from suggestions", role: .destructive) {
          removeSuggestion(emoji)
        }
      }
    }
  }

  private var moreReactionsButton: some View {
    Button(action: showEmojiPicker) {
      Image(systemName: "plus")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: Self.buttonSize, height: Self.buttonSize)
    }
    .buttonStyle(.plain)
    .background(buttonBackground(key: Self.moreReactionsKey))
    .contentShape(Circle())
    .scaleEffect(isHovered[Self.moreReactionsKey] == true ? 1.1 : 1.0)
    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHovered[Self.moreReactionsKey])
    .onHover { hovering in
      isHovered[Self.moreReactionsKey] = hovering
    }
    .help("More reactions")
    .popover(isPresented: $isEmojiPickerPresented, arrowEdge: .bottom) {
      EmojiPickerPopover(onSelect: handleCustomEmojiSelected)
    }
  }

  private func buttonBackground(key: String) -> some View {
    Circle()
      .fill(Color(NSColor.windowBackgroundColor).opacity(isHovered[key] == true ? 0.6 : 0))
      .animation(.easeOut(duration: 0.15), value: isHovered[key])
  }
}
