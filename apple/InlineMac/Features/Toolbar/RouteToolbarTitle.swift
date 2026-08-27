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

struct RouteToolbarSpacePickerItem: Identifiable, Equatable {
  let id: Int64
  let name: String
  var menuDetail: String? = nil

  var menuTitle: String {
    guard let menuDetail, menuDetail.isEmpty == false else { return name }
    return "\(name) · \(menuDetail)"
  }
}

/// A route title that also selects the space context. Keeping this presentation
/// shared prevents Grid and All Chats from drifting into subtly different title
/// pickers while each route continues to own what selecting a space means.
struct RouteToolbarSpacePickerTitleItem: View {
  let title: String
  let selectedSpaceID: Int64?
  var homeTitle: String? = nil
  let spaces: [RouteToolbarSpacePickerItem]
  let help: String
  let onSelect: (Int64?) -> Void

  @Environment(\.macToolbarLayout) private var toolbarLayout

  @ViewBuilder
  var body: some View {
    if spaces.isEmpty {
      RouteToolbarTitleItem(title: title)
    } else {
      Menu {
        if let homeTitle {
          selectionButton(title: homeTitle, spaceID: nil)
          Divider()
        }

        ForEach(spaces) { space in
          selectionButton(title: space.menuTitle, spaceID: space.id)
        }
      } label: {
        HStack(spacing: 6) {
          Text(title)
            .font(.system(size: toolbarLayout.titleFontSize + 2, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)

          Color.clear
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .frame(minWidth: 0, maxWidth: toolbarLayout.titleMaxWidth, alignment: .leading)
      }
      .menuStyle(.button)
      .buttonStyle(.borderless)
      .menuIndicator(.hidden)
      .tint(Color.primary)
      .help(help)
      .accessibilityLabel("\(title), \(help)")
    }
  }

  private func selectionButton(title: String, spaceID: Int64?) -> some View {
    Button {
      onSelect(spaceID)
    } label: {
      if selectedSpaceID == spaceID {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }
}
