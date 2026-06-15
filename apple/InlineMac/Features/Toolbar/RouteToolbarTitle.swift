import SwiftUI

struct RouteToolbarTitleLabel: View {
  let title: String
  var subtitle: String? = nil

  @Environment(\.macToolbarLayout) private var toolbarLayout

  var body: some View {
    VStack(spacing: 1) {
      Text(title)
        .font(.system(size: toolbarLayout.titleFontSize, weight: .semibold))
        .lineLimit(1)

      if let subtitle {
        Text(subtitle)
          .font(.system(size: toolbarLayout.subtitleFontSize, weight: .regular))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }
}

struct RouteToolbarTitleItem: View {
  let title: String
  var subtitle: String? = nil
  var systemImage: String? = nil

  @Environment(\.macToolbarLayout) private var toolbarLayout

  var body: some View {
    HStack(spacing: toolbarLayout.titleSpacing) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: toolbarLayout.titleFontSize + 1, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: toolbarLayout.chatIconSize - 6, height: toolbarLayout.chatIconSize - 6)
      }

      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .font(.system(size: toolbarLayout.titleFontSize + 2, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)

        if let subtitle {
          Text(subtitle)
            .font(.system(size: toolbarLayout.subtitleFontSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(minWidth: 0, alignment: .leading)
      .layoutPriority(1)

      Color.clear
        .frame(minWidth: 0, maxWidth: .infinity)
    }
    .frame(minWidth: 0, maxWidth: toolbarLayout.titleMaxWidth, alignment: .leading)
  }
}
