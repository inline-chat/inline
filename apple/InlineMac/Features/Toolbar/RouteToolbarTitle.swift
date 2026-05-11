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
