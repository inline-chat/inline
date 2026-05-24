import SwiftUI

struct RouteToolbarTitleLabel: View {
  let title: String
  var subtitle: String? = nil

  var body: some View {
    VStack(spacing: 1) {
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)

      if let subtitle {
        Text(subtitle)
          .font(.system(size: 10, weight: .regular))
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

  var body: some View {
    HStack(spacing: 8) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 18, height: 18)
      }

      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)

        if let subtitle {
          Text(subtitle)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(minWidth: 0, alignment: .leading)
      .layoutPriority(1)

      Color.clear
        .frame(minWidth: 0, maxWidth: .infinity)
    }
    .frame(minWidth: 0, maxWidth: 280, alignment: .leading)
  }
}
