#if os(iOS)
import Combine
import Photos
import SwiftUI

public extension Notification.Name {
  static let attachmentPickerRecentMediaDidChange = Notification.Name("attachmentPickerRecentMediaDidChange")
}

public enum AttachmentPickerRecentMediaChangeUserInfo {
  public static let localIdentifiersKey = "localIdentifiers"
}

public struct AttachmentPickerActions {
  public let openCamera: () -> Void
  public let openLibrary: () -> Void
  public let openFiles: () -> Void
  public let openRecentItem: (AttachmentPickerModel.RecentItem) -> Void
  public let openRecentItems: ([AttachmentPickerModel.RecentItem]) -> Void
  public let manageLimitedAccess: () -> Void

  public init(
    openCamera: @escaping () -> Void,
    openLibrary: @escaping () -> Void,
    openFiles: @escaping () -> Void,
    openRecentItem: @escaping (AttachmentPickerModel.RecentItem) -> Void,
    openRecentItems: @escaping ([AttachmentPickerModel.RecentItem]) -> Void,
    manageLimitedAccess: @escaping () -> Void
  ) {
    self.openCamera = openCamera
    self.openLibrary = openLibrary
    self.openFiles = openFiles
    self.openRecentItem = openRecentItem
    self.openRecentItems = openRecentItems
    self.manageLimitedAccess = manageLimitedAccess
  }
}

public struct AttachmentPickerSheet: View {
  @State private var model: AttachmentPickerModel

  private let actions: AttachmentPickerActions

  @MainActor
  public init(
    actions: AttachmentPickerActions,
    recentLimit: Int = 25
  ) {
    _model = State(initialValue: AttachmentPickerModel(recentLimit: recentLimit))
    self.actions = actions
  }

  @MainActor
  init(
    model: AttachmentPickerModel,
    actions: AttachmentPickerActions
  ) {
    _model = State(initialValue: model)
    self.actions = actions
  }

  public var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .overlay(alignment: .bottom) {
        bottomSendButtonOverlay
      }
      .animation(.easeInOut(duration: 0.22), value: model.selectedRecentItems.isEmpty)
      .task {
        await model.reload()
      }
      .onReceive(NotificationCenter.default.publisher(for: .attachmentPickerRecentMediaDidChange)) { notification in
        Task {
          let localIdentifiers = notification.userInfo?[AttachmentPickerRecentMediaChangeUserInfo.localIdentifiersKey] as? [String]
          if let localIdentifiers {
            await model.reload(promotingLocalIdentifiers: localIdentifiers)
          } else {
            await model.reload()
          }
        }
      }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 18) {
      mediaHeader

      recentStrip

      if let message = emptyStateMessage {
        Text(message)
          .font(.footnote.weight(.regular))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 2)
      }

      Divider()
        .padding(.horizontal, 20)

      actionList
    }
    .padding(.top, 20)
    .padding(.bottom, 24)
  }

  private var mediaHeader: some View {
    ZStack(alignment: .leading) {
      if model.showsLimitedAccessNotice {
        LimitedLibraryNotice(action: actions.manageLimitedAccess)
      }

      Text("Select Media")
        .font(.headline.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.leading, 20)
        .allowsHitTesting(false)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var recentStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        AttachmentPickerCameraTile(action: actions.openCamera)

        ForEach(model.recentItems) { item in
          AttachmentPickerRecentTile(
            item: item,
            isSelected: model.selectedRecentItemIds.contains(item.localIdentifier),
            onSelectToggle: {
              model.toggleRecentSelection(localIdentifier: item.localIdentifier)
            }
          )
        }
      }
      .padding(.horizontal, 12)
    }
  }

  private var actionList: some View {
    VStack(spacing: 18) {
      listActionButton(
        title: "Library",
        systemImage: "photo.on.rectangle.angled",
        action: libraryAction
      )

      listActionButton(
        title: "Files",
        systemImage: "folder",
        action: actions.openFiles
      )
    }
    .padding(.horizontal, 20)
  }

  private var sendSelectedButtonTitle: String {
    let count = model.selectedRecentItems.count
    if count == 1 {
      return "Add 1 photo"
    }
    return "Add \(count) photos"
  }

  @ViewBuilder
  private var bottomSendButtonOverlay: some View {
    if model.selectedRecentItems.isEmpty == false {
      Button(action: sendSelectedItems) {
        Text(sendSelectedButtonTitle)
          .font(.body.weight(.semibold))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
      }
      .buttonStyle(.plain)
      .background(.blue, in: Capsule())
      .padding(.horizontal, 28)
      .padding(.bottom, 8)
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  private func sendSelectedItems() {
    let selectedItems = model.selectedRecentItems
    guard selectedItems.isEmpty == false else { return }
    actions.openRecentItems(selectedItems)
    model.clearRecentSelection()
  }

  private func listActionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: systemImage)
          .font(.system(size: 20, weight: .regular))
          .foregroundStyle(.primary)
          .frame(width: 28)

        Text(title)
          .font(.body.weight(.regular))
          .foregroundStyle(.primary)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 6)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }

  private var libraryAction: () -> Void {
    switch resolveAttachmentPickerLibraryActionTarget(
      showsLimitedAccessNotice: model.showsLimitedAccessNotice
    ) {
      case .openLibrary:
        return actions.openLibrary
      case .manageLimitedAccess:
        return actions.manageLimitedAccess
    }
  }

  private var emptyStateMessage: String? {
    if model.isLoading {
      return nil
    }

    switch model.authorizationStatus {
      case .denied, .restricted:
        return "Allow photo access to see recent media here."
      case .authorized, .limited:
        return nil
      case .notDetermined:
        return nil
      @unknown default:
        return nil
    }
  }
}
#endif
