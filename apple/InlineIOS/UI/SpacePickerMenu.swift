import InlineKit
import RealtimeV2
import SwiftUI

struct SpacePickerMenu: View {
  private enum PresentedSheet: String, Identifiable {
    case picker

    var id: String { rawValue }
  }

  @EnvironmentObject private var compactSpaceList: CompactSpaceList
  @EnvironmentObject private var realtimeState: RealtimeState
  @Environment(Router.self) private var router

  var selectedSpaceId: Binding<Int64?>? = nil
  var onSelectHome: (() -> Void)? = nil
  var onSelectSpace: ((Space) -> Void)? = nil
  var onCreateSpace: (() -> Void)? = nil

  @State private var localSelectedSpaceId: Int64?
  @State private var presentedSheet: PresentedSheet?

  var body: some View {
    let selectedSpaceId = selectedSpaceId ?? $localSelectedSpaceId
    let activeSpace = selectedSpace(selectedSpaceId.wrappedValue)
    let displayedConnectionState = realtimeState.displayedConnectionState
    let title = displayedConnectionState?.title
      ?? activeSpace?.displayName
      ?? (onSelectHome != nil ? "Home" : "Spaces")
    let createSpace = onCreateSpace ?? { router.push(.createSpace) }

    Button {
      presentedSheet = .picker
    } label: {
      HStack(spacing: 8) {
        SpacePickerToolbarIcon(
          space: activeSpace,
          systemImage: onSelectHome != nil ? "house.fill" : "building.2.fill"
        )
        Text(title)
          .font(.title)
          .fontWeight(.bold)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.tail)
          .allowsTightening(true)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .sheet(item: $presentedSheet) { _ in
      SpacePickerSheet(
        spaces: compactSpaceList.spaces,
        selectedSpaceId: activeSpace?.id,
        showsHome: onSelectHome != nil,
        onSelectHome: onSelectHome.map { onSelectHome in
          {
            selectedSpaceId.wrappedValue = nil
            onSelectHome()
          }
        },
        onSelectSpace: { space in
          selectedSpaceId.wrappedValue = space.id
          onSelectSpace?(space)
        },
        onCreateSpace: createSpace
      )
    }
  }

  private func selectedSpace(_ selectedSpaceId: Int64?) -> Space? {
    if let selectedSpaceId {
      return compactSpaceList.spaces.first(where: { $0.id == selectedSpaceId })
    }

    if onSelectHome == nil {
      return compactSpaceList.spaces.first
    }

    return nil
  }
}

private struct SpacePickerToolbarIcon: View {
  let space: Space?
  let systemImage: String

  var body: some View {
    if let space {
      SpacePickerMonochromeAvatar(space: space, size: 32)
    } else {
      RoundedRectangle(cornerRadius: 32.0 / 3.0, style: .continuous)
        .fill(Color.gray.opacity(0.15))
        .frame(width: 32, height: 32)
        .overlay {
          Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
        }
    }
  }
}

private struct SpacePickerSheet: View {
  let spaces: [Space]
  let selectedSpaceId: Int64?
  let showsHome: Bool
  let onSelectHome: (() -> Void)?
  let onSelectSpace: (Space) -> Void
  let onCreateSpace: () -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if showsHome, let onSelectHome {
          Button {
            dismiss()
            onSelectHome()
          } label: {
            SpacePickerRow(
              title: "Home",
              space: nil,
              systemImage: "house.fill",
              isSelected: selectedSpaceId == nil
            )
          }
          .buttonStyle(.plain)
        }

        if spaces.isEmpty {
          Text("No Spaces")
            .foregroundStyle(.secondary)
        } else {
          ForEach(spaces) { space in
            Button {
              dismiss()
              onSelectSpace(space)
            } label: {
              SpacePickerRow(
                title: space.displayName,
                space: space,
                systemImage: "building.2.fill",
                isSelected: space.id == selectedSpaceId
              )
            }
            .buttonStyle(.plain)
          }
        }

        Button {
          dismiss()
          onCreateSpace()
        } label: {
          SpacePickerCreateRow(systemImage: "plus")
        }
        .buttonStyle(.plain)
      }
      .navigationTitle("Spaces")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Close") {
            dismiss()
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
}

private struct SpacePickerRow: View {
  let title: String
  let space: Space?
  let systemImage: String
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 12) {
      SpacePickerListIcon(space: space, systemImage: systemImage, size: 28)

      Text(title)
        .foregroundStyle(.primary)
        .lineLimit(1)

      Spacer()

      if isSelected {
        Image(systemName: "checkmark")
          .font(.body)
          .fontWeight(.semibold)
          .foregroundStyle(Color.accentColor)
      }
    }
    .contentShape(Rectangle())
  }
}

private struct SpacePickerCreateRow: View {
  let systemImage: String

  var body: some View {
    HStack(spacing: 12) {
      SpacePickerListIcon(space: nil, systemImage: systemImage, size: 28)

      Text("Create Space")
        .foregroundStyle(.primary)

      Spacer()
    }
    .contentShape(Rectangle())
  }
}

private struct SpacePickerListIcon: View {
  let space: Space?
  let systemImage: String
  let size: CGFloat

  var body: some View {
    if let space {
      SpacePickerMonochromeAvatar(space: space, size: size)
    } else {
      RoundedRectangle(cornerRadius: size / 3, style: .continuous)
        .fill(Color.gray.opacity(0.15))
        .frame(width: size, height: size)
        .overlay {
          Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.secondary)
        }
    }
  }
}

private struct SpacePickerMonochromeAvatar: View {
  let space: Space
  let size: CGFloat

  var body: some View {
    let displayText = leadingEmoji ?? fallbackText

    RoundedRectangle(cornerRadius: size / 3, style: .continuous)
      .fill(Color.gray.opacity(0.15))
      .frame(width: size, height: size)
      .overlay {
        Text(displayText)
          .font(.system(size: size * (displayText.spacePickerIsAllEmoji ? 0.6 : 0.55), weight: .semibold))
          .foregroundStyle(.secondary)
      }
  }

  private var leadingEmoji: String? {
    let rawName = space.name
    let nameWithoutEmoji = space.nameWithoutEmoji
    guard rawName != nameWithoutEmoji else { return nil }

    let emojiPart = nameWithoutEmoji.isEmpty
      ? rawName
      : String(rawName.dropLast(nameWithoutEmoji.count))
    let trimmed = emojiPart.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private var fallbackText: String {
    let trimmed = space.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.first.map { String($0).uppercased() } ?? "·"
  }
}

private extension String {
  var spacePickerIsAllEmoji: Bool {
    !isEmpty && allSatisfy(\.spacePickerIsEmoji)
  }
}

private extension Character {
  var spacePickerIsEmoji: Bool {
    guard let scalar = unicodeScalars.first else { return false }
    return scalar.properties.isEmoji && (scalar.value > 0x238C || unicodeScalars.count > 1)
  }
}
