import InlineKit
import SwiftUI

#if os(iOS)
struct IOSForwardMessagesSheetView: View {
  @Bindable var model: ForwardMessagesSheetModel
  let onToggleSelectionMode: () -> Void
  let onSend: () -> Void
  let onActivateDestination: (ForwardMessagesDestination) -> Void

  var body: some View {
    NavigationStack {
      List {
        if model.filteredDestinations.isEmpty {
          emptyState
        } else {
          ForEach(model.filteredDestinations) { destination in
            Button {
              onActivateDestination(destination)
            } label: {
              IOSForwardDestinationRow(
                destination: destination,
                isSelecting: model.isSelecting,
                isSelected: model.isSelected(destination)
              )
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
          }
        }
      }
      .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always))
      .disabled(model.isSending)
      .navigationTitle(model.navigationTitle)
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        if model.supportsMultiSelect {
          ToolbarItem(placement: .primaryAction) {
            Button(model.isSelecting ? "Cancel" : "Select") {
              onToggleSelectionMode()
            }
            .disabled(model.isSending)
          }

          if model.shouldShowSendButton {
            ToolbarItem(placement: .confirmationAction) {
              Button("Send") {
                onSend()
              }
              .disabled(model.isSending)
              .fontWeight(.semibold)
            }
          }
        }
      }
    }
  }

  private var emptyState: some View {
    Text(model.searchText.isEmpty ? "No chats available" : "No chats found")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
  }
}

private struct IOSForwardDestinationRow: View, Equatable {
  let destination: ForwardMessagesDestination
  let isSelecting: Bool
  let isSelected: Bool

  private static let avatarSize: CGFloat = 38
  private static let rowHeight: CGFloat = 52

  nonisolated static func == (lhs: IOSForwardDestinationRow, rhs: IOSForwardDestinationRow) -> Bool {
    lhs.destination == rhs.destination
      && lhs.isSelecting == rhs.isSelecting
      && lhs.isSelected == rhs.isSelected
  }

  var body: some View {
    HStack(spacing: 12) {
      if isSelecting {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 21, weight: .medium))
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
          .frame(width: 24, height: 24)
          .accessibilityHidden(true)
      }

      ForwardMessagesAvatarView(
        avatar: destination.avatar,
        size: Self.avatarSize,
        shape: .circle
      )
      .equatable()

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(destination.title)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

          if destination.pinned {
            Image(systemName: "pin.fill")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.secondary)
              .accessibilityLabel("Pinned")
          }

          if destination.unread {
            ForwardMessagesUnreadDot(size: 8)
          }
        }

        subtitle
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(height: Self.rowHeight)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  @ViewBuilder
  private var subtitle: some View {
    let text = subtitleText
    if text.isEmpty {
      EmptyView()
    } else {
      Text(text)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var subtitleText: String {
    if let parentTitle = destination.parentTitle, !parentTitle.isEmpty {
      return parentTitle
    }

    if let spaceTitle = destination.spaceTitle, !spaceTitle.isEmpty {
      if destination.preview.isEmpty {
        return spaceTitle
      }
      return "\(spaceTitle) · \(destination.preview)"
    }

    return destination.preview
  }
}
#endif
