import Auth
import InlineKit
import Logger
import RealtimeV2
import SwiftUI

struct ReactionOverlayView: View {
  let fullMessage: FullMessage
  let onDismiss: () -> Void
  let onEmojiPickerActiveChanged: (Bool) -> Void
  let onEmojiPickerDismissed: () -> Void

  private static let log = Log.scoped("ReactionOverlayView")

  // Common emoji reactions - doubled the amount
  static let defaultReactions = [
    "🥹",
    "❤️",
    "🫡",
    "👍",
    "👎",
    "💯",
    "😂",
    "✔️",
    "🎉",
    "🔥",
    "👏",
    "🙏",
    "🤔",
    "😮",
    "😢",
    "😡",
  ]

  // State for hover and animation
  @State private var isHovered: [String: Bool] = [:]
  @State private var appearScale: CGFloat = 0.5
  @State private var appearOpacity: Double = 0
  @State private var isEmojiPickerPresented = false
  @State private var isSelectingCustomEmoji = false

  private enum Metrics {
    static let width: CGFloat = 280
    static let height: CGFloat = 46
    static let outerPadding: CGFloat = 4
    static let horizontalPadding: CGFloat = 6
    static let itemSpacing: CGFloat = 2
    static let buttonSize: CGFloat = 32
  }

  private static let moreReactionsKey = "__more_reactions"

  private func handleReactionSelected(_ emoji: String) {
    guard let emoji = EmojiPickerValue.normalizedEmoji(from: emoji) else { return }

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

  var body: some View {
    reactionBar
    .scaleEffect(appearScale)
    .opacity(appearOpacity)
    .onAppear {
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
    .padding(Metrics.outerPadding)
  }

  private var reactionBar: some View {
    ZStack {
      reactionBarBackground

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Metrics.itemSpacing) {
          ForEach(Self.defaultReactions, id: \.self) { emoji in
            reactionButton(emoji)
          }
          moreReactionsButton
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .frame(height: Metrics.height, alignment: .center)
      }
      .frame(width: Metrics.width, height: Metrics.height)
      .background(ReactionScrollViewConfigurator().allowsHitTesting(false))
    }
    .frame(width: Metrics.width, height: Metrics.height)
    .contentShape(Capsule())
  }

  @ViewBuilder
  private var reactionBarBackground: some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: 0) {
        Color.clear
          .frame(width: Metrics.width, height: Metrics.height)
          .glassEffect(.regular.interactive(), in: Capsule())
      }
      .allowsHitTesting(false)
      .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
    } else {
      Capsule()
        .fill(.ultraThinMaterial)
        .allowsHitTesting(false)
        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
    }
  }

  private func reactionButton(_ emoji: String) -> some View {
    Button(
      action: {
        handleReactionSelected(emoji)
      },
      label: {
        Text(emoji)
          .font(.system(size: 22))
          .frame(width: Metrics.buttonSize, height: Metrics.buttonSize)
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
  }

  private var moreReactionsButton: some View {
    Button(
      action: showEmojiPicker,
      label: {
        Image(systemName: "plus")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: Metrics.buttonSize, height: Metrics.buttonSize)
      }
    )
    .buttonStyle(.plain)
    .background(buttonBackground(key: Self.moreReactionsKey))
    .contentShape(Circle())
    .scaleEffect(isHovered[Self.moreReactionsKey] == true ? 1.1 : 1.0)
    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHovered[Self.moreReactionsKey])
    .onHover { hovering in
      isHovered[Self.moreReactionsKey] = hovering
    }
    .help("More reactions")
    .background {
      EmojiPickerPopoverPresenter(
        isPresented: $isEmojiPickerPresented,
        preferredEdge: .maxY,
        onSelect: handleCustomEmojiSelected
      )
      .allowsHitTesting(false)
    }
  }

  private func buttonBackground(key: String) -> some View {
    Circle()
      .fill(Color.primary.opacity(isHovered[key] == true ? 0.08 : 0))
      .animation(.easeOut(duration: 0.15), value: isHovered[key])
  }
}

private struct ReactionScrollViewConfigurator: NSViewRepresentable {
  func makeNSView(context _: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async {
      configure(from: view)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context _: Context) {
    DispatchQueue.main.async {
      configure(from: nsView)
    }
  }

  private func configure(from view: NSView) {
    guard let scrollView = view.firstSuperview(of: NSScrollView.self) else { return }

    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.horizontalScrollElasticity = .allowed
    scrollView.verticalScrollElasticity = .none
  }
}

private extension NSView {
  func firstSuperview<T: NSView>(of _: T.Type) -> T? {
    var current = superview
    while let view = current {
      if let match = view as? T {
        return match
      }
      current = view.superview
    }
    return nil
  }
}
