import InlineKit
import InlineUI
import SwiftUI

struct SpacePickerMenu: View {
  @EnvironmentObject private var compactSpaceList: CompactSpaceList
  @Environment(Router.self) private var router
  @State private var selectedSpaceId: Int64?
  @State private var isPickerVisible = false

  var body: some View {
    Button {
      isPickerVisible.toggle()
    } label: {
      SpacePickerMenuLabel(space: selectedSpace)
    }
    .buttonStyle(.plain)
    .popover(isPresented: $isPickerVisible, arrowEdge: .top) {
      SpacePickerOverlayView(
        spaces: compactSpaceList.spaces,
        selectedSpaceId: selectedSpace?.id,
        onSelect: { space in
          selectedSpaceId = space.id
          isPickerVisible = false
        },
        onCreateSpace: {
          isPickerVisible = false
          router.push(.createSpace)
        }
      )
      .presentationCompactAdaptation(.none)
    }
  }

  private var selectedSpace: Space? {
    if let selectedSpaceId {
      return compactSpaceList.spaces.first { $0.id == selectedSpaceId }
    }
    return compactSpaceList.spaces.first
  }
}

private struct SpacePickerMenuLabel: View {
  let space: Space?


  var body: some View {
    HStack(spacing: 8) {
      if let space {
        SpaceAvatar(space: space, size: 24)
      } else {
        Circle()
          .fill(Color(.systemGray5))
          .frame(width: 24, height: 24)
      }

      Text(space?.displayName ?? "Spaces")
        .font(.headline)
        .lineLimit(1)
        .truncationMode(.tail)

      Image(systemName: "chevron.up.chevron.down")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: 12, height: 12)
        .layoutPriority(1)
    }
  }
}

private struct SpacePickerOverlayView: View {
  private static let cornerRadius: CGFloat = 12
  private static let maxListHeight: CGFloat = 260
  private static let preferredWidth: CGFloat = 240

  let spaces: [Space]
  let selectedSpaceId: Int64?
  let onSelect: (Space) -> Void
  let onCreateSpace: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    let content = VStack(spacing: 8) {
      ScrollView {
        VStack(spacing: 0) {
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
      }
      .scrollIndicators(.hidden)
      .frame(maxHeight: Self.maxListHeight)
    }
    .padding(10)
    .frame(width: Self.preferredWidth)

    Group {
      if #available(iOS 26.0, *) {
        GlassEffectContainer(spacing: 8) {
          content
        }
        .glassEffect(.regular, in: shape)
      } else {
        content
          .background(.ultraThinMaterial, in: shape)
      }
    }
    .overlay(
      shape.stroke(borderColor, lineWidth: 0.5)
    )
    .shadow(color: Color.black.opacity(0.2), radius: 12, x: 0, y: 6)
  }

  private var borderColor: Color {
    colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
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
