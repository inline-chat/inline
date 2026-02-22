import InlineKit
import InlineUI
import SwiftUI

struct SpacePickerMenu: View {
  @EnvironmentObject private var compactSpaceList: CompactSpaceList
  @Environment(Router.self) private var router
  var selectedSpaceId: Binding<Int64?>? = nil
  var onSelectHome: (() -> Void)? = nil
  var onSelectSpace: ((Space) -> Void)? = nil
  var onCreateSpace: (() -> Void)? = nil

  @State private var localSelectedSpaceId: Int64?
  @State private var isPickerVisible = false

  var body: some View {
    let selectedSpaceId = selectedSpaceId ?? $localSelectedSpaceId
    let createSpace = onCreateSpace ?? { router.push(.createSpace) }
    let space = selectedSpace(selectedSpaceId.wrappedValue)
    let title = space?.displayName ?? ((onSelectHome == nil) ? "Spaces" : "Home")
    let isHomeSelected = onSelectHome != nil && selectedSpaceId.wrappedValue == nil

    Button {
      isPickerVisible.toggle()
    } label: {
      SpacePickerMenuPill(space: space, title: title)
    }
    .buttonStyle(.plain)
    .popover(isPresented: $isPickerVisible, arrowEdge: .top) {
      SpacePickerOverlayView(
        spaces: compactSpaceList.spaces,
        selectedSpaceId: selectedSpace(selectedSpaceId.wrappedValue)?.id,
        isHomeSelected: isHomeSelected,
        onSelectHome: onSelectHome.map { onSelectHome in
          {
            isPickerVisible = false
            selectedSpaceId.wrappedValue = nil
            onSelectHome()
          }
        },
        onSelect: { space in
          isPickerVisible = false
          onSelectSpace?(space)
          selectedSpaceId.wrappedValue = space.id
        },
        onCreateSpace: {
          isPickerVisible = false
          createSpace()
        }
      )
      .presentationCompactAdaptation(.none)
    }
  }

  private func selectedSpace(_ selectedSpaceId: Int64?) -> Space? {
    if let selectedSpaceId {
      return compactSpaceList.spaces.first(where: { $0.id == selectedSpaceId })
    }

    // Legacy behavior: default to the first space when nothing is selected.
    if selectedSpaceId == nil, onSelectHome == nil {
      return compactSpaceList.spaces.first
    }

    return nil
  }
}

private struct SpacePickerMenuPill: View {
  let space: Space?
  let title: String

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    if #available(iOS 26.0, *) {
      SpacePickerMenuLabel(space: space, title: title)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .glassEffect(.regular.interactive(), in: Capsule())
    } else {
      SpacePickerMenuLabel(space: space, title: title)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
  }

  private var borderColor: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
  }
}

private struct SpacePickerMenuLabel: View {
  let space: Space?
  let title: String

  var body: some View {
    HStack(spacing: 8) {
      if let space {
        SpaceAvatar(space: space, size: 24)
      } else if title == "Home" {
        Circle()
          .fill(Color(.systemGray5))
          .frame(width: 24, height: 24)
          .overlay {
            Image(systemName: "house.fill")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
      } else {
        Circle()
          .fill(Color(.systemGray5))
          .frame(width: 24, height: 24)
      }

      Text(title)
        .font(.headline)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(1)
    }
  }
}

private struct SpacePickerOverlayView: View {
  private static let cornerRadius: CGFloat = 12
  private static let maxListHeight: CGFloat = 260

  let spaces: [Space]
  let selectedSpaceId: Int64?
  let isHomeSelected: Bool
  let onSelectHome: (() -> Void)?
  let onSelect: (Space) -> Void
  let onCreateSpace: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 8) {
      ScrollView {
        VStack(spacing: 0) {
          if let onSelectHome {
            SpacePickerOverlayHomeRow(
              isSelected: isHomeSelected,
              onSelect: onSelectHome
            )
          }

          if spaces.isEmpty {
            SpacePickerEmptyRow()
          } else {
            ForEach(spaces) { space in
              SpacePickerOverlayRow(
                space: space,
                isSelected: space.id == selectedSpaceId,
                onSelect: onSelect
              )
            }
          }

          Divider()
            .opacity(0.6)
            .padding(.vertical, 4)

          Button {
            onCreateSpace()
          } label: {
            HStack(spacing: 8) {
              Image(systemName: "plus")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text("Create Space")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
          }
          .buttonStyle(.plain)
        }
        .padding(10)
      }
      .scrollIndicators(.hidden)
      
    }
    
  }
 
}

private struct SpacePickerOverlayRow: View {
  let space: Space
  let isSelected: Bool
  let onSelect: (Space) -> Void

  var body: some View {
    Button {
      onSelect(space)
    } label: {
      HStack(spacing: 8) {
        SpaceAvatar(space: space, size: 22)
        Text(space.displayName)
          .font(.body)
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(isSelected ? Color(.systemBackground) : Color.clear)
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}

private struct SpacePickerOverlayHomeRow: View {
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button {
      onSelect()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "house.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(width: 22, height: 22)

        Text("Home")
          .font(.body)
          .foregroundStyle(.primary)
          .lineLimit(1)

        Spacer(minLength: 0)
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(isSelected ? Color(.systemBackground) : Color.clear)
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}

private struct SpacePickerEmptyRow: View {
  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(Color(.systemGray5))
        .frame(width: 22, height: 22)
      Text("No Spaces")
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
