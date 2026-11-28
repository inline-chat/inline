import AppKit
import InlineKit
import InlineUI
import SwiftUI

/// What the reactions strip shows and where its items are. Owned by whoever hosts the strip: the reaction
/// overlay over a message, or the bar above the message context menu, which also drives keyboard focus
/// and the right-click press-drag through it.
@MainActor
final class ReactionStripModel: ObservableObject {
  static let moreKey = "__more_reactions"

  let fullMessage: FullMessage
  @Published private(set) var suggested: [String] = []
  /// Emoji the current user already reacted with; picking one again removes it.
  @Published private(set) var chosen: Set<String> = []
  /// Keyboard focus, when the context menu moves it into the strip.
  @Published var focusedKey: String?
  /// The item under a press-drag from the right click that opened the menu.
  @Published var pointerKey: String?
  @Published var isEmojiPickerPresented = false

  private(set) var usageCounts: [String: Int] = [:]
  private(set) var sources: [String: String] = [:]
  /// Emoji written in the message itself; sent exactly as shown.
  private(set) var messageEmojis: Set<String> = []

  /// Item frames and the scroller's frame, top-left origin, in the strip's own space.
  fileprivate var itemFrames: [String: CGRect] = [:]
  fileprivate var viewport: CGRect = .zero

  init(fullMessage: FullMessage) {
    self.fullMessage = fullMessage
    reload()
  }

  func reload() {
    let suggestions = MessageReactionActions.suggestions(for: fullMessage)
    usageCounts = suggestions.usageCounts
    sources = suggestions.sources
    messageEmojis = suggestions.messageEmojis
    suggested = suggestions.displayed
    chosen = MessageReactionActions.chosenEmojis(on: fullMessage)
  }

  /// Every focusable item in order: the suggestions, then +.
  var keys: [String] { suggested + [Self.moreKey] }

  /// The item at a point in the strip's space (top-left origin). Suggestions scrolled out of view
  /// don't count.
  func key(at point: CGPoint) -> String? {
    if itemFrames[Self.moreKey]?.contains(point) == true { return Self.moreKey }
    guard viewport.contains(point) else { return nil }
    return suggested.first { itemFrames[$0]?.contains(point) == true }
  }
}

/// The quick reactions: suggestions in a horizontal scroller, + pinned after it opening the full emoji
/// picker from itself. The one reaction picker on macOS, over a message on hover and above the message
/// context menu.
struct ReactionStrip: View {
  static let coordinateSpace = "reaction-strip"
  static let buttonSize: CGFloat = 32
  private static let edgeFadeWidth: CGFloat = 20

  @ObservedObject var model: ReactionStripModel
  /// The side of + the full picker opens on.
  var pickerEdge: NSRectEdge = .maxY
  /// Right-click a suggestion to remove it. Off inside the context menu, where right click belongs to the menu.
  var allowsEditingSuggestions = true
  var onPick: (String) -> Void
  /// Runs just before the full picker opens.
  var onMore: () -> Void = {}
  /// The full picker closed without a pick.
  var onPickerDismissed: () -> Void = {}

  @State private var hovered: String?
  @State private var scrollEdges = ScrollEdges(leading: false, trailing: true)

  private struct ScrollEdges: Equatable {
    var leading: Bool
    var trailing: Bool
  }

