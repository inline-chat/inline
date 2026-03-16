#if os(iOS)
import Photos
import SwiftUI

public struct AttachmentPickerActions {
  public let openCamera: () -> Void
  public let openLibrary: () -> Void
  public let openFiles: () -> Void
  public let openRecentItem: (AttachmentPickerModel.RecentItem) -> Void
  public let manageLimitedAccess: () -> Void

  public init(
    openCamera: @escaping () -> Void,
    openLibrary: @escaping () -> Void,
    openFiles: @escaping () -> Void,
    openRecentItem: @escaping (AttachmentPickerModel.RecentItem) -> Void,
    manageLimitedAccess: @escaping () -> Void
  ) {
    self.openCamera = openCamera
    self.openLibrary = openLibrary
    self.openFiles = openFiles
    self.openRecentItem = openRecentItem
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
      .task {
        await model.reload()
      }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 18) {
      if model.showsLimitedAccessNotice {
        LimitedLibraryNotice(action: actions.manageLimitedAccess)
      }

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

  private var recentStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        AttachmentPickerCameraTile(action: actions.openCamera)

        ForEach(model.recentItems) { item in
          AttachmentPickerRecentTile(item: item) {
            actions.openRecentItem(item)
          }
        }
      }
      .padding(.horizontal, 12)
    }
  }

  private var actionList: some View {
    VStack(spacing: 18) {
      listActionButton(
        title: "Photos",
        systemImage: "photo.on.rectangle.angled",
        action: actions.openLibrary
      )

      listActionButton(
        title: "Files",
        systemImage: "folder",
        action: actions.openFiles
      )
    }
    .padding(.horizontal, 20)
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

  private var emptyStateMessage: String? {
    if model.isLoading {
      return nil
    }

    switch model.authorizationStatus {
      case .denied, .restricted:
        return "Allow photo access to see recent photos here."
      case .authorized, .limited:
        return model.recentItems.isEmpty ? "No recent photos yet." : nil
      case .notDetermined:
        return nil
      @unknown default:
        return nil
    }
  }
}
#endif
