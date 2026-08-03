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

  var selectedSpaceId: Binding<Int64?>?
  var onSelectHome: (() -> Void)?
  var onSelectSpace: ((Space) -> Void)?
  var onCreateSpace: (() -> Void)?

  @State private var localSelectedSpaceId: Int64?
  @State private var presentedSheet: PresentedSheet?

  var body: some View {
    let selectedSpaceId = selectedSpaceId ?? $localSelectedSpaceId
    let activeSpace = selectedSpace(selectedSpaceId.wrappedValue)
    let visibleConnectionState = connectionStateForToolbar(activeSpace: activeSpace)
    let title = visibleConnectionState?.title
      ?? activeSpace?.displayName
      ?? (onSelectHome != nil ? "Home" : "Spaces")
    let createSpace = onCreateSpace ?? { router.push(.createSpace) }
    let selection = Binding<Int64?>(
      get: { selectedSpaceId.wrappedValue },
      set: { newSpaceId in
        selectedSpaceId.wrappedValue = newSpaceId
        if let newSpaceId,
           let space = compactSpaceList.spaces.first(where: { $0.id == newSpaceId }) {
          onSelectSpace?(space)
        } else {
          onSelectHome?()
        }
      }
    )

    Menu {
      Picker("Space", selection: selection) {
        if onSelectHome != nil {
          Text("Home")
            .tag(nil as Int64?)
        }

        ForEach(compactSpaceList.spaces) { space in
          Text(space.displayName)
            .tag(space.id as Int64?)
        }
      }
      .labelsHidden()

      Divider()

      Button {
        createSpace()
      } label: {
        Text("Create Space")
      }
    } label: {
      HStack(spacing: 4) {
        Text(title)
          .font(activeSpace == nil ? .title.weight(.bold) : .headline)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.tail)
          .allowsTightening(true)

        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
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

  private func connectionStateForToolbar(activeSpace _: Space?) -> RealtimeConnectionState? {
    realtimeState.displayedConnectionState
  }
}

// TODO: Reconsider a toolbar space icon only if the text-only context
// picker proves insufficient during prototype review.
private struct SpacePickerToolbarIcon: View {
  let space: Space?
  let systemImage: String
  let size: CGFloat

  var body: some View {
    if let space {
      SpacePickerMonochromeAvatar(space: space, size: size)
    } else {
      RoundedRectangle(cornerRadius: size / 3.0, style: .continuous)
        .fill(Color.gray.opacity(0.15))
        .frame(width: size, height: size)
        .overlay {
          Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.primary)
        }
    }
  }
}

// TODO: Remove the old sheet picker after the compact menu UX is accepted.
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