  var body: some View {
    // The plus stays pinned outside the scroller so it is always visible, like iOS.
    HStack(spacing: 2) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 2) {
            ForEach(model.suggested, id: \.self) { emoji in
              reactionButton(emoji)
                .id(emoji)
            }
          }
          .padding(.leading, 6)
        }
        .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
          let minOffset = -geometry.contentInsets.leading
          let maxOffset = geometry.contentSize.width + geometry.contentInsets.trailing - geometry.containerSize.width
          return ScrollEdges(
            leading: geometry.contentOffset.x > minOffset + 1,
            trailing: geometry.contentOffset.x < maxOffset - 1
          )
        } action: { _, edges in
          scrollEdges = edges
        }
        .mask(edgeFadeMask)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.coordinateSpace)) } action: { frame in
          model.viewport = frame
        }
        .onChange(of: model.focusedKey) { _, key in
          guard let key, key != ReactionStripModel.moreKey else { return }
          withAnimation(.smoothSnappy) { proxy.scrollTo(key, anchor: .center) }
        }
      }

      moreReactionsButton
        .padding(.trailing, 6)
    }
    .padding(.vertical, 2)
    .coordinateSpace(.named(Self.coordinateSpace))
    .onDisappear { hovered = nil }
  }

  private func isLit(_ key: String) -> Bool {
    hovered == key || model.pointerKey == key || model.focusedKey == key
  }

  private func reactionButton(_ emoji: String) -> some View {
    Button(
      action: { onPick(emoji) },
      label: {
        Text(emoji)
          .font(.system(size: 22))
          .frame(width: Self.buttonSize, height: Self.buttonSize)
      }
    )
    .buttonStyle(.plain)
    .background(itemBackground(key: emoji))
    .contentShape(Circle())
    .scaleEffect(isLit(emoji) ? 1.1 : 1.0)
    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isLit(emoji))
    .onHover { hovering in
      if hovering { hovered = emoji } else if hovered == emoji { hovered = nil }
    }
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.coordinateSpace)) } action: { frame in
      model.itemFrames[emoji] = frame
    }
    .accessibilityLabel(model.chosen.contains(emoji) ? "Remove \(emoji)" : "React with \(emoji)")
    .contextMenu {
      if allowsEditingSuggestions, !model.messageEmojis.contains(emoji),
         model.usageCounts[model.sources[emoji] ?? emoji, default: 0] > 0 {
        Button("Remove from suggestions", role: .destructive) {
          ReactionPickerEmojiUsageStore.removeSuggestion(model.sources[emoji] ?? emoji)
          withAnimation(.smoothSnappy) { model.reload() }
        }
      }
    }
  }

  private var moreReactionsButton: some View {
    let key = ReactionStripModel.moreKey
    return Button(action: showEmojiPicker) {
      Image(systemName: "plus")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)
        .frame(width: Self.buttonSize - 4, height: Self.buttonSize - 4)
        .background(
          Circle().fill(Color.primary.opacity(isLit(key) || model.isEmojiPickerPresented ? 0.14 : 0.08))
        )
        .overlay(focusRing(key: key).padding(-2))
        .frame(width: Self.buttonSize, height: Self.buttonSize)
    }
    .buttonStyle(.plain)
    .contentShape(Circle())
    .scaleEffect(isLit(key) ? 1.1 : 1.0)
    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isLit(key))
    .onHover { hovering in
      if hovering { hovered = key } else if hovered == key { hovered = nil }
    }
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.coordinateSpace)) } action: { frame in
      model.itemFrames[key] = frame
    }
    .help("More reactions")
    .accessibilityLabel("More reactions")
    .background {
      EmojiPickerPopoverPresenter2(
        isPresented: $model.isEmojiPickerPresented,
        preferredEdge: pickerEdge,
        onSelect: { value in
          onPick(AppSettings.shared.preferredEmojiSkinTone.applying(to: value))
        },
        onDismiss: onPickerDismissed
      )
      .allowsHitTesting(false)
    }
  }

  private func showEmojiPicker() {
    guard !model.isEmojiPickerPresented else { return }
    hovered = nil
    model.pointerKey = nil
    model.focusedKey = nil
    onMore()
    model.isEmojiPickerPresented = true
  }

  private func itemBackground(key: String) -> some View {
    ZStack {
      if model.chosen.contains(key) {
        Circle().fill(Color.accentColor.opacity(0.2))
      }
      Circle()
        .fill(Color(NSColor.windowBackgroundColor).opacity(isLit(key) ? 0.6 : 0))
        .animation(.easeOut(duration: 0.15), value: isLit(key))
      focusRing(key: key)
    }
  }

  @ViewBuilder
  private func focusRing(key: String) -> some View {
    if model.focusedKey == key {
      Circle().strokeBorder(Color.accentColor, lineWidth: 2)
    }
  }

  /// Fades reactions out at an edge with more content past it, so the one next to the plus
  /// dissolves instead of reading as clipped behind it.
  private var edgeFadeMask: some View {
    HStack(spacing: 0) {
      LinearGradient(
        colors: [scrollEdges.leading ? .clear : .black, .black],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: Self.edgeFadeWidth)
      Color.black
      LinearGradient(
        colors: [.black, scrollEdges.trailing ? .clear : .black],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: Self.edgeFadeWidth)
    }
  }
}
