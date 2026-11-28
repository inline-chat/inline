import Auth
import InlineKit
import SwiftUI

/// The reaction picker over a message (hover quick action): the shared `ReactionStrip` on its own
/// material, with + opening the full picker above it.
struct ReactionOverlayView: View {
  static let shadowPadding: CGFloat = 5

  let fullMessage: FullMessage
  let onDismiss: () -> Void
  let onEmojiPickerActiveChanged: (Bool) -> Void
  let onEmojiPickerDismissed: () -> Void

  @StateObject private var model: ReactionStripModel
  @State private var appearScale: CGFloat = 0.5
  @State private var appearOpacity: Double = 0

  private let pageWidth: CGFloat = 280 // Width of one page of reactions

  init(
    fullMessage: FullMessage,
    onDismiss: @escaping () -> Void,
    onEmojiPickerActiveChanged: @escaping (Bool) -> Void,
    onEmojiPickerDismissed: @escaping () -> Void
  ) {
    self.fullMessage = fullMessage
    self.onDismiss = onDismiss
    self.onEmojiPickerActiveChanged = onEmojiPickerActiveChanged
    self.onEmojiPickerDismissed = onEmojiPickerDismissed
    _model = StateObject(wrappedValue: ReactionStripModel(fullMessage: fullMessage))
  }

  private func handleReactionSelected(_ emoji: String) {
    guard Auth.shared.getCurrentUserId() != nil else {
      onDismiss()
      return
    }
    MessageReactionActions.toggle(emoji, on: fullMessage, messageEmojis: model.messageEmojis)
    model.reload()
    onDismiss()
  }

  var body: some View {
    ReactionStrip(
      model: model,
      pickerEdge: .maxY,
      onPick: handleReactionSelected,
      onPickerDismissed: onEmojiPickerDismissed
    )
    .background(
      RoundedRectangle(cornerRadius: 20)
        .fill(.ultraThinMaterial)
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
    )
    .frame(width: pageWidth, height: 50)
    .scaleEffect(appearScale)
    .opacity(appearOpacity)
    .onAppear {
      model.reload()
      withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
        appearScale = 1.0
        appearOpacity = 1.0
      }
    }
    .onChange(of: model.isEmojiPickerPresented) { _, isPresented in
      onEmojiPickerActiveChanged(isPresented)
    }
    .padding(Self.shadowPadding)
  }
}
