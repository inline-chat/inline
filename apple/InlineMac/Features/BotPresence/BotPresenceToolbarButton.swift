import InlineKit
import SwiftUI

struct BotPresenceToolbarButton: View {
  let peer: Peer
  @ObservedObject var controller: BotPresenceController

  var body: some View {
    if let item = controller.toolbarItem(for: peer) {
      Button {
        if item.isVisible {
          controller.close()
        } else {
          controller.showCurrent()
        }
      } label: {
        BotPresenceToolbarPreview(item: item)
      }
      .help(item.isVisible ? "Hide \(item.displayName)" : "Show \(item.displayName)")
      .accessibilityLabel(item.isVisible ? "Hide \(item.displayName)" : "Show \(item.displayName)")
    }
  }
}

private struct BotPresenceToolbarPreview: View {
  let item: BotPresenceToolbarItem

  @State private var preview: CGImage?

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.primary.opacity(0.07))

      if let preview {
        Image(decorative: preview, scale: 1)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .padding(1)
      } else {
        Image(systemName: "sparkle")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 22, height: 22)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(
          item.isVisible ? Color.accentColor : Color.primary.opacity(0.12),
          lineWidth: item.isVisible ? 1.4 : 0.7
        )
    }
    .task(id: item.avatarKey) {
      preview = nil
      let image = await BotAvatarAtlasCache.shared.previewFrame(for: item.avatar)
      guard !Task.isCancelled else { return }
      preview = image
    }
  }
}
