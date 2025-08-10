import InlineKit
import SwiftUI

/// Presented in a small popover when chat needs translation
public struct TranslationPrompt: View {
  var peer: Peer

  @Environment(\.dismiss) private var dismiss

  public var body: some View {
    HStack {
      // TODO: Translate this prompt in common user languages
      Text(
        "Translation available"
      ).fixedSize()

      #if os(macOS)
      // Close button
      dismissButton
      #endif
    }
    #if os(macOS)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    #else
    .padding()
    #endif
  }

  @ViewBuilder var dismissButton: some View {
    Button {
      TranslationAlertDismiss.shared.dismissForPeer(peer)
      dismiss()
    } label: {
      Image(systemName: "xmark")
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .focusable(false)
  }
}

#Preview {
  TranslationPrompt(peer: .user(id: 1))
}
